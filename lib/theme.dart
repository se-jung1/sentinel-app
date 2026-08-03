import 'package:flutter/material.dart';

/// 설계 문서 그림 3 (모바일 앱 계측 화면)의 색·타이포를 그대로 옮긴 값.
class SentinelColors {
  static const page = Color(0xFFF7F6F4);
  static const surface = Color(0xFFFFFFFF);
  static const border = Color(0xFFE7E4DE);

  static const textPrimary = Color(0xFF1B1B1B);
  static const textSecondary = Color(0xFF6E6E6E);
  static const textMuted = Color(0xFF9A9A9A);

  static const pm25 = Color(0xFF3B6FD1);
  static const pm10 = Color(0xFFC0632E);
  static const threshold = Color(0xFF8A8A8A);

  /// 상태 배지 — 정상 / 주의 / 위험
  static const okBg = Color(0xFFDDEBDC);
  static const okFg = Color(0xFF2F5D2C);
  static const warnBg = Color(0xFFEDE0C0);
  static const warnFg = Color(0xFF7A5B18);
  static const dangerBg = Color(0xFFF3D6D0);
  static const dangerFg = Color(0xFF8C2F1B);
}

ThemeData buildSentinelTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: SentinelColors.pm25,
      surface: SentinelColors.surface,
    ),
    scaffoldBackgroundColor: SentinelColors.page,
  );

  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: SentinelColors.textPrimary,
      displayColor: SentinelColors.textPrimary,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: SentinelColors.page,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
    ),
    dividerTheme: const DividerThemeData(
      color: SentinelColors.border,
      thickness: 1,
      space: 1,
    ),
  );
}

/// 카드 공통 외곽선. 화면 전체에서 이 하나만 사용한다.
BoxDecoration cardDecoration({Color? color}) => BoxDecoration(
  color: color ?? SentinelColors.surface,
  borderRadius: BorderRadius.circular(12),
  border: Border.all(color: SentinelColors.border),
);
