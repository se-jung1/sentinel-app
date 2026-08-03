// 화면 확인 전용 진입점. 플러그인(NFC/BLE/SQLite) 없이 고정 데이터로 그린다.
//   flutter run -d chrome -t lib/main_demo.dart
import 'package:flutter/material.dart';

import 'data/air_quality.dart';
import 'data/models.dart';
import 'data/reading_repository.dart';
import 'screens/dashboard_screen.dart';
import 'services/sync_controller.dart';
import 'theme.dart';
import 'widgets/nfc_scan_dialog.dart';

const _hourly = <int, (int, int)>{
  7: (20, 45), 8: (24, 62), 9: (29, 88), 10: (35, 112),
  11: (43, 132), 12: (57, 162), 13: (70, 214), 14: (64, 152),
  15: (50, 120), 16: (41, 100), 17: (33, 80), 18: (26, 68),
};

DashboardData _demoData() {
  final today = DateTime(2026, 8, 3);
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
      pm25: 26,
      pm10: 68,
    ),
    todayMaxPm10: 214,
    exceedDuration: const Duration(minutes: 148),
    buckets: [
      for (final e in _hourly.entries)
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
    alertLevel: AirAlertLevel.watch,
    source: DashboardSource.remote,
  );
}

void main() => runApp(const DemoApp());

class DemoApp extends StatelessWidget {
  const DemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sentinel Labs — 데모',
      debugShowCheckedModeBanner: false,
      theme: buildSentinelTheme(),
      home: const _DemoShell(),
    );
  }
}

class _DemoShell extends StatefulWidget {
  const _DemoShell();

  @override
  State<_DemoShell> createState() => _DemoShellState();
}

class _DemoShellState extends State<_DemoShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          _Page(
            title: '계측',
            child: MeasurementCard(data: _demoData()),
          ),
          const _NfcDemoPage(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.show_chart), label: '계측'),
          NavigationDestination(icon: Icon(Icons.nfc), label: 'NFC 연결'),
        ],
      ),
    );
  }
}

class _Page extends StatelessWidget {
  const _Page({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          title,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// 실제 화면과 같은 구성. 태깅 대신 창만 띄워 보여준다.
class _NfcDemoPage extends StatelessWidget {
  const _NfcDemoPage();

  void _showDialog(BuildContext context, SyncPhase phase) {
    showDialog<void>(
      context: context,
      builder: (_) => NfcScanDialog(
        phase: phase,
        progress: phase == SyncPhase.downloading ? 0.62 : null,
        onCancel: () => Navigator.of(context).pop(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _Page(
      title: 'NFC 연결',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Tile(
            icon: Icons.bluetooth,
            title: '블루투스',
            subtitle: '켜짐 — 노드에서 데이터를 받을 수 있습니다',
            ok: true,
          ),
          const SizedBox(height: 10),
          const _Tile(
            icon: Icons.nfc,
            title: 'NFC',
            subtitle: '켜짐 — 태그를 읽을 수 있습니다',
            ok: true,
          ),
          const SizedBox(height: 32),
          Icon(
            Icons.tap_and_play,
            size: 96,
            color: SentinelColors.pm25.withValues(alpha: 0.85),
          ),
          const SizedBox(height: 20),
          const Text(
            '노드에 갖다 대세요',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          const Text(
            '아래 버튼을 누른 뒤 휴대폰 뒷면을 노드의 NFC 표시에 대세요.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: SentinelColors.textSecondary,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () => _showDialog(context, SyncPhase.waitingTag),
            child: const Text('태그 읽기 시작'),
          ),
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 12),
          const Text(
            '창 미리보기 (데모 전용)',
            style: TextStyle(fontSize: 12, color: SentinelColors.textMuted),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final phase in [
                SyncPhase.waitingTag,
                SyncPhase.connecting,
                SyncPhase.downloading,
                SyncPhase.uploading,
                SyncPhase.done,
                SyncPhase.failed,
              ])
                OutlinedButton(
                  onPressed: () => _showDialog(context, phase),
                  child: Text(NfcScanDialog.labelsFor(phase).$1),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.ok,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: cardDecoration(),
      child: Row(
        children: [
          Icon(
            icon,
            size: 20,
            color: ok ? SentinelColors.pm25 : SentinelColors.textMuted,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 12,
                    color: SentinelColors.textSecondary,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
