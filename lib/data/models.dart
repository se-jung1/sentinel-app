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

  /// 트래커가 안 돌아서 headcount 가 인원수가 아니라 0/1 바닥값이다.
  /// **이 값들을 합산해서 사람 수로 쓰면 안 된다.**
  static const noTracker = 0x20;

  /// SEN5x 무응답, 또는 상태 레지스터가 팬/레이저 고장을 알림.
  /// 레이더의 sensorFault 와 분리돼 있다 — 한 노드에 센서가 둘이고 따로 죽는다.
  static const aqFault = 0x40;

  static List<String> describe(int flags) => [
    if (flags & sensorFault != 0) 'sensor_fault',
    if (flags & lowBattery != 0) 'low_battery',
    if (flags & rtcUnset != 0) 'rtc_unset',
    if (flags & calibrating != 0) 'calibrating',
    if (flags & thresholdExceeded != 0) 'threshold_exceeded',
    if (flags & noTracker != 0) 'no_tracker',
    if (flags & aqFault != 0) 'aq_fault',
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

/// 노드가 한 창(기본 30초) 동안 관측한 것 한 줄.
///
/// 공기질 필드가 전부 nullable 인 이유: null 은 "센서가 그 값을 측정하지 않았다" 는
/// 뜻이고, 0 과 절대 같지 않다. SEN50 에는 온습도 센서가 없고, 팬이 멈춘 SEN5x 의
/// PM 0 은 화면에서 "아주 깨끗함" 으로 보인다.
class Reading {
  const Reading({
    required this.deviceId,
    required this.seq,
    required this.ts,
    this.pm25,
    this.pm10,
    this.headcount,
    this.occS,
    this.dwellS,
    this.tempC,
    this.rh,
    this.voc,
    this.flags = 0,
    this.quality = const [],
    this.battery,
  });

  final String deviceId;
  final int seq;

  /// 측정 시각 (UTC).
  final DateTime ts;

  /// µg/m³. null = 측정 안 됨.
  final int? pm25;
  final int? pm10;

  /// 그 창에서 동시에 잡힌 최대 인원. NodeFlags.noTracker 가 서 있으면
  /// 인원수가 아니라 0/1 바닥값이다.
  final int? headcount;

  /// 창 중 점유였던 초.
  final int? occS;

  /// 창이 끝나는 시점의 끊기지 않은 재실 시간(초). 창 경계를 넘어 누적된다.
  final int? dwellS;

  final double? tempC;
  final double? rh;
  final double? voc;

  final int flags;
  final List<String> quality;
  final int? battery;

  Map<String, Object?> toRow() => {
    'device_id': deviceId,
    'seq': seq,
    'ts': ts.millisecondsSinceEpoch ~/ 1000,
    'pm25': pm25,
    'pm10': pm10,
    'headcount': headcount,
    'occ_s': occS,
    'dwell_s': dwellS,
    'temp_c': tempC,
    'rh': rh,
    'voc': voc,
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
    pm25: row['pm25'] as int?,
    pm10: row['pm10'] as int?,
    headcount: row['headcount'] as int?,
    occS: row['occ_s'] as int?,
    dwellS: row['dwell_s'] as int?,
    tempC: (row['temp_c'] as num?)?.toDouble(),
    rh: (row['rh'] as num?)?.toDouble(),
    voc: (row['voc'] as num?)?.toDouble(),
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
