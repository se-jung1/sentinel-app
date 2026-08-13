import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/air_quality.dart';
import '../data/api_client.dart';
import '../data/models.dart';
import '../data/reading_repository.dart';
import '../theme.dart';
import '../widgets/metric_card.dart';
import '../widgets/status_badge.dart';
import '../widgets/trend_chart.dart';

/// 설계 문서 3.4 앱 화면 구성 — 모바일 앱 계측 화면.
///
/// SQLite 만 읽는다. 클라우드 연결 상태와 무관하게 동작한다.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({
    super.key,
    required this.repository,
    required this.deviceId,
    this.api,
  });

  final ReadingRepository repository;
  final String deviceId;

  /// null 이면 서버 없이 SQLite 만으로 동작한다.
  final ApiClient? api;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late Future<DashboardData> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.repository.loadDashboard(widget.deviceId);
  }

  void _reload() {
    setState(() {
      _future = widget.repository.loadDashboard(widget.deviceId);
    });
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '계측',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
      ),
      body: FutureBuilder<DashboardData>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _Message(
              icon: Icons.error_outline,
              text: '데이터를 읽지 못했습니다\n${snapshot.error}',
              actionLabel: '다시 시도',
              onAction: _reload,
            );
          }

          final data = snapshot.data!;
          if (data.isEmpty) {
            return const _Message(
              icon: Icons.sensors_off,
              text: '아직 받은 측정 데이터가 없습니다.\n'
                  '아래 [NFC 연결] 탭에서 노드에 휴대폰을 갖다 대세요.',
            );
          }

          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: LayoutBuilder(
              builder: (context, constraints) {
                // 폰/태블릿 폭을 화면 크기로 분기한다. 고정 픽셀 레이아웃 금지.
                final horizontal = constraints.maxWidth >= 600 ? 24.0 : 16.0;
                return SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(
                    horizontal,
                    8,
                    horizontal,
                    24 + MediaQuery.paddingOf(context).bottom,
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 640),
                      child: MeasurementCard(data: data),
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

/// 설계 문서 그림 3 의 카드 한 장. 데이터만 주면 그려지므로 위젯 테스트로 검증한다.
class MeasurementCard extends StatelessWidget {
  const MeasurementCard({super.key, required this.data});

  final DashboardData data;

  @override
  Widget build(BuildContext context) {
    final latest = data.latest!;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: cardDecoration().copyWith(
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Header(data: data),
          const SizedBox(height: 18),
          _MetricGrid(data: data, latest: latest),
          const SizedBox(height: 22),
          TrendChart(buckets: data.buckets),
          if (data.alerts.isNotEmpty) ...[
            const SizedBox(height: 18),
            const Divider(),
            const SizedBox(height: 12),
            ...data.alerts.take(3).map((e) => _AlertRow(event: e)),
          ],
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.data});

  final DashboardData data;

  @override
  Widget build(BuildContext context) {
    final parts = [
      if (data.device.siteName != null) data.device.siteName!,
      _syncLabel(data.device.lastSyncAt),
    ];

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                data.device.deviceId,
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Flexible(
                    child: Text(
                      parts.join(' · '),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: SentinelColors.textSecondary,
                      ),
                    ),
                  ),
                  if (data.source == DashboardSource.local) ...[
                    const SizedBox(width: 6),
                    const Icon(
                      Icons.cloud_off,
                      size: 12,
                      color: SentinelColors.textMuted,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      DashboardSource.local.label,
                      style: const TextStyle(
                        fontSize: 11,
                        color: SentinelColors.textMuted,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        StatusBadge(alertLevel: data.alertLevel, grade: data.currentGrade),
      ],
    );
  }

  static String _syncLabel(DateTime? at) {
    if (at == null) return '동기화 기록 없음';
    final diff = DateTime.now().toUtc().difference(at);
    if (diff.inMinutes < 1) return '방금 동기화';
    if (diff.inMinutes < 60) return '${diff.inMinutes}분 전 동기화';
    if (diff.inHours < 24) return '${diff.inHours}시간 전 동기화';
    return '${DateFormat('M월 d일 HH:mm').format(at.toLocal())} 동기화';
  }
}

class _MetricGrid extends StatelessWidget {
  const _MetricGrid({required this.data, required this.latest});

  final DashboardData data;
  final Reading latest;

  @override
  Widget build(BuildContext context) {
    final exceedHours = data.exceedDuration.inMinutes / 60;
    final cards = <Widget>[
      MetricCard(
        label: 'PM2.5',
        // 측정 안 된 값은 숫자를 만들어내지 않고 '—' 로 둔다.
        value: latest.pm25?.toString() ?? '—',
        unit: 'µg/m³',
        emphasize: latest.pm25 != null &&
            AirKorea.gradePm25(latest.pm25!).index >= AirGrade.bad.index,
      ),
      MetricCard(
        label: 'PM10',
        value: latest.pm10?.toString() ?? '—',
        unit: 'µg/m³',
        emphasize: latest.pm10 != null &&
            AirKorea.gradePm10(latest.pm10!).index >= AirGrade.bad.index,
      ),
      MetricCard(
        label: '오늘 최고 PM10',
        value: '${data.todayMaxPm10}',
        emphasize: data.todayMaxPm10 >= AirKorea.pm10Watch,
      ),
      MetricCard(
        label: '기준 초과',
        value: exceedHours.toStringAsFixed(1),
        unit: '시간',
        emphasize: exceedHours > 0,
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 560 ? 4 : 2;
        const gap = 10.0;
        final width =
            (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final card in cards) SizedBox(width: width, child: card),
          ],
        );
      },
    );
  }
}

class _AlertRow extends StatelessWidget {
  const _AlertRow({required this.event});

  final AlertEvent event;

  @override
  Widget build(BuildContext context) {
    final h = event.duration.inHours;
    final m = event.duration.inMinutes % 60;
    final span = h > 0 ? '$h시간 $m분' : '$m분';

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            size: 15,
            color: SentinelColors.textMuted,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${DateFormat('HH:mm').format(event.peakAt)} '
              'PM10 ${event.peakPm10} µg/m³ · $span 주의보 기준 초과',
              style: const TextStyle(
                fontSize: 12,
                color: SentinelColors.textSecondary,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.text,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: SentinelColors.textMuted),
            const SizedBox(height: 14),
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: SentinelColors.textSecondary,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 18),
            if (onAction != null)
              FilledButton(onPressed: onAction, child: Text(actionLabel ?? '')),
          ],
        ),
      ),
    );
  }
}
