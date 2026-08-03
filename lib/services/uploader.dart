import 'package:flutter/foundation.dart';

import '../data/api_client.dart';
import '../data/db.dart';
import '../data/models.dart';

/// SQLite 에 쌓인 미전송 측정값을 서버(→ MongoDB)로 올린다.
///
/// 노드 → 앱(SQLite) → 서버 순서로 흐른다. 앱이 정본을 들고 있으므로
/// 업로드가 실패해도 데이터가 사라지지 않고, 다음 기회에 다시 올린다.
/// 서버가 멱등이라 같은 배치를 여러 번 보내도 안전하다.
class Uploader {
  Uploader({required SentinelDb db, required ApiClient api})
    : _db = db,
      _api = api;

  final SentinelDb _db;
  final ApiClient _api;

  /// 한 번 호출에 최대 [maxBatches] 배치까지 올린다.
  /// 네트워크가 없으면 조용히 0을 돌려주고 다음 기회로 미룬다.
  Future<UploadOutcome> flush({
    int batchSize = 1000,
    int maxBatches = 5,
  }) async {
    var inserted = 0;
    var duplicated = 0;

    for (var i = 0; i < maxBatches; i++) {
      final pending = await _db.pendingUploads(limit: batchSize);
      if (pending.isEmpty) break;

      // 서버는 배치당 기기 하나만 받는다.
      final deviceId = pending.first.deviceId;
      final batch = pending.where((r) => r.deviceId == deviceId).toList();

      try {
        final result = await _api.uploadReadings(
          deviceId: deviceId,
          readings: batch,
        );
        inserted += result.inserted;
        duplicated += result.duplicated;
        await _db.markUploaded(deviceId, [for (final r in batch) r.seq]);
      } on ApiException catch (e) {
        // 오프라인이거나 서버 오류 — 표시하지 않고 다음에 다시 시도한다.
        debugPrint('업로드 보류: $e');
        return UploadOutcome(
          inserted: inserted,
          duplicated: duplicated,
          remaining: await _db.pendingCount(),
          error: e,
        );
      }
    }

    return UploadOutcome(
      inserted: inserted,
      duplicated: duplicated,
      remaining: await _db.pendingCount(),
    );
  }

  /// NFC 로 새로 알게 된 기기를 서버에 등록한다.
  /// 이미 등록돼 있으면 서버가 메타데이터만 갱신한다.
  Future<void> registerIfNeeded(DeviceInfo device, {required String siteId}) =>
      _api.registerDevice(
        deviceId: device.deviceId,
        siteId: siteId,
        siteName: device.siteName,
        bleId: device.bleId,
      );
}

class UploadOutcome {
  const UploadOutcome({
    required this.inserted,
    required this.duplicated,
    required this.remaining,
    this.error,
  });

  final int inserted;
  final int duplicated;

  /// 아직 못 올린 건수.
  final int remaining;
  final ApiException? error;

  bool get isComplete => remaining == 0 && error == null;
}
