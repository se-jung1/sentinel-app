import 'dart:convert';
import 'dart:typed_data';

import 'models.dart';

/// 노드 → 앱 바이너리 전송 프레임.
///
/// nRF5340_Presence 펌웨어의 `src/frame.h` 와 짝을 이룬다. 여기 상수를 고칠 일이
/// 생기면 그쪽도 같이 고쳐야 한다. (NFC 페이로드와 BLE 다운로드가 같은 프레임을 쓴다)
///
/// 헤더 16바이트 + 레코드 N개 + CRC16 2바이트, 모든 정수는 리틀엔디언.
///
/// ```
/// off size  field
///   0    4  magic        'SNTL'
///   4    1  version      = 3
///   5    1  recordSize   = 24
///   6    2  recordCount  uint16
///   8    8  deviceId     ASCII, 0x00 패딩
///  16  24*N records
///  end   2  crc16-ccitt  (0..end 구간)
/// ```
///
/// 레코드 24바이트. 앞 14바이트는 v2(재실 전용 노드)와 같고 뒤 10바이트가 v3에서
/// 붙은 공기질이다:
/// ```
///   0    4  seq        uint32
///   4    4  ts         uint32  unix seconds (UTC)
///   8    1  headcount  uint8   그 창에서 동시에 잡힌 최대 인원
///   9    1  occS       uint8   창 중 점유였던 초
///  10    2  dwellS     uint16  끊기지 않은 재실 시간 (창 경계를 넘어 누적)
///  12    1  flags      uint8   NodeFlags
///  13    1  batt       uint8   %
///  14    2  pm25       uint16  0.1 µg/m³, 창 안 최댓값. 0xFFFF = 측정 안 됨
///  16    2  pm10       uint16  0.1 µg/m³, 창 안 최댓값
///  18    2  temp        int16  0.01 °C,   0x7FFF = 측정 안 됨
///  20    2  rh          int16  0.01 %RH
///  22    2  voc         int16  0.1 VOC 지수 (SEN54/55만)
/// ```
///
/// 측정 안 됨 센티널이 부호 있는 필드만 다른 이유: SEN5x 는 없는 값을 전부 `0xFFFF`
/// 로 답하는데 int16 에서 그건 `-1` 이고, −0.01 °C 는 실제로 나올 수 있는 값이다.
class SentinelPacket {
  static const magic = 0x4C544E53; // 'SNTL' little-endian
  static const headerSize = 16;
  static const recordSize = 24;
  static const crcSize = 2;
  static const supportedVersion = 3;

  /// 센서가 "그 값은 없다" 고 답한 것. 0 과 구분해야 한다 — 팬이 멈춘 센서의
  /// PM 0 은 "공기 깨끗함" 으로 읽히고, 그게 이 제품이 내면 안 되는 유일한 거짓말이다.
  static const unknownU = 0xFFFF;
  static const unknownS = 0x7FFF;

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

    int rawTs(int i) =>
        view.getUint32(headerSize + i * recordSize + 4, Endian.little);
    int rawFlags(int i) => view.getUint8(headerSize + i * recordSize + 12);

    // 노드에 달력 시계가 없다. nRF5340 의 RTC 는 32.768 kHz 카운터일 뿐이고
    // DK 에는 배터리 백업이 없어서, ts 는 유닉스 시각이 아니라 최초 부팅 이후
    // 누적 초다. 그대로 올리면 전부 1970년으로 들어가 '오늘' 집계가 텅 빈다.
    //
    // 시각을 아는 쪽이 여기밖에 없어서 여기서 역산한다. 가장 최신 레코드가
    // 방금(길어야 한 창) 찍힌 것이므로 그것을 다운로드 시각에 맞추고 나머지를
    // 같은 간격만큼 뒤로 민다:
    //
    //     실제시각(레코드) = 다운로드시각 − (최신 ts − 레코드 ts)
    //
    // 정확한 것은 레코드 사이의 간격이지 절대 시각이 아니다. 전원이 완전히
    // 나갔던 구간은 그 공백을 알 방법이 없어서 그만큼 어긋난다 — 그래서
    // 버리지 않고 tsDerived 태그를 붙여 파생값임을 남긴다.
    final rebase = count > 0 && rawFlags(count - 1) & NodeFlags.rtcUnset != 0;
    final newest = rebase
        ? List.generate(count, rawTs).reduce((a, b) => a > b ? a : b)
        : 0;
    // 노드의 ts 는 초 단위다. 파생 시각이 마이크로초 정밀도를 주장하면
    // 거짓 정밀도이기도 하고, 서버를 한 번 돌아오면 잘려서 안 맞는다.
    final anchor = DateTime.fromMillisecondsSinceEpoch(
      (reference.millisecondsSinceEpoch ~/ 1000) * 1000,
      isUtc: true,
    );

    for (var i = 0; i < count; i++) {
      final o = headerSize + i * recordSize;
      final raw = rawTs(i);
      final ts = rebase
          ? anchor.subtract(Duration(seconds: newest - raw))
          : DateTime.fromMillisecondsSinceEpoch(raw * 1000, isUtc: true);
      final flags = view.getUint8(o + 12);

      // 이상값 비파기 원칙: 버리지 않고 태그만 붙인다.
      final quality = <String>[
        if (rebase) QualityTag.tsDerived,
        if (ts.isAfter(reference.add(const Duration(minutes: 5))))
          QualityTag.tsFuture,
        if (ts.isBefore(reference.subtract(const Duration(days: 365))))
          QualityTag.tsStale,
      ];

      int? u(int off) {
        final v = view.getUint16(off, Endian.little);
        return v == unknownU ? null : v;
      }

      double? s(int off, double scale) {
        final v = view.getInt16(off, Endian.little);
        return v == unknownS ? null : v / scale;
      }

      // µg/m³ 정수로 내린다: DB·서버·화면이 전부 정수 µg/m³ 이고,
      // 0.1 자리는 센서 정밀도(±5 µg/m³)보다 훨씬 작아서 실어봐야 의미가 없다.
      final pm25 = u(o + 14);
      final pm10 = u(o + 16);

      readings.add(
        Reading(
          deviceId: deviceId,
          seq: view.getUint32(o, Endian.little),
          ts: ts,
          pm25: pm25 == null ? null : (pm25 / 10).round(),
          pm10: pm10 == null ? null : (pm10 / 10).round(),
          headcount: view.getUint8(o + 8),
          occS: view.getUint8(o + 9),
          dwellS: view.getUint16(o + 10, Endian.little),
          tempC: s(o + 18, 100),
          rh: s(o + 20, 100),
          voc: s(o + 22, 10),
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
      view.setUint8(o + 8, r.headcount ?? 0);
      view.setUint8(o + 9, r.occS ?? 0);
      view.setUint16(o + 10, r.dwellS ?? 0, Endian.little);
      view.setUint8(o + 12, r.flags);
      view.setUint8(o + 13, r.battery ?? 100);
      view.setUint16(o + 14, r.pm25 == null ? unknownU : r.pm25! * 10,
          Endian.little);
      view.setUint16(o + 16, r.pm10 == null ? unknownU : r.pm10! * 10,
          Endian.little);
      view.setInt16(o + 18,
          r.tempC == null ? unknownS : (r.tempC! * 100).round(), Endian.little);
      view.setInt16(o + 20,
          r.rh == null ? unknownS : (r.rh! * 100).round(), Endian.little);
      view.setInt16(o + 22,
          r.voc == null ? unknownS : (r.voc! * 10).round(), Endian.little);
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
