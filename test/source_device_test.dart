import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/util/source_address.dart';
import 'package:proxypin/utils/har.dart';

void main() {
  test('normalizes client socket addresses', () {
    expect(normalizeSourceAddress('::ffff:192.168.1.8'), '192.168.1.8');
    expect(normalizeSourceAddress('::1'), '127.0.0.1');
    expect(normalizeSourceAddress(' 10.0.0.2 '), '10.0.0.2');
    expect(normalizeSourceAddress(''), isNull);
  });

  test('matches all, known, and unknown source devices', () {
    expect(matchesSourceAddress(null, '192.168.1.8'), isTrue);
    expect(matchesSourceAddress('192.168.1.8', '::ffff:192.168.1.8'), isTrue);
    expect(matchesSourceAddress('192.168.1.8', '192.168.1.9'), isFalse);
    expect(matchesSourceAddress('', null), isTrue);
    expect(matchesSourceAddress('', '192.168.1.8'), isFalse);
  });

  test('recognizes the complete IPv4 loopback range and IPv6 loopback', () {
    expect(isLoopbackSourceAddress('127.0.0.1'), isTrue);
    expect(isLoopbackSourceAddress('127.12.34.56'), isTrue);
    expect(isLoopbackSourceAddress('::1'), isTrue);
    expect(isLoopbackSourceAddress('::ffff:127.0.0.2'), isTrue);
    expect(isLoopbackSourceAddress('192.168.1.8'), isFalse);
    expect(isLoopbackSourceAddress(null), isFalse);
  });

  test('local and external capture scopes are complementary', () {
    const addresses = <String?>['127.0.0.1', '::1', '192.168.1.8', '10.0.0.2', null];

    for (final address in addresses) {
      final local = matchesCaptureSourceScope(CaptureSourceScope.localMachine, address);
      final external = matchesCaptureSourceScope(CaptureSourceScope.external, address);
      expect(local, isNot(external), reason: 'address=$address');
      expect(matchesCaptureSourceScope(CaptureSourceScope.all, address), isTrue);
    }
  });

  test('source IP survives request JSON round trip', () {
    final request = HttpRequest(HttpMethod.get, 'https://api.example.test/items')..sourceIp = '::ffff:192.168.1.9';

    final restored = HttpRequest.fromJson(request.toJson());

    expect(restored.sourceIp, '192.168.1.9');
    expect(restored.sourceKey, '192.168.1.9');
  });

  test('source IP survives HAR round trip and legacy entries stay unknown', () {
    final request = HttpRequest(HttpMethod.get, 'https://api.example.test/items')..sourceIp = '192.168.1.10';
    final har = Har.toHar(request);

    expect(Har.toRequest(har).sourceIp, '192.168.1.10');

    har.remove('_sourceIp');
    final legacy = Har.toRequest(har);
    expect(legacy.sourceIp, isNull);
    expect(legacy.sourceKey, isEmpty);
  });
}
