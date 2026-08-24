import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/network/channel/host_port.dart';
import 'package:proxypin/network/util/system_proxy_snapshot.dart';

void main() {
  group('system proxy upstream selection', () {
    test('uses one matching HTTP and HTTPS endpoint', () {
      final snapshot = SystemProxySnapshot(
        http: ProxyInfo.of('127.0.0.1', 8888),
        https: ProxyInfo.of('localhost', 8888),
      );

      final upstream = snapshot.compatibleUpstream(localPort: 9099);

      expect(upstream?.host, '127.0.0.1');
      expect(upstream?.port, 8888);
      expect(upstream?.enabled, isTrue);
    });

    test('rejects a different HTTP and HTTPS route', () {
      final snapshot = SystemProxySnapshot(
        http: ProxyInfo.of('127.0.0.1', 8888),
        https: ProxyInfo.of('127.0.0.1', 6152),
      );

      expect(() => snapshot.compatibleUpstream(localPort: 9099), throwsStateError);
    });

    test('rejects a mixed self and different route instead of hiding it as owned', () {
      final snapshot = SystemProxySnapshot(
        http: ProxyInfo.of('127.0.0.1', 9099),
        https: ProxyInfo.of('127.0.0.1', 8888),
      );

      expect(() => snapshot.compatibleUpstream(localPort: 9099), throwsStateError);
    });

    test('rejects a partially enabled route', () {
      final snapshot = SystemProxySnapshot(http: ProxyInfo.of('127.0.0.1', 8888));

      expect(() => snapshot.compatibleUpstream(localPort: 9099), throwsStateError);
    });

    test('does not chain back to the ProxyPin listener', () {
      final snapshot = SystemProxySnapshot(
        http: ProxyInfo.of('localhost', 9099),
        https: ProxyInfo.of('127.0.0.1', 9099),
      );

      expect(snapshot.compatibleUpstream(localPort: 9099), isNull);
      expect(snapshot.isOwnedBy(host: '127.0.0.1', port: 9099), isTrue);
    });

    test('reports partial ownership when only one protocol points to ProxyPin', () {
      final snapshot = SystemProxySnapshot(
        http: ProxyInfo.of('127.0.0.1', 9099),
        https: ProxyInfo.of('127.0.0.1', 8888),
      );

      expect(
        snapshot.ownershipBy(host: '127.0.0.1', port: 9099),
        SystemProxyOwnership.partial,
      );
      expect(snapshot.ownsAnyEndpoint(host: '127.0.0.1', port: 9099), isTrue);
      expect(snapshot.isOwnedBy(host: '127.0.0.1', port: 9099), isFalse);
    });

    test('JSON round trip keeps routes and bypass domains', () {
      final source = SystemProxySnapshot(
        http: ProxyInfo.of('127.0.0.1', 8888),
        https: ProxyInfo.of('127.0.0.1', 8888),
        bypassDomains: 'localhost;*.local',
        autoConfigEnabled: true,
        networkService: 'Wi-Fi',
      );

      final restored = SystemProxySnapshot.fromJson(source.toJson());

      expect(restored.hasSameRouting(source), isTrue);
      expect(restored.networkService, 'Wi-Fi');
    });
  });

  group('macOS effective system proxy parsing', () {
    test('uses top-level proxy and ignores __SCOPED__ proxy', () {
      final snapshot = SystemProxySnapshot.fromScutilProxyOutput('''
<dictionary> {
  HTTPEnable : 1
  HTTPPort : 8888
  HTTPProxy : 127.0.0.1
  HTTPSEnable : 1
  HTTPSPort : 8888
  HTTPSProxy : 127.0.0.1
  ProxyAutoConfigEnable : 0
  __SCOPED__ : <dictionary> {
    en0 : <dictionary> {
      HTTPEnable : 1
      HTTPPort : 9099
      HTTPProxy : 127.0.0.1
      HTTPSEnable : 1
      HTTPSPort : 9099
      HTTPSProxy : 127.0.0.1
    }
  }
}
''');

      expect(snapshot.http?.port, 8888);
      expect(snapshot.https?.port, 8888);
      expect(snapshot.autoConfigEnabled, isFalse);
    });

    test('ignores stale addresses when manual proxies are disabled', () {
      final snapshot = SystemProxySnapshot.fromScutilProxyOutput('''
<dictionary> {
  HTTPEnable : 0
  HTTPPort : 9099
  HTTPProxy : 127.0.0.1
  HTTPSEnable : 0
  HTTPSPort : 9099
  HTTPSProxy : 127.0.0.1
  ProxyAutoConfigEnable : 0
}
''');

      expect(snapshot.http, isNull);
      expect(snapshot.https, isNull);
      expect(snapshot.hasEnabledProxy, isFalse);
    });

    test('records PAC and refuses to collapse it into a single upstream', () {
      final snapshot = SystemProxySnapshot.fromScutilProxyOutput('''
<dictionary> {
  HTTPEnable : 0
  HTTPSEnable : 0
  ProxyAutoConfigEnable : 1
  ProxyAutoConfigURLString : https://example.com/proxy.pac
}
''');

      expect(snapshot.autoConfigEnabled, isTrue);
      expect(snapshot.hasEnabledProxy, isTrue);
      expect(() => snapshot.compatibleUpstream(localPort: 9099), throwsStateError);
    });

    test('rejects an enabled proxy with an incomplete endpoint', () {
      expect(
        () => SystemProxySnapshot.fromScutilProxyOutput('''
<dictionary> {
  HTTPEnable : 1
  HTTPProxy : 127.0.0.1
  HTTPSEnable : 0
  ProxyAutoConfigEnable : 0
}
'''),
        throwsStateError,
      );
    });

    test('rejects a proxy endpoint without its enable state', () {
      expect(
        () => SystemProxySnapshot.fromScutilProxyOutput('''
<dictionary> {
  HTTPPort : 8888
  HTTPProxy : 127.0.0.1
  HTTPSEnable : 0
  ProxyAutoConfigEnable : 0
}
'''),
        throwsStateError,
      );
    });

    for (final port in ['not-a-port', '0', '65536']) {
      test('rejects invalid enabled proxy port $port', () {
        expect(
          () => SystemProxySnapshot.fromScutilProxyOutput('''
<dictionary> {
  HTTPEnable : 1
  HTTPPort : $port
  HTTPProxy : 127.0.0.1
  HTTPSEnable : 0
  ProxyAutoConfigEnable : 0
}
'''),
          throwsStateError,
        );
      });
    }
  });
}
