import 'package:flutter_test/flutter_test.dart';
import 'package:rhythm/services/audio_diagnostics.dart';

void main() {
  test('diagnostic errors preserve status while removing signed URLs', () {
    final safe = AudioDiagnostics.redact(
      'HTTP 403 https://audio.example/file?sig=SECRET&ip=1.2.3.4\nretry '
      '"http://other.example/token"',
    );
    expect(safe, contains('HTTP 403'));
    expect(safe, contains('retry'));
    expect(safe, isNot(contains('SECRET')));
    expect(safe, isNot(contains('1.2.3.4')));
    expect(safe, isNot(contains('http')));
    expect(safe, isNot(contains('\n')));
  });
}
