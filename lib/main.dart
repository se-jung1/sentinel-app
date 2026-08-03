import 'package:flutter/material.dart';

import 'config.dart';
import 'data/api_client.dart';
import 'data/db.dart';
import 'data/reading_repository.dart';
import 'screens/home_shell.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final db = await SentinelDb.open();

  // API_BASE_URL 을 주지 않으면 서버 없이 SQLite 만으로 동작한다.
  final api = AppConfig.useApi
      ? ApiClient(baseUrl: AppConfig.apiBaseUrl)
      : null;
  final repository = ReadingRepository(db, api: api);

  // 설계 검토용 예시 데이터. 서버를 붙였거나 실제 데이터가 있으면 넣지 않는다.
  if (api == null) {
    await repository.seedSampleDataIfEmpty();
  }

  final devices = await db.devices();
  runApp(
    SentinelApp(
      repository: repository,
      api: api,
      deviceId: devices.isEmpty ? 'SL-A3F92C' : devices.first.deviceId,
    ),
  );
}

class SentinelApp extends StatelessWidget {
  const SentinelApp({
    super.key,
    required this.repository,
    required this.deviceId,
    this.api,
  });

  final ReadingRepository repository;
  final ApiClient? api;
  final String deviceId;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sentinel Labs',
      debugShowCheckedModeBanner: false,
      theme: buildSentinelTheme(),
      home: HomeShell(
        repository: repository,
        api: api,
        deviceId: deviceId,
      ),
    );
  }
}
