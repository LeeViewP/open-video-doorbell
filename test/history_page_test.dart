import 'package:doorbell_call/history_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formatWhen: today, yesterday, older', () {
    final now = DateTime(2026, 11, 11, 18, 30);
    expect(formatWhen(DateTime(2026, 11, 11, 9, 5), now), '09:05');
    expect(formatWhen(DateTime(2026, 11, 10, 23, 59), now), 'Yesterday 23:59');
    expect(formatWhen(DateTime(2026, 11, 3, 14, 0), now), '3 Nov 14:00');
  });
}
