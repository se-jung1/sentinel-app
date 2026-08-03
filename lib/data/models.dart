/// 노드 펌웨어가 레코드에 실어 보내는 상태 비트.
/// 서버(app/models.py)의 flags 비트 정의와 값이 일치해야 한다.
class NodeFlags {
  static const sensorFault = 0x01;
  static const lowBattery = 0x02;

  /// RTC 미탑재/리셋으로 타임스탬프를 신뢰할 수 없음.
  static const rtcUnset = 0x04;
  static const calibrating = 0x08;

  /// 노드가 자체 판단한 임계치 초과.
  static const thresholdExceeded = 0x10;

  static List<String> describe(int flags) => [
    if (flags & sensorFault != 0) 'sensor_fault',
    if (flags & lowBattery != 0) 'low_battery',
    if (flags & rtcUnset != 0) 'rtc_unset',
    if (flags & calibrating != 0) 'calibrating',
    if (flags & thresholdExceeded != 0) 'threshold_exceeded',
  ];
}

/// 앱이 부여하는 품질 태그.
///
/// 이상값 비파기 원칙(설계 결정): 범위를 벗어난 데이터도 버리지 않고
/// 태그만 붙여 저장한다. 안전관리 데이터는 법적 증빙이 될 수 있다.
class QualityTag {
  static const tsFuture = 'ts_future';
  static const tsStale = 'ts_stale';
}

class Reading {
  const Reading({
    required this.deviceId,
    required this.seq,
    required this.ts,
    required this.pm25,
    required this.pm10,
    this.flags = 0,
    this.quality = const [],
    this.battery,
  });

  final String deviceId;
  final int seq;

  /// 측정 시각 (UTC).
  final DateTime ts;
  final int pm25;
  final int pm10;
  final int flags;
  final List<String> quality;
  final int? battery;

  Map<String, Object?> toRow() => {
    'device_id': deviceId,
    'seq': seq,
    'ts': ts.millisecondsSinceEpoch ~/ 1000,
    'pm25': pm25,
    'pm10': pm10,
    'flags': flags,
    'quality': quality.join(','),
    'battery': battery,
  };

  static Reading fromRow(Map<String, Object?> row) => Reading(
    deviceId: row['device_id']! as String,
    seq: row['seq']! as int,
    ts: DateTime.fromMillisecondsSinceEpoch(
      (row['ts']! as int) * 1000,
      isUtc: true,
    ),
    pm25: row['pm25']! as int,
    pm10: row['pm10']! as int,
    flags: (row['flags'] as int?) ?? 0,
    quality: ((row['quality'] as String?) ?? '')
        .split(',')
        .where((e) => e.isNotEmpty)
        .toList(),
    battery: row['battery'] as int?,
  );
}

class DeviceInfo {
  const DeviceInfo({
    required this.deviceId,
    this.siteName,
    this.bleId,
    this.lastSyncAt,
  });

  final String deviceId;

  /// 소속 공구 (예: '3공구').
  final String? siteName;

  /// BLE 스캔에 사용할 광고 이름 또는 remoteId.
  final String? bleId;
  final DateTime? lastSyncAt;

  Map<String, Object?> toRow() => {
    'device_id': deviceId,
    'site_name': siteName,
    'ble_id': bleId,
    'last_sync_at': lastSyncAt == null
        ? null
        : lastSyncAt!.millisecondsSinceEpoch ~/ 1000,
  };

  static DeviceInfo fromRow(Map<String, Object?> row) => DeviceInfo(
    deviceId: row['device_id']! as String,
    siteName: row['site_name'] as String?,
    bleId: row['ble_id'] as String?,
    lastSyncAt: row['last_sync_at'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            (row['last_sync_at']! as int) * 1000,
            isUtc: true,
          ),
  );
}
