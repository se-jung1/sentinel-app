import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../data/air_quality.dart';
import '../data/reading_repository.dart';
import '../theme.dart';

/// 시간대별 PM2.5 / PM10 추이.
///
/// 선은 시간당 **최대값**을 그린다 — 안전관리에서는 순간 피크가 일평균보다
/// 중요하고, '오늘 최고 PM10' 카드와 차트 꼭대기가 어긋나면 안 되기 때문이다.
/// 주의보·경보 발령 판정은 법령상 시간당 평균 기준이므로 그쪽은 평균을 쓴다
/// (ReadingRepository._alertLevel). 툴팁에서 두 값을 함께 보여준다.
class TrendChart extends StatelessWidget {
  const TrendChart({super.key, required this.buckets});

  final List<HourBucket> buckets;

  @override
  Widget build(BuildContext context) {
    if (buckets.isEmpty) {
      return const SizedBox(
        height: 220,
        child: Center(
          child: Text(
            '오늘 수집된 데이터가 없습니다',
            style: TextStyle(color: SentinelColors.textMuted, fontSize: 13),
          ),
        ),
      );
    }

    final peak = buckets
        .expand((b) => [b.maxPm10, b.maxPm25])
        .nonNulls
        .map((v) => v.toDouble())
        .fold<double>(AirKorea.pm10Watch.toDouble(), (a, b) => a > b ? a : b);
    // 주의보 기준선이 항상 보이도록 최소 높이를 확보하고 20 단위로 올림한다.
    final maxY = ((peak * 1.12) / 20).ceil() * 20.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Legend(),
        const SizedBox(height: 12),
        AspectRatio(
          aspectRatio: 1.6,
          child: LineChart(
            LineChartData(
              minX: buckets.first.hour.hour.toDouble(),
              maxX: buckets.last.hour.hour.toDouble(),
              minY: 0,
              maxY: maxY,
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                horizontalInterval: 50,
                getDrawingHorizontalLine: (_) => const FlLine(
                  color: Color(0xFFEDEBE6),
                  strokeWidth: 1,
                ),
              ),
              borderData: FlBorderData(
                show: true,
                border: const Border(
                  bottom: BorderSide(color: SentinelColors.border),
                ),
              ),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(),
                rightTitles: const AxisTitles(),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 34,
                    interval: 50,
                    getTitlesWidget: (value, meta) {
                      // 50 단위 눈금과 최상단 값만 표시한다.
                      final isTick = value % 50 == 0;
                      if (!isTick && value != meta.max) {
                        return const SizedBox.shrink();
                      }
                      return Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Text(
                          value.toInt().toString(),
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            fontSize: 10,
                            color: SentinelColors.textMuted,
                          ),
                        ),
                      );
                    },
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 24,
                    interval: 1,
                    getTitlesWidget: (value, meta) => Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        value.toInt().toString().padLeft(2, '0'),
                        style: const TextStyle(
                          fontSize: 10,
                          color: SentinelColors.textMuted,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              extraLinesData: ExtraLinesData(
                horizontalLines: [
                  HorizontalLine(
                    y: AirKorea.pm10Watch.toDouble(),
                    color: SentinelColors.threshold,
                    strokeWidth: 1,
                    dashArray: const [4, 4],
                  ),
                ],
              ),
              lineTouchData: LineTouchData(
                touchTooltipData: LineTouchTooltipData(
                  getTooltipColor: (_) => const Color(0xFF2B2B2B),
                  tooltipBorderRadius: BorderRadius.circular(8),
                  tooltipPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  getTooltipItems: _tooltipItems,
                ),
              ),
              lineBarsData: [
                LineChartBarData(
                  spots: [
                    // 측정이 없던 시간은 점을 안 찍는다 — 0 으로 찍으면
                    // 바닥까지 내려가는 가짜 골짜기가 생긴다.
                    for (final b in buckets)
                      if (b.maxPm25 != null)
                        FlSpot(b.hour.hour.toDouble(), b.maxPm25!.toDouble()),
                  ],
                  color: SentinelColors.pm25,
                  barWidth: 2,
                  isCurved: true,
                  curveSmoothness: 0.25,
                  preventCurveOverShooting: true,
                  isStrokeCapRound: true,
                  dotData: FlDotData(
                    getDotPainter: (_, _, _, _) => FlDotCirclePainter(
                      radius: 3.5,
                      color: SentinelColors.pm25,
                      strokeWidth: 0,
                    ),
                  ),
                ),
                LineChartBarData(
                  spots: [
                    for (final b in buckets)
                      if (b.maxPm10 != null)
                        FlSpot(b.hour.hour.toDouble(), b.maxPm10!.toDouble()),
                  ],
                  color: SentinelColors.pm10,
                  barWidth: 2,
                  isCurved: true,
                  curveSmoothness: 0.25,
                  preventCurveOverShooting: true,
                  dashArray: const [6, 4],
                  dotData: FlDotData(
                    getDotPainter: (_, _, _, _) =>
                        const TriangleDotPainter(color: SentinelColors.pm10),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  List<LineTooltipItem?> _tooltipItems(List<LineBarSpot> spots) {
    return spots.map((spot) {
      final bucket = buckets.firstWhere(
        (b) => b.hour.hour == spot.x.round(),
        orElse: () => buckets.first,
      );
      final isPm25 = spot.barIndex == 0;
      final avg = isPm25 ? bucket.avgPm25 : bucket.avgPm10;
      final max = isPm25 ? bucket.maxPm25 : bucket.maxPm10;
      return LineTooltipItem(
        '${isPm25 ? 'PM2.5' : 'PM10'}  '
            '평균 ${avg?.round() ?? '—'} · 최고 ${max ?? '—'}',
        TextStyle(
          color: isPm25 ? const Color(0xFF9DBBF0) : const Color(0xFFEBA97C),
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      );
    }).toList();
  }
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 16,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _LegendItem(color: SentinelColors.pm25, label: 'PM2.5'),
        _LegendItem(color: SentinelColors.pm10, label: 'PM10 (점선)'),
        _LegendItem(
          color: SentinelColors.threshold,
          label: '주의보 기준 ${AirKorea.pm10Watch}',
          asLine: true,
        ),
      ],
    );
  }
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({
    required this.color,
    required this.label,
    this.asLine = false,
  });

  final Color color;
  final String label;
  final bool asLine;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: asLine ? 14 : 9,
          height: asLine ? 2 : 9,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(asLine ? 1 : 2),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            color: SentinelColors.textSecondary,
          ),
        ),
      ],
    );
  }
}

/// fl_chart 에 삼각형 마커가 없어 직접 그린다 (설계 문서 그림 3 의 PM10 마커).
class TriangleDotPainter extends FlDotPainter {
  const TriangleDotPainter({required this.color, this.size = 8});

  final Color color;
  final double size;

  @override
  void draw(Canvas canvas, FlSpot spot, Offset center) {
    final half = size / 2;
    final path = Path()
      ..moveTo(center.dx, center.dy - half)
      ..lineTo(center.dx + half, center.dy + half)
      ..lineTo(center.dx - half, center.dy + half)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  Size getSize(FlSpot spot) => Size(size, size);

  @override
  Color get mainColor => color;

  @override
  FlDotPainter lerp(FlDotPainter a, FlDotPainter b, double t) =>
      (a is TriangleDotPainter && b is TriangleDotPainter)
      ? TriangleDotPainter(
          color: Color.lerp(a.color, b.color, t) ?? b.color,
          size: a.size + (b.size - a.size) * t,
        )
      : b;

  @override
  List<Object?> get props => [color, size];
}
