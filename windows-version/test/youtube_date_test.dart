import 'package:flutter_test/flutter_test.dart';
// Deliberately exercise the exact vendored parser used by search and pagination.
// ignore: implementation_imports
import 'package:youtube_explode_dart/src/extensions/helpers_extension.dart';

void main() {
  for (final entry in <String, Duration>{
    'Streamed 3y ago': const Duration(days: 3 * 365),
    'Streamed 3 years ago': const Duration(days: 3 * 365),
    '  Streamed   3y ago  ': const Duration(days: 3 * 365),
    'Premiered 2 months ago': const Duration(days: 60),
    '2mo ago': const Duration(days: 60),
    '5 minutes ago': const Duration(minutes: 5),
    '4h ago': const Duration(hours: 4),
  }.entries) {
    test('search metadata parses ${entry.key}', () {
      final before = DateTime.now().subtract(entry.value);
      final parsed = entry.key.toDateTime();
      expect(parsed, isNotNull);
      expect(parsed!.difference(before).inSeconds.abs(), lessThan(2));
    });
  }
  for (final label in <String?>[
    null,
    '',
    'Streamed',
    'Streamed live',
    'Streamed yesterday',
    'just now',
    '3 неизвестных ago',
    'LIVE',
    '999999999999999999999999y ago',
  ]) {
    test('unknown optional date does not abort search: $label', () {
      expect(label.toDateTime(), isNull);
    });
  }
}
