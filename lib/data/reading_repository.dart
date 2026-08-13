import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'air_quality.dart';
import 'api_client.dart';
import 'db.dart';
import 'models.dart';

/// 화면에 그려진 데이터가 어디서 왔는지.
enum DashboardSource {
  /// 서버(MongoDB) 집계 결과.
  remote('클라우드'),

  /// 서버에 못 붙어 기기에 저장된 값으로 그림.
  local('오프라인');

  const DashboardSource(this.label);
  final String label;
}

/// 노드 측정 주기.
///
/// ⚠ exceed_minutes 를 '초과 레코드 수 × 측정 주기' 로 환산하므로
/// 펌웨어 측정 주기가 바뀌면 이 값을 함께 고쳐야 한다.
const samplePeriod = Duration(minutes: 1);

class HourBucket {
  const HourBucket({
    required this.hour,
    required this.avgPm25,
    required this.maxPm25,
    required this.avgPm10,
    required this.maxPm10,
  });

  /// 버킷 시작 시각 (로컬).
  final DateTime hour;
  final double avgPm25;
  final int maxPm25;
  final double avgPm10;
  final int maxPm10;
}

class AlertEvent {
  const AlertEvent({
    required this.peakAt,
    required this.peakPm10,
    required this.duration,
  });

  final DateTime peakAt;
  final int peakPm10;
  final Duration duration;
}

class DashboardData {
  const DashboardData({
    required this.device,
    required this.latest,
    required this.todayMaxPm10,
    required this.exceedDuration,
    required this.buckets,
    required this.alerts,
    required this.alertLevel,
    this.source = DashboardSource.local,
  });

  final DashboardSource source;

  final DeviceInfo device;
  final Reading? latest;
  final int todayMaxPm10;

  /// 오늘 PM10 이 주의보 기준(150) 이상이었던 누적 시간.
  final Duration exceedDuration;
  final List<HourBucket> buckets;
  final List<AlertEvent> alerts;

  /// 시간당 평균 기준으로 판정한 발령 단계 (대기환경보전법).
  final AirAlertLevel alertLevel;

  bool get isEmpty => latest == null;

  /// 현재 값의 에어코리아 예보등급. PM2.5/PM10 중 나쁜 쪽을 따른다.
  AirGrade? get currentGrade {
    final now = latest;
    if (now == null) return null;
    // 측정 안 된 쪽은 판정에서 빠진다. 둘 다 없으면 등급도 없다 —
    // 없는 값을 0 으로 읽어 '좋음' 이라고 하는 게 최악이다.
    final pm25 = now.pm25, pm10 = now.pm10;
    final a = pm25 == null ? null : AirKorea.gradePm25(pm25);
    final b = pm10 == null ? null : AirKorea.gradePm10(pm10);
    if (a == null || b == null) return a ?? b;
    return a.index >= b.index ? a : b;
  }
}

class ReadingRepository {
  ReadingRepository(this._db, {ApiClient? api}) : _api = api;

  final SentinelDb _db;

  /// null 이면 서버를 쓰지 않고 SQLite 만 읽는다.
  final ApiClient? _api;

  /// 화면 데이터를 서버(MongoDB)에서 먼저 가져오고, 실패하면 SQLite 로 떨어진다.
  ///
  /// 설계 문서 3.4 의 '클라우드 연결 상태와 무관하게 동작한다' 를 지키면서
  /// 평상시에는 MongoDB 집계 결과를 그린다. 어느 쪽으로 그렸는지는
  /// [DashboardData.source] 에 담겨 화면에 표시된다.
  Future<DashboardData> loadDashboard(String deviceId, {DateTime? day}) async {
    final api = _api;
    // 과거 날짜 조회는 서버 요약 엔드포인트가 '오늘' 만 다루므로 로컬로 간다.
    if (api != null && day == null) {
      try {
        return _fromRemote(await api.deviceSummary(deviceId));
      } on ApiException catch (e) {
        debugPrint('서버 조회 실패 — 로컬 데이터로 그립니다: $e');
      }
    }
    return loadLocalDashboard(deviceId, day: day);
  }

  DashboardData _fromRemote(RemoteSummary summary) {
    final buckets = [
      for (final p in summary.hourly)
        HourBucket(
          hour: p.ts.toLocal(),
          avgPm25: p.pm25Avg,
          maxPm25: p.pm25Max,
          avgPm10: p.pm10Avg,
          maxPm10: p.pm10Max,
        ),
    ];

    return DashboardData(
      device: summary.device,
      latest: summary.latest,
      todayMaxPm10: summary.todayMaxPm10,
      exceedDuration: Duration(minutes: summary.exceedMinutes),
      buckets: buckets,
      alerts: _alertsFromBuckets(buckets),
      alertLevel: summary.alertLevel,
      source: DashboardSource.remote,
    );
  }

