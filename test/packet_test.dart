import 'package:flutter_test/flutter_test.dart';
import 'package:sentinel_app/data/models.dart';
import 'package:sentinel_app/data/packet.dart';

void main() {
  final base = DateTime.utc(2026, 8, 3, 4);

  List<Reading> sample() => [
    Reading(
      deviceId: 'SL-A3F9',
      seq: 0,
      ts: base,
      pm25: 26,
      pm10: 68,
      battery: 91,
    ),
    Reading(
      deviceId: 'SL-A3F9',
      seq: 1,
      ts: base.add(const Duration(minutes: 1)),
      pm25: 70,
      pm10: 214,
      flags: NodeFlags.thresholdExceeded,
      battery: 91,
    ),
  ];

  test('인코딩한 프레임을 그대로 되읽는다', () {
    final bytes = SentinelPacket.encode('SL-A3F9', sample());
    final packet = SentinelPacket.parse(bytes, now: base);

    expect(packet.deviceId, 'SL-A3F9');
    expect(packet.readings.length, 2);
    expect(packet.readings[1].pm10, 214);
    expect(packet.readings[1].ts, base.add(const Duration(minutes: 1)));
    expect(packet.readings[1].flags & NodeFlags.thresholdExceeded, isNonZero);
    expect(packet.readings[0].battery, 91);
  });

  test('v3 재실·환경 필드가 왕복한다', () {
    final bytes = SentinelPacket.encode('PRA3F92C', [
      Reading(
        deviceId: 'PRA3F92C',
        seq: 7,
        ts: base,
        pm25: 26,
        pm10: 68,
        headcount: 3,
        occS: 27,
        dwellS: 1071,
        tempC: 23.5,
        rh: 45.1,
        voc: 100.5,
        flags: NodeFlags.rtcUnset | NodeFlags.noTracker,
        battery: 100,
      ),
    ]);
    final r = SentinelPacket.parse(bytes, now: base).readings.single;

    expect(bytes.length, 16 + 24 + 2);
    expect(r.headcount, 3);
    expect(r.occS, 27);
    expect(r.dwellS, 1071);
    expect(r.tempC, closeTo(23.5, 0.01));
    expect(r.rh, closeTo(45.1, 0.01));
    expect(r.voc, closeTo(100.5, 0.05));
    expect(NodeFlags.describe(r.flags), contains('no_tracker'));
  });

  test('측정 안 된 값은 0 이 아니라 null 로 온다', () {
    // 팬이 멈춘 센서의 PM 을 0 으로 읽으면 화면에 '아주 깨끗함' 이 뜬다.
    // 그래서 센티널은 반드시 null 로 살아 넘어와야 한다.
    final bytes = SentinelPacket.encode('PRA3F92C', [
      Reading(
        deviceId: 'PRA3F92C',
        seq: 0,
        ts: base,
        flags: NodeFlags.aqFault,
      ),
    ]);
    final r = SentinelPacket.parse(bytes, now: base).readings.single;

    expect(r.pm25, isNull);
    expect(r.pm10, isNull);
    expect(r.tempC, isNull);
    expect(r.rh, isNull);
    expect(r.voc, isNull);
    expect(NodeFlags.describe(r.flags), contains('aq_fault'));
  });

  test('영하 온도가 센티널과 헷갈리지 않는다', () {
    final bytes = SentinelPacket.encode('PRA3F92C', [
      Reading(deviceId: 'PRA3F92C', seq: 0, ts: base, tempC: -12.5),
    ]);
    expect(
      SentinelPacket.parse(bytes, now: base).readings.single.tempC,
      closeTo(-12.5, 0.01),
    );
  });

  group('시계 없는 노드의 ts 역산', () {
    /// 노드의 ts 는 '최초 부팅 이후 누적 초' 라서 유닉스 epoch 로 읽으면
    /// 1970년이 된다. epoch + N초 로 그 상황을 그대로 만든다.
    List<Reading> boot(List<int> deviceSeconds, {required int flags}) => [
      for (var i = 0; i < deviceSeconds.length; i++)
        Reading(
          deviceId: 'PRA3F92C',
          seq: i,
          ts: DateTime.fromMillisecondsSinceEpoch(
            deviceSeconds[i] * 1000,
            isUtc: true,
          ),
          pm25: 20,
          pm10: 40,
          flags: flags,
        ),
    ];

    test('RTC_UNSET 이면 다운로드 시각 기준으로 밀어준다', () {
      final downloadedAt = DateTime.utc(2026, 8, 13, 6, 3, 10);
      final bytes = SentinelPacket.encode(
        'PRA3F92C',
        boot([29210, 29240, 29270], flags: NodeFlags.rtcUnset),
      );

      final r = SentinelPacket.parse(bytes, now: downloadedAt).readings;

      // 가장 최신 레코드가 다운로드 시각, 나머지는 그만큼 뒤로.
      expect(r[2].ts, downloadedAt);
      expect(r[1].ts, downloadedAt.subtract(const Duration(seconds: 30)));
      expect(r[0].ts, downloadedAt.subtract(const Duration(seconds: 60)));
      // 파생값이라는 사실이 남아야 한다 — 절대 시각은 전원이 꺼져 있던
      // 시간만큼 어긋날 수 있다.
      expect(r[0].quality, contains(QualityTag.tsDerived));
      expect(r[0].quality, isNot(contains(QualityTag.tsStale)));
    });

    test('시계가 있는 노드의 ts 는 손대지 않는다', () {
      final at = DateTime.utc(2026, 8, 13, 6, 0);
      final bytes = SentinelPacket.encode('PRA3F92C', [
        Reading(deviceId: 'PRA3F92C', seq: 0, ts: at, pm25: 20, pm10: 40),
      ]);

      final r = SentinelPacket.parse(bytes, now: at).readings.single;
      expect(r.ts, at);
      expect(r.quality, isNot(contains(QualityTag.tsDerived)));
    });

    test('파생 시각은 초 단위로 끊는다', () {
      // 마이크로초를 그대로 실으면 거짓 정밀도이고, 서버를 한 번 돌아오면
      // 잘려서 안 맞는다.
      final messy = DateTime.utc(2026, 8, 13, 6, 3, 10, 683, 751);
      final bytes = SentinelPacket.encode(
        'PRA3F92C',
        boot([29210], flags: NodeFlags.rtcUnset),
      );

      final r = SentinelPacket.parse(bytes, now: messy).readings.single;
      expect(r.ts.millisecond, 0);
      expect(r.ts.microsecond, 0);
    });
  });

  test('헤더만 보고 전체 길이를 계산한다', () {
    final bytes = SentinelPacket.encode('SL-A3F9', sample());
    expect(
      SentinelPacket.expectedLength(bytes.sublist(0, 16)),
      bytes.length,
    );
    // 헤더가 덜 왔으면 아직 알 수 없다.
    expect(SentinelPacket.expectedLength(bytes.sublist(0, 8)), isNull);
  });

  test('한 바이트만 틀어져도 CRC 에서 걸린다', () {
    final bytes = SentinelPacket.encode('SL-A3F9', sample());
    bytes[20] = bytes[20] ^ 0xFF;
    expect(
      () => SentinelPacket.parse(bytes, now: base),
      throwsA(isA<PacketException>()),
    );
  });

  test('잘린 프레임은 파싱하지 않는다', () {
    final bytes = SentinelPacket.encode('SL-A3F9', sample());
    expect(
      () => SentinelPacket.parse(bytes.sublist(0, bytes.length - 3), now: base),
      throwsA(isA<PacketException>()),
    );
  });

  test('범위를 벗어난 ts 는 버리지 않고 태그만 붙인다', () {
    final bytes = SentinelPacket.encode('SL-A3F9', [
      Reading(
        deviceId: 'SL-A3F9',
        seq: 0,
        ts: base.add(const Duration(days: 3)),
        pm25: 10,
        pm10: 20,
      ),
    ]);
    final packet = SentinelPacket.parse(bytes, now: base);

    expect(packet.readings.length, 1, reason: '폐기하면 안 된다');
    expect(packet.readings.first.quality, contains(QualityTag.tsFuture));
  });

  test('핸드셰이크 텍스트를 읽는다', () {
    final h = NodeHandshake.tryParse('SNTL1|SL-A3F92C|SL-NODE-01|3공구');
    expect(h, isNotNull);
    expect(h!.deviceId, 'SL-A3F92C');
    expect(h.bleId, 'SL-NODE-01');
    expect(h.siteName, '3공구');

    expect(NodeHandshake.tryParse('그냥 텍스트'), isNull);
  });
}
