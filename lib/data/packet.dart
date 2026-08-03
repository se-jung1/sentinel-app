import 'dart:convert';
import 'dart:typed_data';

import 'models.dart';

/// 노드 → 앱 바이너리 전송 프레임.
///
/// ⚠ 펌웨어 확정 스펙을 아직 받지 못해 아래 형식을 가정하고 구현했다.
/// 실제 스펙이 나오면 **이 파일만** 고치면 되도록 격리해 두었다.
/// (NFC 페이로드와 BLE 다운로드가 동일한 프레임을 쓴다고 가정)
///
/// 헤더 16바이트 + 레코드 N개 + CRC16 2바이트, 모든 정수는 리틀엔디언.
///
/// ```
/// off size  field
///   0    4  magic        'SNTL'
///   4    1  version      = 1
///   5    1  recordSize   = 14
///   6    2  recordCount  uint16
///   8    8  deviceId     ASCII, 0x00 패딩
///  16  14*N records
///  end   2  crc16-ccitt  (0..end 구간)
/// ```
///
/// 레코드 14바이트:
/// ```
///   0    4  seq    uint32
///   4    4  ts     uint32  unix seconds (UTC)
///   8    2  pm25   uint16  µg/m³
///  10    2  pm10   uint16  µg/m³
///  12    1  flags  uint8   NodeFlags
///  13    1  batt   uint8   %
/// ```
class SentinelPacket {
  static const magic = 0x4C544E53; // 'SNTL' little-endian
  static const headerSize = 16;
  static const recordSize = 14;
  static const crcSize = 2;
  static const supportedVersion = 1;

  const SentinelPacket({required this.deviceId, required this.readings});

  final String deviceId;
  final List<Reading> readings;

  /// 헤더만 보고 전체 프레임 길이를 계산한다.
  /// BLE 수신 중 "몇 바이트 더 받아야 하는지" 판단하는 데 쓴다.
  /// 헤더가 아직 다 안 왔거나 매직이 다르면 null.
  static int? expectedLength(List<int> bytes) {
    if (bytes.length < headerSize) return null;
    final view = ByteData.sublistView(Uint8List.fromList(bytes));
    if (view.getUint32(0, Endian.little) != magic) return null;
    final count = view.getUint16(6, Endian.little);
    return headerSize + count * recordSize + crcSize;
  }

  /// 매직이 맞는지만 빠르게 확인 (NFC 페이로드가 프레임인지 핸드셰이크인지 구분용).
  static bool looksLikeFrame(List<int> bytes) =>
      expectedLength(bytes) != null;

  /// [now]는 ts 이상값 판정 기준 시각. 테스트에서 주입한다.
  static SentinelPacket parse(List<int> bytes, {DateTime? now}) {
    final expected = expectedLength(bytes);
    if (expected == null) {
      throw const PacketException('SNTL 프레임이 아닙니다 (매직 불일치)');
    }
    if (bytes.length < expected) {
      throw PacketException(
        '프레임이 잘렸습니다 (${bytes.length}/$expected 바이트)',
      );
    }

    final data = Uint8List.fromList(bytes.sublist(0, expected));
    final view = ByteData.sublistView(data);

    final version = view.getUint8(4);
    if (version != supportedVersion) {
      throw PacketException('지원하지 않는 프레임 버전: $version');
    }
    final declaredRecordSize = view.getUint8(5);
    if (declaredRecordSize != recordSize) {
      throw PacketException('레코드 크기 불일치: $declaredRecordSize');
    }

    final crcGiven = view.getUint16(expected - crcSize, Endian.little);
    final crcCalc = crc16(data.sublist(0, expected - crcSize));
    if (crcGiven != crcCalc) {
      throw PacketException(
        'CRC 불일치 (수신 0x${crcGiven.toRadixString(16)}, '
        '계산 0x${crcCalc.toRadixString(16)})',
      );
    }

    final deviceId = ascii
        .decode(data.sublist(8, 16), allowInvalid: true)
        .replaceAll('\x00', '')
        .trim();

    final reference = now ?? DateTime.now().toUtc();
    final count = view.getUint16(6, Endian.little);
    final readings = <Reading>[];

    for (var i = 0; i < count; i++) {
      final o = headerSize + i * recordSize;
      final ts = DateTime.fromMillisecondsSinceEpoch(
        view.getUint32(o + 4, Endian.little) * 1000,
        isUtc: true,
      );
      final flags = view.getUint8(o + 12);

      // 이상값 비파기 원칙: 버리지 않고 태그만 붙인다.
      final quality = <String>[
        if (ts.isAfter(reference.add(const Duration(minutes: 5))))
          QualityTag.tsFuture,
        if (ts.isBefore(reference.subtract(const Duration(days: 365))))
          QualityTag.tsStale,
      ];

      readings.add(
        Reading(
          deviceId: deviceId,
          seq: view.getUint32(o, Endian.little),
          ts: ts,
          pm25: view.getUint16(o + 8, Endian.little),
          pm10: view.getUint16(o + 10, Endian.little),
          flags: flags,
          quality: quality,
          battery: view.getUint8(o + 13),
        ),
      );
    }

    return SentinelPacket(deviceId: deviceId, readings: readings);
  }

  /// 테스트·데모용 인코더. 실제 앱 경로에서는 쓰지 않는다.
  static Uint8List encode(String deviceId, List<Reading> readings) {
    final total = headerSize + readings.length * recordSize + crcSize;
    final data = Uint8List(total);
    final view = ByteData.sublistView(data);

    view.setUint32(0, magic, Endian.little);
    view.setUint8(4, supportedVersion);
    view.setUint8(5, recordSize);
    view.setUint16(6, readings.length, Endian.little);
    final id = ascii.encode(deviceId.padRight(8, '\x00')).sublist(0, 8);
    data.setRange(8, 16, id);

    for (var i = 0; i < readings.length; i++) {
      final r = readings[i];
      final o = headerSize + i * recordSize;
      view.setUint32(o, r.seq, Endian.little);
      view.setUint32(o + 4, r.ts.millisecondsSinceEpoch ~/ 1000, Endian.little);
      view.setUint16(o + 8, r.pm25, Endian.little);
      view.setUint16(o + 10, r.pm10, Endian.little);
      view.setUint8(o + 12, r.flags);
      view.setUint8(o + 13, r.battery ?? 100);
    }

    view.setUint16(
      total - crcSize,
      crc16(data.sublist(0, total - crcSize)),
      Endian.little,
    );
    return data;
  }

  /// CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF).
  static int crc16(List<int> bytes) {
    var crc = 0xFFFF;
    for (final b in bytes) {
      crc ^= b << 8;
      for (var i = 0; i < 8; i++) {
        crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) : (crc << 1);
        crc &= 0xFFFF;
      }
    }
    return crc;
  }
}

class PacketException implements Exception {
  const PacketException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// NFC 태그가 프레임 대신 핸드셰이크를 담고 있을 때의 내용.
///
/// 텍스트 형식: `SNTL1|<deviceId>|<bleId>|<siteName>`
/// (bleId·siteName은 생략 가능)
class NodeHandshake {
  const NodeHandshake({required this.deviceId, this.bleId, this.siteName});

  final String deviceId;
  final String? bleId;
  final String? siteName;

  static NodeHandshake? tryParse(String text) {
    final parts = text.trim().split('|');
    if (parts.length < 2 || parts.first != 'SNTL1') return null;
    String? at(int i) =>
        parts.length > i && parts[i].isNotEmpty ? parts[i] : null;
    return NodeHandshake(
      deviceId: parts[1],
      bleId: at(2),
      siteName: at(3),
    );
  }
}
