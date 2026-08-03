/// 빌드 시점 설정. 코드에 서버 주소를 박지 않는다.
///
/// ```
/// flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8080
/// ```
/// (안드로이드 에뮬레이터에서 호스트 PC 는 10.0.2.2 다)
class AppConfig {
  /// 비워 두면 서버를 쓰지 않고 SQLite 만으로 동작한다.
  static const apiBaseUrl = String.fromEnvironment('API_BASE_URL');

  /// 기기 등록 시 붙일 현장 ID.
  /// ⚠ 임시. 현장 선택 화면이 생기면 사용자가 고르게 해야 한다.
  static const defaultSiteId = String.fromEnvironment(
    'SITE_ID',
    defaultValue: 'site-3',
  );

  static bool get useApi => apiBaseUrl.isNotEmpty;
}
