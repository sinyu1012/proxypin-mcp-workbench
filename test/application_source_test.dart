import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/network/util/application_source.dart';
import 'package:proxypin/network/util/process_info.dart';

void main() {
  final chrome = ProcessInfo(
    'com.google.Chrome',
    'Google Chrome',
    '/Applications/Google Chrome.app',
    os: 'macos',
  );
  final otherChrome = ProcessInfo(
    'com.google.Chrome',
    'Google Chrome',
    '/Users/example/Applications/Google Chrome.app',
    os: 'macos',
  );

  test('application source identity includes the executable path', () {
    expect(applicationSourceLabel(chrome), 'Google Chrome');
    expect(applicationSourceKey(chrome), isNot(applicationSourceKey(otherChrome)));
  });

  test('matches all, known, and unknown applications', () {
    expect(matchesApplicationSource(null, chrome), isTrue);
    expect(matchesApplicationSource(applicationSourceKey(chrome), chrome), isTrue);
    expect(matchesApplicationSource(applicationSourceKey(chrome), otherChrome), isFalse);
    expect(matchesApplicationSource('', null), isTrue);
    expect(matchesApplicationSource('', chrome), isFalse);
  });
}