  /// 서버 요약에는 경보 이력이 없어 시간 버킷에서 되만든다.
  /// 로컬(분 단위)보다 거칠지만 화면에 쓰기에는 충분하다.
  List<AlertEvent> _alertsFromBuckets(List<HourBucket> buckets) {
    final events = <AlertEvent>[];
    HourBucket? peak;
    var hours = 0;

    void flush() {
      if (peak != null) {
        events.add(
          AlertEvent(
            peakAt: peak!.hour,
            peakPm10: peak!.maxPm10,
            duration: Duration(hours: hours),
          ),
        );
      }
      peak = null;
      hours = 0;
    }

    for (final b in buckets) {
      if (b.maxPm10 >= AirKorea.pm10Watch) {
        hours++;
        if (peak == null || b.maxPm10 > peak!.maxPm10) peak = b;
      } else {
        flush();
      }
    }
    flush();
    return events.reversed.toList();
  }

  /// SQLite 만 읽는 경로. 오프라인이거나 과거 날짜를 볼 때 쓴다.
  Future<DashboardData> loadLocalDashboard(
    String deviceId, {
    DateTime? day,
  }) async {
    final device =
        await _db.device(deviceId) ?? DeviceInfo(deviceId: deviceId);

    final base = day ?? DateTime.now();
    final from = DateTime(base.year, base.month, base.day);
    final to = from.add(const Duration(days: 1));
    final fromTs = from.millisecondsSinceEpoch ~/ 1000;
    final toTs = to.millisecondsSinceEpoch ~/ 1000;
    // 로컬 시간대로 버킷을 나누기 위한 오프셋. SQLite 에는 시간대 개념이 없다.
    final offset = from.timeZoneOffset.inSeconds;

    final latestRows = await _db.raw.query(
      'readings',
      where: 'device_id = ?',
      whereArgs: [deviceId],
      orderBy: 'ts DESC',
      limit: 1,
    );

    final todayRows = await _db.raw.rawQuery(
      '''
      SELECT MAX(pm10) AS max_pm10,
             SUM(CASE WHEN pm10 >= ? THEN 1 ELSE 0 END) AS exceed_count
      FROM readings
      WHERE device_id = ? AND ts >= ? AND ts < ?
      ''',
      [AirKorea.pm10Watch, deviceId, fromTs, toTs],
    );

    final bucketRows = await _db.raw.rawQuery(
      '''
      SELECT ((ts + ?) / 3600) AS bucket,
             AVG(pm25) AS avg_pm25, MAX(pm25) AS max_pm25,
             AVG(pm10) AS avg_pm10, MAX(pm10) AS max_pm10
      FROM readings
      WHERE device_id = ? AND ts >= ? AND ts < ?
      GROUP BY bucket
      ORDER BY bucket
      ''',
      [offset, deviceId, fromTs, toTs],
    );

    final buckets = bucketRows.map((r) {
      final bucket = (r['bucket']! as num).toInt();
      return HourBucket(
        hour: DateTime.fromMillisecondsSinceEpoch(
          (bucket * 3600 - offset) * 1000,
        ),
        avgPm25: (r['avg_pm25']! as num).toDouble(),
        maxPm25: (r['max_pm25']! as num).toInt(),
        avgPm10: (r['avg_pm10']! as num).toDouble(),
        maxPm10: (r['max_pm10']! as num).toInt(),
      );
    }).toList();

    final exceedCount = (todayRows.first['exceed_count'] as int?) ?? 0;

    return DashboardData(
      device: device,
      latest: latestRows.isEmpty ? null : Reading.fromRow(latestRows.first),
      todayMaxPm10: (todayRows.first['max_pm10'] as int?) ?? 0,
      exceedDuration: samplePeriod * exceedCount,
      buckets: buckets,
      alerts: await _alerts(deviceId, fromTs, toTs),
      alertLevel: _alertLevel(buckets),
    );
  }

  /// 발령 판정은 '시간당 평균 농도가 2시간 이상 지속' 이므로
  /// 시간이 끊긴 구간은 별개 구간으로 끊어서 넘긴다.
  AirAlertLevel _alertLevel(List<HourBucket> buckets) {
    var worst = AirAlertLevel.none;
    var run = <double>[];

    void flush() {
      if (run.isEmpty) return;
      final level = AirKorea.alertLevelPm10(run);
      if (level.index > worst.index) worst = level;
      run = [];
    }

    for (var i = 0; i < buckets.length; i++) {
      if (i > 0 &&
          buckets[i].hour.difference(buckets[i - 1].hour) !=
              const Duration(hours: 1)) {
        flush();
      }
      run.add(buckets[i].avgPm10);
    }
    flush();
    return worst;
  }

