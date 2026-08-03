import 'package:flutter/foundation.dart';

import '../config.dart';
import '../data/api_client.dart';
import '../data/db.dart';
import '../data/models.dart';
import '../data/packet.dart';
import 'ble_service.dart';
import 'nfc_service.dart';
import 'uploader.dart';

enum SyncPhase {
  /// 대기 — 태그를 갖다 대기 전.
  idle,

  /// NFC 세션이 열려 태그를 기다리는 중.
  waitingTag,

  /// 태그를 읽고 노드에 접속하는 중.
  connecting,

  /// 바이너리 프레임 수신 중.
  downloading,

  /// 파싱 후 SQLite 저장 중.
  saving,

  /// 서버(MongoDB)로 올리는 중. 실패해도 저장은 이미 끝나 있다.
  uploading,
  done,
  failed,
}

/// NFC 태깅 → BLE 다운로드 → 파싱 → SQLite 저장을 한 줄로 엮는다.
///
/// 태그가 프레임을 통째로 담고 있으면 BLE 단계는 건너뛴다.
class SyncController extends ChangeNotifier {
  SyncController({
    required SentinelDb db,
    NfcService? nfc,
    BleService? ble,
    Uploader? uploader,
  }) : _db = db,
       _uploader = uploader,
       _nfc = nfc ?? NfcService(),
       _ble = ble ?? BleService();

  final SentinelDb _db;
  final NfcService _nfc;
  final BleService _ble;

  /// null 이면 서버 업로드를 건너뛴다 (SQLite 만 쓰는 구성).
  final Uploader? _uploader;

  BleService get ble => _ble;
  NfcService get nfc => _nfc;

  SyncPhase _phase = SyncPhase.idle;
  SyncPhase get phase => _phase;

  BleTransferProgress? _progress;
  BleTransferProgress? get progress => _progress;

  String? _deviceId;
  String? get deviceId => _deviceId;

  InsertResult? _result;
  InsertResult? get result => _result;

  String? _error;
  String? get error => _error;

  bool get isBusy =>
      _phase != SyncPhase.idle &&
      _phase != SyncPhase.done &&
      _phase != SyncPhase.failed;

  void _set(SyncPhase phase, {String? error}) {
    _phase = phase;
    _error = error;
    notifyListeners();
  }

  /// NFC 세션을 열고 태그를 기다린다.
  Future<void> start() async {
    if (isBusy) return;
    _progress = null;
    _result = null;
    _deviceId = null;
    _set(SyncPhase.waitingTag);

    await _nfc.startSession(
      onResult: (scan) async {
        try {
          await _handle(scan);
        } catch (e) {
          _set(SyncPhase.failed, error: '$e');
        }
      },
      onError: (e) {
        // 사용자가 iOS 팝업을 닫은 경우까지 실패로 표시하지는 않는다.
        if (_phase == SyncPhase.waitingTag) {
          _set(SyncPhase.idle);
        } else {
          _set(SyncPhase.failed, error: '$e');
        }
      },
    );
  }

  Future<void> cancel() async {
    await _nfc.stopSession();
    _set(SyncPhase.idle);
  }

  Future<void> _handle(NfcScanResult scan) async {
    final bytes = switch (scan) {
      // 태그 자체에 프레임이 들어 있던 경우 — BLE 없이 바로 저장.
      NfcFrameResult(bytes: final b) => b,
      NfcHandshakeResult(handshake: final h) => await _downloadOverBle(h),
    };

    _set(SyncPhase.saving);
    final packet = SentinelPacket.parse(bytes);
    _deviceId = packet.deviceId;

    final existing = await _db.device(packet.deviceId);
    if (existing == null) {
      await _db.upsertDevice(DeviceInfo(deviceId: packet.deviceId));
    }
    _result = await _db.insertReadings(packet.readings);
    await _db.touchLastSync(packet.deviceId, DateTime.now().toUtc());

    await _upload(packet.deviceId);
    _set(SyncPhase.done);
  }

  /// 서버로 밀어 올린다. 실패해도 SQLite 에는 이미 저장돼 있으므로
  /// 동기화 자체는 성공으로 본다 — 다음 기회에 다시 올린다.
  Future<void> _upload(String deviceId) async {
    final uploader = _uploader;
    if (uploader == null) return;

    _set(SyncPhase.uploading);
    try {
      await uploader.registerIfNeeded(
        await _db.device(deviceId) ?? DeviceInfo(deviceId: deviceId),
        siteId: AppConfig.defaultSiteId,
      );
    } on ApiException catch (e) {
      debugPrint('기기 등록 보류: $e');
    }
    _uploadOutcome = await uploader.flush();
  }

  UploadOutcome? _uploadOutcome;

  /// 마지막 업로드 결과. null 이면 서버를 쓰지 않는 구성이다.
  UploadOutcome? get uploadOutcome => _uploadOutcome;

  Future<Uint8List> _downloadOverBle(NodeHandshake handshake) async {
    _deviceId = handshake.deviceId;
    _set(SyncPhase.connecting);

    await _db.upsertDevice(
      DeviceInfo(
        deviceId: handshake.deviceId,
        siteName: handshake.siteName,
        bleId: handshake.bleId,
      ),
    );

    if (!await _ble.ensurePermissions()) {
      throw const BleException('블루투스 권한이 필요합니다');
    }

    final sinceSeq = await _db.lastSeq(handshake.deviceId);
    return _ble.download(
      sinceSeq: sinceSeq,
      bleId: handshake.bleId,
      onProgress: (p) {
        _progress = p;
        if (_phase != SyncPhase.downloading) {
          _phase = SyncPhase.downloading;
        }
        notifyListeners();
      },
    );
  }

  @override
  void dispose() {
    _nfc.stopSession();
    super.dispose();
  }
}
