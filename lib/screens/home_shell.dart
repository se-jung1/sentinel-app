import 'package:flutter/material.dart';

import '../data/api_client.dart';
import '../data/db.dart';
import '../data/reading_repository.dart';
import '../services/uploader.dart';
import 'dashboard_screen.dart';
import 'nfc_setup_screen.dart';

/// 하단 탭으로 '계측'(데이터 출력)과 'NFC 연결'을 오간다.
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.repository,
    required this.deviceId,
    this.api,
  });

  final ReadingRepository repository;
  final String deviceId;
  final ApiClient? api;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  // NFC 탭에서 돌아오면 계측 화면을 다시 불러오도록 키를 바꾼다.
  Key _dashboardKey = UniqueKey();

  void _onTap(int next) {
    setState(() {
      if (next == 0 && _index == 1) _dashboardKey = UniqueKey();
      _index = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    final api = widget.api;

    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          DashboardScreen(
            key: _dashboardKey,
            repository: widget.repository,
            deviceId: widget.deviceId,
          ),
          NfcSetupScreen(
            uploader: api == null
                ? null
                : Uploader(db: SentinelDb.instance, api: api),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _onTap,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.show_chart),
            label: '계측',
          ),
          NavigationDestination(
            icon: Icon(Icons.nfc),
            label: 'NFC 연결',
          ),
        ],
      ),
    );
  }
}
