import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:sentinel_app/data/air_quality.dart';
import 'package:sentinel_app/data/db.dart';
import 'package:sentinel_app/data/models.dart';
import 'package:sentinel_app/data/reading_repository.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late SentinelDb db;

  setUp(() async {
    db = await SentinelDb.open(path: inMemoryDatabasePath);
  });

  tearDown(() async => db.close());

  Reading reading(int seq, DateTime at, int pm25, int pm10) => Reading(
    deviceId: 'SL-A3F92C',
    seq: seq,
    ts: at.toUtc(),
    pm25: pm25,
    pm10: pm10,
  );

  group('멱등 저장', () {
    test('같은 배치를 다시 넣어도 신규 0건이다', () async {
      final today = DateTime(2026, 8, 3, 9);
      final batch = [
        for (var i = 0; i < 1000; i++)
          reading(i, today.add(Duration(minutes: i)), 20, 40),
      ];

      final first = await db.insertReadings(batch);
      expect(first.inserted, 1000);
      expect(first.duplicated, 0);

      // LTE 음영 지역 재전송 — 100번 보내도 결과가 같아야 한다.
      final second = await db.insertReadings(batch);
      expect(second.inserted, 0);
      expect(second.duplicated, 1000);

      final third = await db.insertReadings(batch);
      expect(third.inserted, 0);
      expect(third.duplicated, 1000);
    });

    test('먼저 도착한 값이 정본이다 (노드가 원본)', () async {
      final at = DateTime(2026, 8, 3, 9);
      await db.insertReadings([reading(0, at, 20, 40)]);
      await db.insertReadings([reading(0, at, 999, 999)]);

      final rows = await db.raw.query('readings');
      expect(rows.length, 1);
      expect(rows.first['pm10'], 40);
    });

    test('lastSeq 로 다음 다운로드 시작점을 잡는다', () async {
      expect(await db.lastSeq('SL-A3F92C'), -1);
      final at = DateTime(2026, 8, 3, 9);
      await db.insertReadings([
        reading(0, at, 20, 40),
        reading(7, at, 20, 40),
        reading(3, at, 20, 40),
      ]);
      expect(await db.lastSeq('SL-A3F92C'), 7);
    });
  });

  group('대시보드 집계', () {
    test('예시 데이터가 설계 문서 그림 3 의 값을 만든다', () async {
      final repo = ReadingRepository(db);
      await repo.seedSampleDataIfEmpty();

      final data = await repo.loadDashboard('SL-A3F92C');

      expect(data.device.siteName, '3공구');
      expect(data.latest!.pm25, 26);
      expect(data.latest!.pm10, 68);
      expect(data.todayMaxPm10, 214);

      // 07~18시 12개 버킷.
      expect(data.buckets.length, 12);
      expect(data.buckets.first.hour.hour, 7);
      expect(data.buckets.last.hour.hour, 18);
      // 차트는 시간당 최대값을 그린다 → 13시 꼭대기가 '오늘 최고 PM10' 과 같아야 한다.
      expect(data.buckets[6].maxPm10, 214); // 13시
      expect(data.buckets[6].maxPm25, 70);
      // 발령 판정용 평균은 최대값보다 낮다 (같은 시간대의 평균/피크 구분).
      expect(data.buckets[6].avgPm10.round(), lessThan(214));

      // 기준 초과 누적 시간 → 화면에는 2.5 시간으로 표시된다.
      final hours = data.exceedDuration.inMinutes / 60;
      expect(hours.toStringAsFixed(1), '2.5');

      // 12·13·14시 평균이 연속 150 이상 → 주의보.
      expect(data.alertLevel, AirAlertLevel.watch);
      expect(data.alerts, hasLength(1));
      expect(data.alerts.first.peakPm10, 214);
    });

    test('데이터가 없으면 빈 화면 상태를 돌려준다', () async {
      final data = await ReadingRepository(db).loadDashboard('없는기기');
      expect(data.isEmpty, isTrue);
      expect(data.buckets, isEmpty);
      expect(data.alertLevel, AirAlertLevel.none);
    });

    test('실제 데이터가 있으면 예시 데이터를 넣지 않는다', () async {
      await db.insertReadings([reading(0, DateTime(2026, 8, 3, 9), 11, 22)]);
      final repo = ReadingRepository(db);
      await repo.seedSampleDataIfEmpty();

      final rows = await db.raw.query('readings');
      expect(rows.length, 1);
    });

    test('한 시간만 기준을 넘으면 주의보가 아니다', () async {
      final today = DateTime(2026, 8, 3);
      await db.upsertDevice(const DeviceInfo(deviceId: 'SL-A3F92C'));
      await db.insertReadings([
        for (var i = 0; i < 60; i++)
          reading(i, today.add(Duration(hours: 9, minutes: i)), 30, 200),
        for (var i = 0; i < 60; i++)
          reading(100 + i, today.add(Duration(hours: 10, minutes: i)), 30, 60),
      ]);

      final data = await ReadingRepository(db).loadDashboard(
        'SL-A3F92C',
        day: today,
      );
      expect(data.buckets.length, 2);
      expect(data.alertLevel, AirAlertLevel.none);
      expect(data.exceedDuration, const Duration(hours: 1));
    });
  });
}
