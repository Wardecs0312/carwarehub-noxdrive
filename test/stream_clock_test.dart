import 'package:carwarehub_noxdrive/features/stream/stream_clock.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('время начала и длительность трансляции', () {
    final start = DateTime(2026, 10, 13, 14, 32, 5);
    expect(
      streamClockText(
        start,
        start.add(const Duration(minutes: 5, seconds: 12)),
      ),
      'с 14:32 · 05:12',
    );
    expect(
      streamClockText(
        start,
        start.add(const Duration(hours: 1, minutes: 2, seconds: 3)),
      ),
      'с 14:32 · 1:02:03',
    );
  });

  test('часы на компьютере отстают от сервера: не уходим в минус', () {
    final start = DateTime(2026, 10, 13, 14, 32);
    expect(
      streamClockText(start, start.subtract(const Duration(seconds: 3))),
      'с 14:32 · 00:00',
    );
  });
}
