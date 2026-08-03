import 'package:flutter/material.dart';

import '../data/air_quality.dart';
import '../theme.dart';

/// 화면 상단 상태 배지.
///
/// 주의보·경보가 발령된 상태면 그것을 보여주고,
/// 아니면 현재 값의 에어코리아 예보등급(좋음/보통/나쁨/매우나쁨)을 보여준다.
class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.alertLevel, this.grade});

  final AirAlertLevel alertLevel;
  final AirGrade? grade;

  @override
  Widget build(BuildContext context) {
    final (label, fg, bg) = switch (alertLevel) {
      AirAlertLevel.alert => (
        '경보',
        SentinelColors.dangerFg,
        SentinelColors.dangerBg,
      ),
      AirAlertLevel.watch => (
        '주의보',
        SentinelColors.warnFg,
        SentinelColors.warnBg,
      ),
      AirAlertLevel.none => (
        grade?.label ?? '데이터 없음',
        grade?.fg ?? SentinelColors.textSecondary,
        grade?.bg ?? SentinelColors.border,
      ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: fg,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          height: 1.2,
        ),
      ),
    );
  }
}
