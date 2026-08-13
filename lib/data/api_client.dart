import 'dart:convert';

import 'package:http/http.dart' as http;

import 'air_quality.dart';
import 'models.dart';

/// sentinel-api (FastAPI + MongoDB) 클라이언트.
///
/// 엔드포인트 계약의 정본은 서버의 `app/models.py` 다 — /docs 의 Swagger UI 와
/// 이 파일이 어긋나면 서버 쪽을 따른다.
class ApiClient {
  ApiClient({
    required this.baseUrl,
    http.Client? httpClient,
    this.tokenProvider,
    this.timeout = const Duration(seconds: 10),
  }) : _http = httpClient ?? http.Client();

  final String baseUrl;
  final http.Client _http;
  final Duration timeout;

  /// Firebase ID 토큰 공급자. null 이면 Authorization 헤더를 붙이지 않는다
  /// (서버가 AUTH_DISABLED=true 인 로컬 검증용).
  final Future<String?> Function()? tokenProvider;

  Future<Map<String, String>> _headers() async {
    final token = await tokenProvider?.call();
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query);

  Never _fail(http.Response response) {
    String detail;
    try {
      detail = (jsonDecode(response.body) as Map)['detail']?.toString() ??
          response.body;
    } catch (_) {
      detail = response.body;
    }
    throw ApiException(response.statusCode, detail);
  }

  Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException(0, '$e');
    }
  }

  /// 기기 등록. 재등록해도 안전하다 (서버가 upsert).
  Future<void> registerDevice({
    required String deviceId,
    required String siteId,
    String? siteName,
    String? bleId,
  }) => _guard(() async {
    final response = await _http
        .post(
          _uri('/v1/devices'),
          headers: await _headers(),
          body: jsonEncode({
            'device_id': deviceId,
            'site_id': siteId,
            'site_name': ?siteName,
            'ble_id': ?bleId,
          }),
        )
        .timeout(timeout);
    if (response.statusCode != 200) _fail(response);
  });

  /// 측정 데이터 배치 업로드. 서버가 멱등이라 재전송해도 안전하다.
  Future<UploadResult> uploadReadings({
    required String deviceId,
    required List<Reading> readings,
  }) => _guard(() async {
    final response = await _http
        .post(
          _uri('/v1/readings'),
          headers: await _headers(),
          body: jsonEncode({
            'device_id': deviceId,
            // ⚠ 서버(sentinel-api)가 아직 v1 스키마다. app/models.py 의
            // `pm25: int = Field(ge=0, le=10_000)` 는 null 을 안 받으므로
            // 센서가 못 읽은 레코드가 섞이면 배치 전체가 422 로 튕긴다.
            // 재실 필드(headcount/occ_s/dwell_s)와 온습도는 아예 받을 자리가 없다.
            // 서버를 v3 로 올리기 전까지 업로드는 반쪽이다 — BLE 수집과 로컬
            // SQLite 저장은 정상이다.
            'readings': [
              for (final r in readings)
                {
                  'seq': r.seq,
                  'ts': r.ts.toUtc().toIso8601String(),
                  'pm25': r.pm25,
                  'pm10': r.pm10,
                  'flags': r.flags,
                  if (r.battery != null) 'battery': r.battery,
                },
            ],
          }),
        )
        .timeout(timeout);
    if (response.statusCode != 200) _fail(response);

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return UploadResult(
      inserted: body['inserted'] as int,
      duplicated: body['duplicated'] as int,
      flagged: (body['flagged'] as int?) ?? 0,
    );
  });

  /// 계측 화면 한 장에 필요한 값을 한 번에 받는다.
  Future<RemoteSummary> deviceSummary(String deviceId) => _guard(() async {
    final response = await _http
        .get(_uri('/v1/devices/$deviceId/summary'), headers: await _headers())
        .timeout(timeout);
    if (response.statusCode != 200) _fail(response);
    return RemoteSummary.fromJson(
      jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
    );
  });

  void close() => _http.close();
}

class ApiException implements Exception {
  const ApiException(this.statusCode, this.detail);

  /// 0 이면 네트워크 자체가 안 된 경우.
  final int statusCode;
  final String detail;

  bool get isOffline => statusCode == 0;

  @override
  String toString() => statusCode == 0 ? detail : '[$statusCode] $detail';
}

class UploadResult {
  const UploadResult({
    required this.inserted,
    required this.duplicated,
    this.flagged = 0,
  });

  final int inserted;
  final int duplicated;
  final int flagged;
}

/// GET /v1/devices/{id}/summary 응답.
class RemoteSummary {
  const RemoteSummary({
    required this.device,
    required this.latest,
    required this.todayMaxPm10,
    required this.exceedMinutes,
    required this.alertLevel,
    required this.hourly,
  });

  final DeviceInfo device;
  final Reading? latest;
  final int todayMaxPm10;
  final int exceedMinutes;
  final AirAlertLevel alertLevel;
  final List<RemotePoint> hourly;

  static RemoteSummary fromJson(Map<String, dynamic> json) {
    final device = json['device'] as Map<String, dynamic>;
    final latest = json['latest'] as Map<String, dynamic>?;
    final deviceId = device['device_id'] as String;

    return RemoteSummary(
      device: DeviceInfo(
        deviceId: deviceId,
        siteName: device['site_name'] as String?,
        bleId: device['ble_id'] as String?,
        lastSyncAt: device['last_sync_at'] == null
            ? null
            : DateTime.parse(device['last_sync_at'] as String).toUtc(),
      ),
      latest: latest == null
          ? null
          : Reading(
              deviceId: deviceId,
              // 서버 요약에는 seq 가 없다. 화면 표시에만 쓰므로 -1 로 둔다.
              seq: -1,
              ts: DateTime.parse(latest['ts'] as String).toUtc(),
              pm25: latest['pm25'] as int,
              pm10: latest['pm10'] as int,
            ),
      todayMaxPm10: (json['today_max_pm10'] as int?) ?? 0,
      exceedMinutes: (json['exceed_minutes'] as int?) ?? 0,
      alertLevel: switch (json['alert_level'] as String?) {
        'alert' => AirAlertLevel.alert,
        'watch' => AirAlertLevel.watch,
        _ => AirAlertLevel.none,
      },
      hourly: [
        for (final p in (json['hourly'] as List? ?? const []))
          RemotePoint.fromJson(p as Map<String, dynamic>),
      ],
    );
  }
}

class RemotePoint {
  const RemotePoint({
    required this.ts,
    required this.pm25Avg,
    required this.pm25Max,
    required this.pm10Avg,
    required this.pm10Max,
  });

  final DateTime ts;
  final double pm25Avg;
  final int pm25Max;
  final double pm10Avg;
  final int pm10Max;

  static RemotePoint fromJson(Map<String, dynamic> json) => RemotePoint(
    ts: DateTime.parse(json['ts'] as String).toUtc(),
    pm25Avg: (json['pm25_avg'] as num).toDouble(),
    pm25Max: (json['pm25_max'] as num).toInt(),
    pm10Avg: (json['pm10_avg'] as num).toDouble(),
    pm10Max: (json['pm10_max'] as num).toInt(),
  );
}
