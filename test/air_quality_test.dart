import 'package:flutter_test/flutter_test.dart';
import 'package:sentinel_app/data/air_quality.dart';

void main() {
  group('에어코리아 예보등급 경계값', () {
    test('PM10 0~30 좋음 / 31~80 보통 / 81~150 나쁨 / 151~ 매우나쁨', () {
      expect(AirKorea.gradePm10(0), AirGrade.good);
      expect(AirKorea.gradePm10(30), AirGrade.good);
      expect(AirKorea.gradePm10(31), AirGrade.normal);
      expect(AirKorea.gradePm10(80), AirGrade.normal);
      expect(AirKorea.gradePm10(81), AirGrade.bad);
      expect(AirKorea.gradePm10(150), AirGrade.bad);
      expect(AirKorea.gradePm10(151), AirGrade.veryBad);
    });

    test('PM2.5 0~15 좋음 / 16~35 보통 / 36~75 나쁨 / 76~ 매우나쁨', () {
      expect(AirKorea.gradePm25(15), AirGrade.good);
      expect(AirKorea.gradePm25(16), AirGrade.normal);
      expect(AirKorea.gradePm25(35), AirGrade.normal);
      expect(AirKorea.gradePm25(36), AirGrade.bad);
      expect(AirKorea.gradePm25(75), AirGrade.bad);
      expect(AirKorea.gradePm25(76), AirGrade.veryBad);
    });
  });

  group('주의보·경보 발령 (시간당 평균 2시간 이상 지속)', () {
    test('1시간만 넘으면 발령하지 않는다', () {
      expect(AirKorea.alertLevelPm10([100, 160, 90]), AirAlertLevel.none);
    });

    test('2시간 연속 150 이상이면 주의보', () {
      expect(AirKorea.alertLevelPm10([100, 160, 155, 90]), AirAlertLevel.watch);
    });

    test('끊겼다 다시 넘는 것은 지속으로 보지 않는다', () {
      expect(AirKorea.alertLevelPm10([160, 90, 160, 90]), AirAlertLevel.none);
    });

    test('2시간 연속 300 이상이면 경보', () {
      expect(AirKorea.alertLevelPm10([320, 310]), AirAlertLevel.alert);
    });

    test('PM2.5 는 75 / 150 기준을 쓴다', () {
      expect(AirKorea.alertLevelPm25([80, 90]), AirAlertLevel.watch);
      expect(AirKorea.alertLevelPm25([160, 155]), AirAlertLevel.alert);
      expect(AirKorea.alertLevelPm25([70, 74]), AirAlertLevel.none);
    });
  });
}