  /// 임계치를 넘은 연속 구간을 하나의 경보 이력으로 묶는다.
  /// 측정 주기의 3배 이상 끊기면 별개 이력으로 본다.
  Future<List<AlertEvent>> _alerts(String deviceId, int fromTs, int toTs) async {
    final rows = await _db.raw.query(
      'readings',
      columns: ['ts', 'pm10'],
      where: 'device_id = ? AND ts >= ? AND ts < ? AND pm10 >= ?',
      whereArgs: [deviceId, fromTs, toTs, AirKorea.pm10Watch],
      orderBy: 'ts',
    );
    if (rows.isEmpty) return const [];

    final gap = samplePeriod.inSeconds * 3;
    final events = <AlertEvent>[];
    var startTs = rows.first['ts']! as int;
    var prevTs = startTs;
    var peakTs = startTs;
    var peak = rows.first['pm10']! as int;

    void flush() {
      events.add(
        AlertEvent(
          peakAt: DateTime.fromMillisecondsSinceEpoch(peakTs * 1000),
          peakPm10: peak,
          duration: Duration(seconds: prevTs - startTs) + samplePeriod,
        ),
      );
    }

    for (final row in rows.skip(1)) {
      final ts = row['ts']! as int;
      final pm10 = row['pm10']! as int;
      if (ts - prevTs > gap) {
        flush();
        startTs = ts;
        peakTs = ts;
        peak = pm10;
      } else if (pm10 > peak) {
        peak = pm10;
        peakTs = ts;
      }
      prevTs = ts;
    }
    flush();

    // 최근 이력이 위로 오도록.
    return events.reversed.toList();
  }

  /// 설계 검토용 예시 데이터.
  ///
  /// 설계 문서 그림 3 과 같은 화면이 나오도록 07:00~18:59 구간을
  /// 1분 주기로 채운다. 실제 노드 데이터가 한 건이라도 있으면 아무것도 하지 않는다.
  /// 데모가 끝나면 이 메서드와 호출부만 지우면 된다.
  Future<void> seedSampleDataIfEmpty({String deviceId = 'SL-A3F92C'}) async {
    final existing = await _db.raw.rawQuery(
      'SELECT COUNT(*) AS c FROM readings',
    );
    if (((existing.first['c'] as int?) ?? 0) > 0) return;

    // 시각별 앵커 (매시 30분 기준). 시간 단위 평균이 이 값이 된다.
    const pm25Anchors = <int, int>{
      7: 20, 8: 24, 9: 29, 10: 35, 11: 43, 12: 57,
      13: 70, 14: 64, 15: 50, 16: 41, 17: 33, 18: 26,
    };
    const pm10Anchors = <int, int>{
      7: 45, 8: 62, 9: 88, 10: 112, 11: 132, 12: 162,
      13: 214, 14: 152, 15: 120, 16: 100, 17: 80, 18: 68,
    };

    double interpolate(Map<int, int> anchors, double hour) {
      final first = anchors.keys.first;
      final last = anchors.keys.last;
      // 앵커는 매시 30분이므로 07:30 이전 / 18:30 이후는 양 끝 값을 유지한다.
      if (hour <= first + 0.5) return anchors[first]!.toDouble();
      if (hour >= last + 0.5) return anchors[last]!.toDouble();
      final h = (hour - 0.5).floor();
      final t = (hour - 0.5) - h;
      final a = anchors[h]!.toDouble();
      final b = anchors[h + 1]!.toDouble();
      return a + (b - a) * t;
    }

    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day, 7);
    final readings = <Reading>[];
    for (var i = 0; i < 12 * 60; i++) {
      final at = start.add(Duration(minutes: i));
      final hour = 7 + i / 60.0;
      final pm10 = interpolate(pm10Anchors, hour).round();
      readings.add(
        Reading(
          deviceId: deviceId,
          seq: i,
          ts: at.toUtc(),
          pm25: interpolate(pm25Anchors, hour).round(),
          pm10: pm10,
          flags: pm10 >= AirKorea.pm10Watch ? NodeFlags.thresholdExceeded : 0,
          battery: math.max(60, 100 - i ~/ 30),
        ),
      );
    }

    await _db.upsertDevice(
      DeviceInfo(
        deviceId: deviceId,
        siteName: '3공구',
        lastSyncAt: DateTime.now().toUtc().subtract(const Duration(minutes: 2)),
      ),
    );
    await _db.insertReadings(readings);
  }
}
