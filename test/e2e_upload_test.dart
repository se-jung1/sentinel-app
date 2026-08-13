/// 노드가 실제로 보낸 프레임 한 장을 앱 코드로 파싱해서 살아 있는 서버에
/// 올려보는 검증. 단위 테스트가 못 잡는 것 하나를 잡는다 — 펌웨어 인코더,
/// 앱 디코더, 서버 스키마 셋이 같은 계약을 보고 있는지.
///
/// 목이 없다. `SentinelPacket.parse` 와 `ApiClient` 를 그대로 쓰고, 바이트는
/// 진짜 하드웨어에서 BLE 로 받은 것이다.
///
/// 서버나 프레임 파일이 없으면 그냥 건너뛴다 — CI 와 평소 `flutter test` 를
/// 막지 않기 위해서다. 돌리려면:
///
/// ```
/// # 서버 (sentinel-api)
/// AUTH_DISABLED=true MONGO_DB=sentinel_e2e \
///   .venv/Scripts/python.exe -m uvicorn app.main:app --port 8000
///
/// # 프레임 (노드에서 BLE 로 받아 떨구기)
/// SNTL_RAW=frame.bin python dl.py 0 540
///
/// # 검증
/// SNTL_FRAME=<frame.bin 경로> flutter test test/e2e_upload_test.dart
/// ```
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sentinel_app/data/api_client.dart';
import 'package:sentinel_app/data/models.dart';
import 'package:sentinel_app/data/packet.dart';

const _baseUrl = String.fromEnvironment(
  'SNTL_API',
  defaultValue: 'http://127.0.0.1:8000',
);

/// `--dart-define=SNTL_FRAME=...` 과 환경변수 둘 다 받는다. flutter test 가
/// 환경변수를 테스트 아이솔레이트까지 넘기는지는 버전마다 다르다.
const _frameDefine = String.fromEnvironment('SNTL_FRAME');

Future<bool> _serverUp() async {
  try {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    final request = await client.getUrl(Uri.parse('$_baseUrl/healthz'));
    final response = await request.close();
    await response.drain<void>();
    client.close();
    return response.statusCode == 200;
  } catch (_) {
    return false;
  }
}

void main() {
  final framePath = _frameDefine.isNotEmpty
      ? _frameDefine
      : Platform.environment['SNTL_FRAME'];
  final frameFile = framePath == null ? null : File(framePath);

  test('노드 프레임이 앱을 거쳐 서버까지 그대로 도착한다', () async {
    if (frameFile == null || !frameFile.existsSync()) {
      markTestSkipped('SNTL_FRAME 이 없다 — dl.py 로 프레임을 먼저 받아라');
      return;
    }
    if (!await _serverUp()) {
      markTestSkipped('$_baseUrl 에 서버가 없다');
      return;
    }

    // 1. 하드웨어가 보낸 바이트를 앱 파서로 읽는다.
    final packet = SentinelPacket.parse(frameFile.readAsBytesSync());
    expect(packet.readings, isNotEmpty);

    final api = ApiClient(baseUrl: _baseUrl);
    addTearDown(api.close);

    // 2. 기기 등록 (서버는 미등록 기기의 업로드를 404 로 거절한다).
    await api.registerDevice(
      deviceId: packet.deviceId,
      siteId: 'e2e',
      siteName: 'E2E 검증',
    );

    // 3. 업로드. 두 번 보내서 멱등까지 같이 본다 — LTE 음영에서 재전송이
    //    반복돼도 중복 레코드가 생기면 안 된다.
    final first = await api.uploadReadings(
      deviceId: packet.deviceId,
      readings: packet.readings,
    );
    expect(first.inserted + first.duplicated, packet.readings.length);

    final again = await api.uploadReadings(
      deviceId: packet.deviceId,
      readings: packet.readings,
    );
    expect(again.inserted, 0, reason: '재전송은 새 레코드를 만들지 않는다');
    expect(again.duplicated, packet.readings.length);

    // 4. 서버가 요약으로 돌려주는 값이 프레임의 마지막 레코드와 같아야 한다.
    //    여기서 어긋나면 펌웨어·앱·서버 중 한 곳의 스케일이나 필드명이 틀린 것이다.
    final summary = await api.deviceSummary(packet.deviceId);
    final sent = packet.readings.reduce((a, b) => a.ts.isAfter(b.ts) ? a : b);
    final got = summary.latest!;

    expect(got.ts, sent.ts);
    // 노드에 시계가 없으므로 앱이 역산한 시각이어야 한다 — 1970년이 아니라.
    expect(sent.quality, contains(QualityTag.tsDerived));
    expect(
      DateTime.now().toUtc().difference(sent.ts).inMinutes.abs(),
      lessThan(5),
      reason: '가장 최신 레코드는 방금 찍힌 것이다',
    );
    expect(summary.todayMaxPm10, greaterThan(0), reason: '오늘 집계에 잡혀야 한다');
    expect(got.pm25, sent.pm25);
    expect(got.pm10, sent.pm10);
    expect(got.headcount, sent.headcount);
    expect(got.tempC, sent.tempC);
    expect(got.rh, sent.rh);

    // 5. 그리고 이 노드가 실제로 무엇인지가 서버까지 전달됐는지.
    final flags = NodeFlags.describe(sent.flags);
    expect(flags, contains('no_tracker'),
        reason: 'headcount 를 합산해 인원수로 쓰면 안 된다는 표시');

    // ignore: avoid_print
    print(
      '  ${packet.readings.length}건 업로드, 최신 ${got.ts.toLocal()}: '
      'pm2.5 ${got.pm25} pm10 ${got.pm10} ${got.tempC}C ${got.rh}%RH '
      'head ${got.headcount} · 오늘 최고 PM10 ${summary.todayMaxPm10}, '
      '재실 ${summary.occupiedMinutes}분, 기준초과 ${summary.exceedMinutes}분',
    );
  });
}
