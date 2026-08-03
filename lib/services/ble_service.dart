import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../data/packet.dart';

/// 노드의 GATT 정의.
///
/// ⚠ 펌웨어 확정 전 임시 UUID. 실제 값이 나오면 여기만 고치면 된다.
class NodeGatt {
  static final service = Guid('6e400001-b5a3-f393-e0a9-e50e24dcca9e');

  /// 앱 → 노드. 다운로드 명령을 쓴다.
  static final control = Guid('6e400002-b5a3-f393-e0a9-e50e24dcca9e');

  /// 노드 → 앱. 프레임을 조각내어 notify 로 흘려 보낸다.
  static final data = Guid('6e400003-b5a3-f393-e0a9-e50e24dcca9e');

  /// 명령 0x01: sinceSeq 이후의 레코드를 모두 보내라 (uint32 LE).
  static Uint8List dumpSince(int seq) {
    final cmd = Uint8List(5);
    cmd[0] = 0x01;
    ByteData.sublistView(cmd).setUint32(1, seq < 0 ? 0 : seq, Endian.little);
    return cmd;
  }
}

class BleTransferProgress {
  const BleTransferProgress({required this.received, required this.expected});

  final int received;

  /// 헤더를 받기 전에는 총 길이를 알 수 없어 null.
  final int? expected;

  double? get fraction =>
      (expected == null || expected == 0) ? null : received / expected!;
}

class BleService {
  /// dart:io 를 쓰지 않는다 — 나중에 웹 빌드를 켜도 컴파일이 깨지지 않도록.
  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Android 12+ 는 스캔·연결 권한이 따로 있고, 그 이전은 위치 권한이 필요하다.
  Future<bool> ensurePermissions() async {
    if (kIsWeb) return false;
    if (!_isAndroid) return true;

    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    // 구형 안드로이드에서는 bluetoothScan/Connect 가 항상 granted 로 떨어진다.
    return statuses[Permission.bluetoothScan]?.isGranted == true &&
        statuses[Permission.bluetoothConnect]?.isGranted == true;
  }

  Stream<BluetoothAdapterState> get adapterState =>
      FlutterBluePlus.adapterState;

  Future<bool> get isSupported => FlutterBluePlus.isSupported;

  /// 안드로이드에서만 앱이 직접 켤 수 있다. iOS 는 설정 앱으로 안내해야 한다.
  Future<void> turnOn() async {
    if (_isAndroid) await FlutterBluePlus.turnOn();
  }

  /// 노드에 붙어 프레임 한 벌을 받아 온다.
  ///
  /// [bleId] 는 NFC 핸드셰이크에서 받은 광고 이름 또는 remoteId.
  /// 없으면 서비스 UUID 만으로 찾는다.
  Future<Uint8List> download({
    required int sinceSeq,
    String? bleId,
    void Function(BleTransferProgress progress)? onProgress,
    Duration scanTimeout = const Duration(seconds: 15),
    Duration transferTimeout = const Duration(seconds: 60),
  }) async {
    final device = await _find(bleId: bleId, timeout: scanTimeout);
    // ⚠ flutter_blue_plus 2.x 는 라이선스 종류를 명시해야 한다.
    // 설계 검토 단계라 nonprofit 으로 두었으나, 상용 납품 시점에는
    // 유료 커머셜 라이선스 구매 또는 다른 BLE 패키지로 교체가 필요하다.
    await device.connect(
      license: License.nonprofit,
      timeout: const Duration(seconds: 15),
    );
    try {
      if (_isAndroid) {
        await device.requestMtu(247);
      }
      final services = await device.discoverServices();
      final service = services.firstWhere(
        (s) => s.uuid == NodeGatt.service,
        orElse: () => throw const BleException('노드 서비스를 찾지 못했습니다'),
      );
      final control = _characteristic(service, NodeGatt.control, '제어');
      final data = _characteristic(service, NodeGatt.data, '데이터');

      final buffer = BytesBuilder(copy: false);
      final done = Completer<Uint8List>();
      int? expected;

      final sub = data.onValueReceived.listen(
        (chunk) {
          if (done.isCompleted) return;
          buffer.add(chunk);
          expected ??= SentinelPacket.expectedLength(buffer.toBytes());
          onProgress?.call(
            BleTransferProgress(received: buffer.length, expected: expected),
          );
          if (expected != null && buffer.length >= expected!) {
            done.complete(buffer.toBytes());
          }
        },
        onError: (Object e) {
          if (!done.isCompleted) done.completeError(e);
        },
      );

      try {
        await data.setNotifyValue(true);
        await control.write(NodeGatt.dumpSince(sinceSeq), withoutResponse: false);
        return await done.future.timeout(
          transferTimeout,
          onTimeout: () => throw BleException(
            '전송이 끊겼습니다 (${buffer.length}/${expected ?? '?'} 바이트)',
          ),
        );
      } finally {
        await sub.cancel();
      }
    } finally {
      await device.disconnect();
    }
  }

  BluetoothCharacteristic _characteristic(
    BluetoothService service,
    Guid uuid,
    String label,
  ) => service.characteristics.firstWhere(
    (c) => c.uuid == uuid,
    orElse: () => throw BleException('$label 캐릭터리스틱이 없습니다'),
  );

  Future<BluetoothDevice> _find({
    String? bleId,
    required Duration timeout,
  }) async {
    // 이미 붙어 있는 기기가 있으면 스캔을 건너뛴다.
    final connected = await FlutterBluePlus.systemDevices([NodeGatt.service]);
    final already = connected.where(_matcher(bleId));
    if (already.isNotEmpty) return already.first;

    final found = Completer<BluetoothDevice>();
    final sub = FlutterBluePlus.onScanResults.listen((results) {
      if (found.isCompleted) return;
      for (final r in results) {
        if (_matcher(bleId)(r.device) ||
            (bleId != null && r.advertisementData.advName == bleId)) {
          found.complete(r.device);
          return;
        }
      }
    });

    try {
      await FlutterBluePlus.startScan(
        withServices: [NodeGatt.service],
        timeout: timeout,
      );
      return await found.future.timeout(
        timeout + const Duration(seconds: 2),
        onTimeout: () => throw const BleException(
          '노드를 찾지 못했습니다. 기기 전원과 거리를 확인하세요',
        ),
      );
    } finally {
      await sub.cancel();
      await FlutterBluePlus.stopScan();
    }
  }

  bool Function(BluetoothDevice) _matcher(String? bleId) => (device) =>
      bleId == null ||
      device.remoteId.str == bleId ||
      device.platformName == bleId;
}

class BleException implements Exception {
  const BleException(this.message);
  final String message;
  @override
  String toString() => message;
}
