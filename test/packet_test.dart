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
