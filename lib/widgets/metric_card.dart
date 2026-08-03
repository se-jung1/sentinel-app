import 'package:flutter/material.dart';

import '../theme.dart';

/// 요약 지표 카드 — 라벨 / 큰 숫자 / 작은 단위.
class MetricCard extends StatelessWidget {
  const MetricCard({
    super.key,
    required this.label,
    required this.value,
    this.unit,
    this.emphasize = false,
  });

  final String label;
  final String value;
  final String? unit;

  /// 임계치를 넘은 값은 색으로 구분한다.
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: SentinelColors.textSecondary,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    height: 1.1,
                    color: emphasize
                        ? SentinelColors.dangerFg
                        : SentinelColors.textPrimary,
                  ),
                ),
              ),
              if (unit != null) ...[
                const SizedBox(width: 4),
                Text(
                  unit!,
                  style: const TextStyle(
                    fontSize: 12,
                    color: SentinelColors.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
