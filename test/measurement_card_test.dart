import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentinel_app/data/air_quality.dart';
import 'package:sentinel_app/data/models.dart';
import 'package:sentinel_app/data/reading_repository.dart';
import 'package:sentinel_app/screens/dashboard_screen.dart';
import 'package:sentinel_app/theme.dart';

/// 설계 문서 그림 3 과 같은 값이 화면에 나오는지 본다.
void main() {
  final today = DateTime(2026, 8, 3);

  DashboardData build({
    int pm25 = 26,
    int pm10 = 68,
    int maxPm10 = 214,
    AirAlertLevel level = AirAlertLevel.watch,
  }) {
    const hourly = <int, (int, int)>{
      7: (20, 45), 8: (24, 62), 9: (29, 88), 10: (35, 112),
      11: (43, 132), 12: (57, 162), 13: (70, 214), 14: (64, 152),
      15: (50, 120), 16: (41, 100), 17: (33, 80), 18: (26, 68),
    };

    return DashboardData(
      device: DeviceInfo(
        deviceId: 'SL-A3F92C',
        siteName: '3공구',
        lastSyncAt: DateTime.now().toUtc().subtract(const Duration(minutes: 2)),
      ),
      latest: Reading(
        deviceId: 'SL-A3F92C',
        seq: 719,
        ts: today.add(const Duration(hours: 18, minutes: 59)).toUtc(),
        pm25: pm25,
        pm10: pm10,
      ),
      todayMaxPm10: maxPm10,
      exceedDuration: const Duration(minutes: 148),
      buckets: [
        for (final e in hourly.entries)
          HourBucket(
            hour: today.add(Duration(hours: e.key)),
            avgPm25: e.value.$1.toDouble(),
            maxPm25: e.value.$1,
            avgPm10: e.value.$2.toDouble(),
            maxPm10: e.value.$2,
          ),
      ],
      alerts: [
        AlertEvent(
          peakAt: today.add(const Duration(hours: 13, minutes: 30)),
          peakPm10: 214,
          duration: const Duration(minutes: 148),
        ),
      ],
      alertLevel: level,
    );
  }

  Future<void> pump(WidgetTester tester, DashboardData data) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSentinelTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: MeasurementCard(data: data),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('기기 ID·공구·동기화 시각과 상태 배지를 보여준다', (tester) async {
    await pump(tester, build());

    expect(find.text('SL-A3F92C'), findsOneWidget);
    expect(find.text('3공구 · 2분 전 동기화'), findsOneWidget);
    expect(find.text('주의보'), findsOneWidget);
  });

  testWidgets('요약 지표 카드 4종을 보여준다', (tester) async {
    await pump(tester, build());

    expect(find.text('PM2.5'), findsWidgets);
    expect(find.text('26'), findsOneWidget);
    expect(find.text('68'), findsOneWidget);
    expect(find.text('오늘 최고 PM10'), findsOneWidget);
    expect(find.text('214'), findsOneWidget);
    expect(find.text('기준 초과'), findsOneWidget);
    expect(find.text('2.5'), findsOneWidget); // 148분 → 2.5시간
  });

  testWidgets('차트 범례에 에어코리아 주의보 기준 150 이 나온다', (tester) async {
    await pump(tester, build());

    expect(find.text('PM10 (점선)'), findsOneWidget);
    expect(find.text('주의보 기준 150'), findsOneWidget);
  });

  testWidgets('경보 이력 줄을 보여준다', (tester) async {
    await pump(tester, build());

    expect(
      find.textContaining('PM10 214 µg/m³ · 2시간 28분'),
      findsOneWidget,
    );
  });

  testWidgets('발령이 없으면 배지에 예보등급이 나온다', (tester) async {
    await pump(
      tester,
      build(pm25: 10, pm10: 20, maxPm10: 40, level: AirAlertLevel.none),
    );

    expect(find.text('좋음'), findsOneWidget);
  });
}
