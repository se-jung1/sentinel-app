import 'dart:ui' show Color;

/// 에어코리아(한국환경공단) 미세먼지 예보등급 및
/// 「대기환경보전법」상 미세먼지 주의보·경보 발령기준.
///
/// 출처
/// - 예보등급: 에어코리아 대기질 예보 (PM10 0~30 좋음 / 31~80 보통 /
///   81~150 나쁨 / 151~ 매우나쁨, PM2.5 0~15 / 16~35 / 36~75 / 76~)
/// - 발령기준: 대기환경보전법 제8조제4항, 같은 법 시행령 제2조제3항
///   (시간당 평균 농도가 기준치 이상으로 2시간 이상 지속될 때 발령)
class AirKorea {
  // ── 예보등급 경계값 (이하 기준) ──────────────────────────────
  static const pm10Good = 30;
  static const pm10Normal = 80;
  static const pm10Bad = 150;

  static const pm25Good = 15;
  static const pm25Normal = 35;
  static const pm25Bad = 75;

  // ── 주의보·경보 발령기준 (시간당 평균, 2시간 이상 지속) ──────
  static const pm10Watch = 150; // 주의보
  static const pm10Alert = 300; // 경보
  static const pm25Watch = 75;
  static const pm25Alert = 150;

  /// 발령 판정에 필요한 지속 시간.
  static const sustained = Duration(hours: 2);

  static AirGrade gradePm10(num value) {
    if (value <= pm10Good) return AirGrade.good;
    if (value <= pm10Normal) return AirGrade.normal;
    if (value <= pm10Bad) return AirGrade.bad;
    return AirGrade.veryBad;
  }

  static AirGrade gradePm25(num value) {
    if (value <= pm25Good) return AirGrade.good;
    if (value <= pm25Normal) return AirGrade.normal;
    if (value <= pm25Bad) return AirGrade.bad;
    return AirGrade.veryBad;
  }

  /// 시간당 평균 농도 목록에서 발령 단계를 판정한다.
  ///
  /// [hourlyAverages] 는 시간 순으로 정렬된, 연속된 시간대의 평균값이어야 한다.
  /// (중간이 비면 지속이 끊긴 것으로 본다 — 호출부에서 빈 시간대를 걸러 넘긴다)
  static AirAlertLevel alertLevelPm10(List<double> hourlyAverages) =>
      _sustainedLevel(
        hourlyAverages,
        watch: pm10Watch,
        alert: pm10Alert,
      );

  static AirAlertLevel alertLevelPm25(List<double> hourlyAverages) =>
      _sustainedLevel(
        hourlyAverages,
        watch: pm25Watch,
        alert: pm25Alert,
      );

  static AirAlertLevel _sustainedLevel(
    List<double> hourly, {
    required int watch,
    required int alert,
  }) {
    final needed = sustained.inHours;
    var watchRun = 0;
    var alertRun = 0;
    var result = AirAlertLevel.none;

    for (final v in hourly) {
      alertRun = v >= alert ? alertRun + 1 : 0;
      watchRun = v >= watch ? watchRun + 1 : 0;
      if (alertRun >= needed) return AirAlertLevel.alert;
      if (watchRun >= needed) result = AirAlertLevel.watch;
    }
    return result;
  }
}

enum AirGrade {
  good('좋음', Color(0xFF3B6FD1), Color(0xFFDCE6F7)),
  normal('보통', Color(0xFF2F7D4F), Color(0xFFDDEBDC)),
  bad('나쁨', Color(0xFF7A5B18), Color(0xFFEDE0C0)),
  veryBad('매우나쁨', Color(0xFF8C2F1B), Color(0xFFF3D6D0));

  const AirGrade(this.label, this.fg, this.bg);
  final String label;
  final Color fg;
  final Color bg;
}

enum AirAlertLevel {
  none(null),
  watch('주의보'),
  alert('경보');

  const AirAlertLevel(this.label);
  final String? label;
}
