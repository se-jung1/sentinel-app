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
