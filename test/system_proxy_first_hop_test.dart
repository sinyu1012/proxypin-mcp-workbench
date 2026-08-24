import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/channel/host_port.dart';
import 'package:proxypin/network/util/system_proxy.dart';
import 'package:proxypin/network/util/system_proxy_snapshot.dart';

void main() {
  group('Proxyman-style first hop', () {
    test('blocks every proxy acquisition entry while app termination is pending', () async {
      final original = _surgeSnapshot();
      final gateway = _FakeSystemProxyGateway(configured: original, effective: original);
      final configuration = _configuration(firstHop: true);
      final server = _server(configuration, gateway);

      server.beginAppTermination(42);

      expect(server.appTerminationLocked, isTrue);
      expect(server.systemProxyRoutingLocked, isTrue);
      await expectLater(server.start(), throwsStateError);
      await expectLater(server.setSystemProxyEnable(true), throwsStateError);
      await expectLater(server.setFirstHopProxyMode(true), throwsStateError);
      expect(gateway.configuredSnapshotCalls, 0);
      expect(gateway.takeOwnershipCalls, 0);

      server.cancelAppTermination(41);
      expect(server.appTerminationLocked, isTrue);

      server.cancelAppTermination(42);
      expect(server.appTerminationLocked, isFalse);
    });

    test('does not let a route acquisition overtake an in-flight stop', () async {
      final port = await _unusedPort();
      final original = _surgeSnapshot();
      final gateway = _FakeSystemProxyGateway(configured: original, effective: original);
      final configuration = _configuration(firstHop: true)..port = port;
      final server = ProxyServer(
        configuration,
        systemProxyGateway: gateway,
        isDesktop: true,
        isMacOS: true,
        upstreamReachabilityProbe: (_) async => true,
        persistConfiguration: () async {},
        initializeCertificates: () async {},
        interceptorFactory: () => [],
      );
      await server.start();

      gateway.restoreStarted = Completer<void>();
      gateway.restoreBarrier = Completer<void>();
      final stop = server.stop();
      await gateway.restoreStarted!.future;

      final enableSystemProxy = server.setSystemProxyEnable(true);
      final enableFirstHop = server.setFirstHopProxyMode(true);
      expect(server.isStopping, isTrue);
      await expectLater(enableSystemProxy, throwsStateError);
      await expectLater(enableFirstHop, throwsStateError);

      gateway.restoreBarrier!.complete();
      await stop;

      expect(server.isRunning, isFalse);
      expect(gateway.configured.hasSameRouting(original), isTrue);
      expect(gateway.takeOwnershipCalls, 1);
    });

    test('last stop intent cancels a start queued behind an in-flight stop', () async {
      final port = await _unusedPort();
      final original = _surgeSnapshot();
      final gateway = _FakeSystemProxyGateway(configured: original, effective: original);
      final configuration = _configuration(firstHop: true)..port = port;
      final server = ProxyServer(
        configuration,
        systemProxyGateway: gateway,
        isDesktop: true,
        isMacOS: true,
        upstreamReachabilityProbe: (_) async => true,
        persistConfiguration: () async {},
        initializeCertificates: () async {},
        interceptorFactory: () => [],
      );
      await server.start();

      gateway.restoreStarted = Completer<void>();
      gateway.restoreBarrier = Completer<void>();
      final firstStop = server.stop();
      await gateway.restoreStarted!.future;

      final queuedStartExpectation = expectLater(server.start(), throwsStateError);
      final finalStop = server.stop();
      gateway.restoreBarrier!.complete();

      await Future.wait([firstStop, finalStop]);
      await queuedStartExpectation;

      expect(server.isRunning, isFalse);
      expect(gateway.configured.hasSameRouting(original), isTrue);
      expect(gateway.takeOwnershipCalls, 1);
    });

    test('app termination cancels a start queued behind an in-flight stop', () async {
      final port = await _unusedPort();
      final original = _surgeSnapshot();
      final gateway = _FakeSystemProxyGateway(configured: original, effective: original);
      final configuration = _configuration(firstHop: true)..port = port;
      final server = ProxyServer(
        configuration,
        systemProxyGateway: gateway,
        isDesktop: true,
        isMacOS: true,
        upstreamReachabilityProbe: (_) async => true,
        persistConfiguration: () async {},
        initializeCertificates: () async {},
        interceptorFactory: () => [],
      );
      await server.start();

      gateway.restoreStarted = Completer<void>();
      gateway.restoreBarrier = Completer<void>();
      final stop = server.stop();
      await gateway.restoreStarted!.future;

      final queuedStartExpectation = expectLater(server.start(), throwsStateError);
      server.beginAppTermination(42);
      gateway.restoreBarrier!.complete();

      await stop;
      await queuedStartExpectation;

      expect(server.isRunning, isFalse);
      expect(server.appTerminationLocked, isTrue);
      expect(gateway.takeOwnershipCalls, 1);
    });

    test('retryBind cannot revive a stopping or stopped listener', () async {
      final port = await _unusedPort();
      final original = _surgeSnapshot();
      final gateway = _FakeSystemProxyGateway(configured: original, effective: original);
      final configuration = _configuration(firstHop: true)..port = port;
      final server = ProxyServer(
        configuration,
        systemProxyGateway: gateway,
        isDesktop: true,
        isMacOS: true,
        upstreamReachabilityProbe: (_) async => true,
        persistConfiguration: () async {},
        initializeCertificates: () async {},
        interceptorFactory: () => [],
      );
      await server.start();

      gateway.restoreStarted = Completer<void>();
      gateway.restoreBarrier = Completer<void>();
      final stop = server.stop();
      await gateway.restoreStarted!.future;

      await server.retryBind();
      gateway.restoreBarrier!.complete();
      await stop;

      await server.retryBind();

      expect(server.isRunning, isFalse);
      expect(gateway.configured.hasSameRouting(original), isTrue);
      expect(gateway.takeOwnershipCalls, 1);
    });

    test('safe coexistence never writes system proxy', () async {
      final original = _surgeSnapshot();
      final gateway = _FakeSystemProxyGateway(configured: original, effective: original);
      final configuration = _configuration(firstHop: false);
      final server = _server(configuration, gateway);

      final result = await server.setSystemProxyEnable(true);

      expect(result.state, SystemProxyActivationState.overridden);
      expect(gateway.takeOwnershipCalls, 0);
      expect(configuration.runtimeExternalProxy?.port, 8888);
    });

    test('routes 9099 through the original 8888 upstream and restores it', () async {
      final original = _surgeSnapshot();
      final gateway = _FakeSystemProxyGateway(configured: original, effective: original);
      final configuration = _configuration(firstHop: true);
      final server = _server(configuration, gateway);

      final enabled = await server.setSystemProxyEnable(true);

      expect(enabled.state, SystemProxyActivationState.owned);
      expect(gateway.takeOwnershipCalls, 1);
      expect(gateway.configured.isOwnedBy(host: '127.0.0.1', port: 9099), isTrue);
      expect(configuration.runtimeExternalProxy?.port, 8888);

      await server.setSystemProxyEnable(false);

      expect(gateway.restoreCalls, 1);
      expect(gateway.configured.hasSameRouting(original), isTrue);
      expect(configuration.runtimeExternalProxy, isNull);
    });

    test('uses the configured 8888 route when scutil has no effective HTTP proxy', () async {
      final original = _surgeSnapshot();
      final gateway = _FakeSystemProxyGateway(
        configured: original,
        effective: const SystemProxySnapshot(),
      );
      final configuration = _configuration(firstHop: true);
      final server = _server(configuration, gateway);

      final enabled = await server.setSystemProxyEnable(true);

      expect(enabled.state, SystemProxyActivationState.owned);
      expect(configuration.runtimeExternalProxy?.port, 8888);
      expect(configuration.effectiveSystemProxyBackup?.hasSameRouting(original), isTrue);
    });

    test('does not write when the original upstream is unreachable', () async {
      final original = _surgeSnapshot();
      final gateway = _FakeSystemProxyGateway(configured: original, effective: original);
      final configuration = _configuration(firstHop: true);
      final server = _server(configuration, gateway, upstreamReachable: false);

      await expectLater(server.setSystemProxyEnable(true), throwsStateError);

      expect(gateway.takeOwnershipCalls, 0);
      expect(gateway.restoreCalls, 0);
      expect(configuration.systemProxyBackup, isNull);
    });

    test('does not write when the same service changes immediately before takeover', () async {
      final original = _surgeSnapshot();
      final newer = SystemProxySnapshot(
        http: ProxyInfo.of('127.0.0.1', 7777),
        https: ProxyInfo.of('127.0.0.1', 7777),
        bypassDomains: 'new-owner',
        networkService: 'Wi-Fi',
      );
      final gateway = _FakeSystemProxyGateway(
        configured: original,
        effective: original,
        mutateConfiguredOnSnapshotCall: 2,
        configuredMutation: newer,
      );
      final configuration = _configuration(firstHop: true);
      final server = _server(configuration, gateway);

      await expectLater(server.setSystemProxyEnable(true), throwsStateError);

      expect(gateway.takeOwnershipCalls, 0);
      expect(gateway.configured.hasSameRouting(newer), isTrue);
      expect(configuration.systemProxyBackup, isNull);
    });

    test('does not write when the effective Surge route changes before takeover', () async {
      final original = _surgeSnapshot();
      final newer = SystemProxySnapshot(
        http: ProxyInfo.of('127.0.0.1', 7777),
        https: ProxyInfo.of('127.0.0.1', 7777),
      );
      final gateway = _FakeSystemProxyGateway(
        configured: original,
        effective: original,
        mutateEffectiveOnSnapshotCall: 2,
        effectiveMutation: newer,
      );
      final configuration = _configuration(firstHop: true);
      final server = _server(configuration, gateway);

      await expectLater(server.setSystemProxyEnable(true), throwsStateError);

      expect(gateway.takeOwnershipCalls, 0);
      expect(gateway.configured.hasSameRouting(original), isTrue);
    });

    test('rolls back when the configured proxy changes but effective routing does not', () async {
      final original = _surgeSnapshot();
      final gateway = _FakeSystemProxyGateway(
        configured: original,
        effective: original,
        mirrorEffectiveOnTakeOwnership: false,
      );
      final configuration = _configuration(firstHop: true);
      final server = _server(configuration, gateway);

      await expectLater(server.setSystemProxyEnable(true), throwsStateError);

      expect(gateway.takeOwnershipCalls, 1);
      expect(gateway.restoreCalls, 1);
      expect(gateway.configured.hasSameRouting(original), isTrue);
      expect(configuration.systemProxyBackup, isNull);
    });

    test('waits for the effective proxy to converge before reporting first-hop success', () async {
      final original = _surgeSnapshot();
      final owned = SystemProxySnapshot(
        http: ProxyInfo.of('127.0.0.1', 9099),
        https: ProxyInfo.of('127.0.0.1', 9099),
      );
      final gateway = _FakeSystemProxyGateway(
        configured: original,
        effective: original,
        mirrorEffectiveOnTakeOwnership: false,
        effectiveAfterTakeSequence: [original, original, owned, owned],
      );
      final configuration = _configuration(firstHop: true);
      final server = _server(configuration, gateway);

      final result = await server.setSystemProxyEnable(true);

      expect(result.state, SystemProxyActivationState.owned);
      expect(gateway.restoreCalls, 0);
      expect(configuration.systemProxyBackup, isNotNull);
    });

    test('does not accept a transient effective ownership sample', () async {
      final original = _surgeSnapshot();
      final owned = SystemProxySnapshot(
        http: ProxyInfo.of('127.0.0.1', 9099),
        https: ProxyInfo.of('127.0.0.1', 9099),
      );
      final gateway = _FakeSystemProxyGateway(
        configured: original,
        effective: original,
        mirrorEffectiveOnTakeOwnership: false,
        effectiveAfterTakeSequence: [owned, original, original, original, original, original, original],
      );
      final configuration = _configuration(firstHop: true);
      final server = _server(configuration, gateway);

      await expectLater(server.setSystemProxyEnable(true), throwsStateError);

      expect(gateway.restoreCalls, 1);
      expect(gateway.configured.hasSameRouting(original), isTrue);
      expect(configuration.systemProxyBackup, isNull);
    });

    test('rolls back a partial HTTP takeover', () async {
      final original = _surgeSnapshot();
      final gateway = _FakeSystemProxyGateway(
        configured: original,
        effective: original,
        failTakeAfterHttp: true,
      );
      final configuration = _configuration(firstHop: true);
      final server = _server(configuration, gateway);

      await expectLater(server.setSystemProxyEnable(true), throwsStateError);

      expect(gateway.takeOwnershipCalls, 1);
      expect(gateway.restoreCalls, 1);
      expect(gateway.configured.hasSameRouting(original), isTrue);
      expect(configuration.systemProxyBackup, isNull);
    });

    test('clears the prepared lease when authorization is denied before any write', () async {
      final original = _surgeSnapshot();
      final gateway = _FakeSystemProxyGateway(
        configured: original,
        effective: original,
        failTakeBeforeWrite: true,
      );
      final configuration = _configuration(firstHop: true);
      final server = _server(configuration, gateway);

      await expectLater(server.setSystemProxyEnable(true), throwsA(isA<SystemProxyTransactionException>()));

      expect(gateway.takeOwnershipCalls, 1);
      expect(gateway.restoreCalls, 0);
      expect(gateway.configured.hasSameRouting(original), isTrue);
      expect(configuration.systemProxyBackup, isNull);
    });

    test('rolls back when the frozen upstream fails immediately after takeover', () async {
      final original = _surgeSnapshot();
      final gateway = _FakeSystemProxyGateway(configured: original, effective: original);
      final configuration = _configuration(firstHop: true);
      final server = _server(
        configuration,
        gateway,
        upstreamReachabilityResults: [true, true, false],
      );

      await expectLater(server.setSystemProxyEnable(true), throwsStateError);

      expect(gateway.takeOwnershipCalls, 1);
      expect(gateway.restoreCalls, 1);
      expect(gateway.configured.hasSameRouting(original), isTrue);
    });

    test('keeps mode and lease visible when activation rollback also fails', () async {
      final original = _surgeSnapshot();
      final gateway = _FakeSystemProxyGateway(
        configured: original,
        effective: original,
        failTakeAfterHttp: true,
      )..failRestore = true;
      final configuration = _configuration(firstHop: false);
      final server = _server(configuration, gateway);

      await expectLater(server.setFirstHopProxyMode(true), throwsStateError);

      expect(configuration.firstHopProxyMode, isTrue);
      expect(configuration.systemProxyBackup?.hasSameRouting(original), isTrue);
      expect(gateway.configured.ownershipBy(host: '127.0.0.1', port: 9099), SystemProxyOwnership.partial);
    });

    test('does not write while the listener is stopped', () async {
      final original = _surgeSnapshot();
      final gateway = _FakeSystemProxyGateway(configured: original, effective: original);
      final configuration = _configuration(firstHop: true);
      final server = _server(configuration, gateway, listenerReady: false);

      final result = await server.setSystemProxyEnable(true);

      expect(result.state, SystemProxyActivationState.disabled);
      expect(gateway.configuredSnapshotCalls, 0);
      expect(gateway.takeOwnershipCalls, 0);
    });

    test('does not overwrite a newer proxy owner during shutdown', () async {
      final original = _surgeSnapshot();
      final gateway = _FakeSystemProxyGateway(configured: original, effective: original);
      final configuration = _configuration(firstHop: true);
      final server = _server(configuration, gateway);
      await server.setSystemProxyEnable(true);

      gateway.configured = SystemProxySnapshot(
        http: ProxyInfo.of('127.0.0.1', 7777),
        https: ProxyInfo.of('127.0.0.1', 7777),
        bypassDomains: 'new-owner',
        networkService: 'Wi-Fi',
      );
      await server.setSystemProxyEnable(false);

      expect(gateway.restoreCalls, 1);
      expect(gateway.configured.http?.port, 7777);
      expect(gateway.configured.bypassDomains, 'new-owner');
    });

    test('preserves a newer bypass after another owner replaces both endpoints', () async {
      final original = _surgeSnapshot();
      final gateway = _FakeSystemProxyGateway(configured: original, effective: original);
      final configuration = _configuration(firstHop: true);
      final server = _server(configuration, gateway);
      await server.setSystemProxyEnable(true);

      gateway.configured = SystemProxySnapshot(
        http: ProxyInfo.of('127.0.0.1', 7777),
        https: ProxyInfo.of('127.0.0.1', 7777),
        bypassDomains: configuration.proxyPassDomains,
        networkService: 'Wi-Fi',
      );
      await server.setSystemProxyEnable(false);

      expect(gateway.configured.http?.port, 7777);
      expect(gateway.configured.https?.port, 7777);
      expect(gateway.configured.bypassDomains, configuration.proxyPassDomains);
    });

    test('restores only the protocol still owned by ProxyPin', () async {
      final original = _surgeSnapshot();
      final gateway = _FakeSystemProxyGateway(configured: original, effective: original);
      final configuration = _configuration(firstHop: true);
      final server = _server(configuration, gateway);
      await server.setSystemProxyEnable(true);

      gateway.configured = SystemProxySnapshot(
        http: ProxyInfo.of('127.0.0.1', 9099),
        https: ProxyInfo.of('127.0.0.1', 7777),
        bypassDomains: configuration.proxyPassDomains,
        networkService: 'Wi-Fi',
      );
      await server.setSystemProxyEnable(false);

      expect(gateway.configured.http?.port, 8888);
      expect(gateway.configured.https?.port, 7777);
      expect(configuration.systemProxyBackup, isNull);
    });

    test('restores the leased service after the active service changes', () async {
      final original = _surgeSnapshot();
      final gateway = _FakeSystemProxyGateway(configured: original, effective: original);
      final configuration = _configuration(firstHop: true);
      final server = _server(configuration, gateway);
      await server.setSystemProxyEnable(true);

      gateway.setServiceSnapshot(SystemProxySnapshot(
        http: ProxyInfo.of('127.0.0.1', 7777),
        https: ProxyInfo.of('127.0.0.1', 7777),
        bypassDomains: 'usb-owner',
        networkService: 'USB 10/100/1000 LAN',
      ));
      gateway.activeNetworkService = 'USB 10/100/1000 LAN';

      await server.setSystemProxyEnable(false);

      expect(gateway.snapshotFor('Wi-Fi').hasSameRouting(original), isTrue);
      expect(gateway.snapshotFor('USB 10/100/1000 LAN').http?.port, 7777);
      expect(gateway.lastRestoreNetworkService, 'Wi-Fi');
    });

    test('keeps the recovery lease when restore fails and allows retry', () async {
      final original = _surgeSnapshot();
      final gateway = _FakeSystemProxyGateway(configured: original, effective: original);
      final configuration = _configuration(firstHop: true);
      final server = _server(configuration, gateway);
      await server.setSystemProxyEnable(true);

      gateway.failRestore = true;
      await expectLater(server.setSystemProxyEnable(false), throwsStateError);
      expect(configuration.systemProxyBackup?.hasSameRouting(original), isTrue);

      gateway.failRestore = false;
      await server.setSystemProxyEnable(false);
      expect(gateway.restoreCalls, 2);
      expect(gateway.configured.hasSameRouting(original), isTrue);
    });

    test('keeps the old listener lease while effective routing still references it', () async {
      final original = _surgeSnapshot();
      final gateway = _FakeSystemProxyGateway(configured: original, effective: original);
      final configuration = _configuration(firstHop: true);
      final server = _server(configuration, gateway);
      await server.setSystemProxyEnable(true);

      gateway.keepEffectiveRouteOnRestore = true;
      await expectLater(server.setSystemProxyEnable(false), throwsStateError);

      expect(configuration.systemProxyBackup, isNotNull);
      expect(server.systemProxyRoutingLocked, isTrue);
      expect(server.systemProxyActivation.state, SystemProxyActivationState.recoveryRequired);

      gateway.keepEffectiveRouteOnRestore = false;
      await server.setSystemProxyEnable(false);
      expect(configuration.systemProxyBackup, isNull);
      expect(gateway.configured.hasSameRouting(original), isTrue);
    });

    test('restores ownership even if the listener has already stopped', () async {
      final original = _surgeSnapshot();
      final gateway = _FakeSystemProxyGateway(configured: original, effective: original);
      final configuration = _configuration(firstHop: true);
      final server = _server(configuration, gateway);
      await server.setSystemProxyEnable(true);

      // The injected listener reports ready for activation, while ProxyServer's
      // real socket is intentionally absent in this unit test.
      await server.stop();

      expect(gateway.restoreCalls, 1);
      expect(gateway.configured.hasSameRouting(original), isTrue);
    });

    test('recovers a persisted lease using its immutable owner port', () async {
      final original = _surgeSnapshot();
      final owned = SystemProxySnapshot(
        http: ProxyInfo.of('127.0.0.1', 9099),
        https: ProxyInfo.of('127.0.0.1', 9099),
        bypassDomains: 'lease-bypass',
        networkService: 'Wi-Fi',
      );
      final gateway = _FakeSystemProxyGateway(configured: owned, effective: owned);
      final configuration = _configuration(firstHop: false)
        ..port = 9191
        ..enableSystemProxy = false
        ..systemProxyBackup = original
        ..systemProxyLeaseOwnerHost = '127.0.0.1'
        ..systemProxyLeaseOwnerPort = 9099
        ..systemProxyLeaseBypassDomains = 'lease-bypass';
      final server = _server(configuration, gateway, listenerReady: false);

      await server.setSystemProxyEnable(false);

      expect(gateway.configured.hasSameRouting(original), isTrue);
      expect(configuration.systemProxyBackup, isNull);
      expect(configuration.systemProxyLeaseOwnerPort, isNull);
    });

    test('refuses to stop a listener still referenced by macOS when no lease exists', () async {
      final owned = SystemProxySnapshot(
        http: ProxyInfo.of('127.0.0.1', 9099),
        https: ProxyInfo.of('127.0.0.1', 9099),
        networkService: 'Wi-Fi',
      );
      final gateway = _FakeSystemProxyGateway(configured: owned, effective: owned);
      final configuration = _configuration(firstHop: false)..systemProxyBackup = null;
      final server = _server(configuration, gateway);

      await expectLater(server.stop(), throwsStateError);

      expect(server.systemProxyActivation.state, SystemProxyActivationState.recoveryRequired);
      expect(server.systemProxyRoutingLocked, isTrue);
      expect(gateway.restoreCalls, 0);
    });

    test('locks an unleased listener already referenced by macOS during passive startup', () async {
      final owned = SystemProxySnapshot(
        http: ProxyInfo.of('127.0.0.1', 9099),
        https: ProxyInfo.of('127.0.0.1', 9099),
        networkService: 'Wi-Fi',
      );
      final gateway = _FakeSystemProxyGateway(configured: owned, effective: owned);
      final configuration = _configuration(firstHop: false)..systemProxyBackup = null;
      final server = _server(configuration, gateway);

      final result = await server.setSystemProxyEnable(true);

      expect(result.state, SystemProxyActivationState.recoveryRequired);
      expect(server.systemProxyRoutingLocked, isTrue);
      expect(gateway.takeOwnershipCalls, 0);
    });

    test('rejects port zero before binding or writing system proxy', () async {
      final original = _surgeSnapshot();
      final gateway = _FakeSystemProxyGateway(configured: original, effective: original);
      final configuration = _configuration(firstHop: true)..port = 0;
      final server = _server(configuration, gateway);

      await expectLater(server.setSystemProxyEnable(true), throwsStateError);

      expect(gateway.configuredSnapshotCalls, 0);
      expect(gateway.takeOwnershipCalls, 0);
    });

    test('recovery startup restores the immutable old port before binding the new port', () async {
      final oldPort = await _unusedPort();
      var newPort = await _unusedPort();
      while (newPort == oldPort) {
        newPort = await _unusedPort();
      }
      final original = _surgeSnapshot();
      final owned = SystemProxySnapshot(
        http: ProxyInfo.of('127.0.0.1', oldPort),
        https: ProxyInfo.of('127.0.0.1', oldPort),
        bypassDomains: original.bypassDomains,
        networkService: 'Wi-Fi',
      );
      final gateway = _FakeSystemProxyGateway(configured: owned, effective: owned);
      final configuration = _configuration(firstHop: false)
        ..port = newPort
        ..enableSystemProxy = false
        ..systemProxyBackup = original
        ..effectiveSystemProxyBackup = original
        ..systemProxyLeaseOwnerHost = '127.0.0.1'
        ..systemProxyLeaseOwnerPort = oldPort
        ..systemProxyLeaseBypassDomains = original.bypassDomains;
      final server = ProxyServer(
        configuration,
        systemProxyGateway: gateway,
        isDesktop: true,
        isMacOS: true,
        upstreamReachabilityProbe: (_) async => true,
        persistConfiguration: () async {},
        initializeCertificates: () async {},
        interceptorFactory: () => [],
      );

      await server.start();

      expect(server.port, newPort);
      expect(configuration.systemProxyBackup, isNull);
      expect(gateway.configured.hasSameRouting(original), isTrue);
      await server.stop();
    });

    test('recovery startup restores the lease when certificate initialization fails', () async {
      final oldPort = await _unusedPort();
      final original = _surgeSnapshot();
      final owned = SystemProxySnapshot(
        http: ProxyInfo.of('127.0.0.1', oldPort),
        https: ProxyInfo.of('127.0.0.1', oldPort),
        bypassDomains: original.bypassDomains,
        networkService: 'Wi-Fi',
      );
      final gateway = _FakeSystemProxyGateway(configured: owned, effective: owned);
      final configuration = _configuration(firstHop: false)
        ..port = oldPort
        ..enableSystemProxy = false
        ..systemProxyBackup = original
        ..effectiveSystemProxyBackup = original
        ..systemProxyLeaseOwnerHost = '127.0.0.1'
        ..systemProxyLeaseOwnerPort = oldPort
        ..systemProxyLeaseBypassDomains = original.bypassDomains;
      final server = ProxyServer(
        configuration,
        systemProxyGateway: gateway,
        isDesktop: true,
        isMacOS: true,
        upstreamReachabilityProbe: (_) async => true,
        persistConfiguration: () async {},
        initializeCertificates: () async => throw StateError('CA unavailable'),
        interceptorFactory: () => [],
      );

      await expectLater(server.start(), throwsStateError);

      expect(gateway.restoreCalls, 1);
      expect(gateway.configured.hasSameRouting(original), isTrue);
      expect(configuration.systemProxyBackup, isNull);
      expect(server.isRunning, isFalse);
    });

    test('recovery startup restores the lease when the old listener port cannot bind', () async {
      final occupied = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
      addTearDown(occupied.close);
      final oldPort = occupied.port;
      final original = _surgeSnapshot();
      final owned = SystemProxySnapshot(
        http: ProxyInfo.of('127.0.0.1', oldPort),
        https: ProxyInfo.of('127.0.0.1', oldPort),
        bypassDomains: original.bypassDomains,
        networkService: 'Wi-Fi',
      );
      final gateway = _FakeSystemProxyGateway(configured: owned, effective: owned);
      final configuration = _configuration(firstHop: false)
        ..port = oldPort
        ..enableSystemProxy = false
        ..systemProxyBackup = original
        ..effectiveSystemProxyBackup = original
        ..systemProxyLeaseOwnerHost = '127.0.0.1'
        ..systemProxyLeaseOwnerPort = oldPort
        ..systemProxyLeaseBypassDomains = original.bypassDomains;
      final server = ProxyServer(
        configuration,
        systemProxyGateway: gateway,
        isDesktop: true,
        isMacOS: true,
        upstreamReachabilityProbe: (_) async => true,
        persistConfiguration: () async {},
        initializeCertificates: () async {},
        interceptorFactory: () => [],
      );

      await expectLater(server.start(), throwsA(isA<SocketException>()));

      expect(gateway.restoreCalls, 1);
      expect(gateway.configured.hasSameRouting(original), isTrue);
      expect(configuration.systemProxyBackup, isNull);
    });

    test('does not write if the recovery lease cannot be persisted', () async {
      final original = _surgeSnapshot();
      final gateway = _FakeSystemProxyGateway(configured: original, effective: original);
      final configuration = _configuration(firstHop: true);
      final server = ProxyServer(
        configuration,
        systemProxyGateway: gateway,
        isDesktop: true,
        isMacOS: true,
        listenerReady: () => true,
        upstreamReachabilityProbe: (_) async => true,
        persistConfiguration: () async => throw StateError('disk unavailable'),
      );

      await expectLater(server.setSystemProxyEnable(true), throwsStateError);

      expect(gateway.takeOwnershipCalls, 0);
      expect(configuration.systemProxyBackup, isNull);
    });

    test('serializes a rapid first-hop on then off transition', () async {
      final original = _surgeSnapshot();
      final gateway = _FakeSystemProxyGateway(configured: original, effective: original);
      final configuration = _configuration(firstHop: false);
      final server = _server(configuration, gateway);

      final enable = server.setFirstHopProxyMode(true);
      final disable = server.setFirstHopProxyMode(false);
      await Future.wait([enable, disable]);

      expect(configuration.firstHopProxyMode, isFalse);
      expect(gateway.takeOwnershipCalls, 1);
      expect(gateway.restoreCalls, 1);
      expect(gateway.configured.hasSameRouting(original), isTrue);
    });

    test('rejects first-hop when single-upstream chaining is off', () async {
      final original = _surgeSnapshot();
      final gateway = _FakeSystemProxyGateway(configured: original, effective: original);
      final configuration = _configuration(firstHop: true)..chainSystemProxy = false;
      final server = _server(configuration, gateway);

      await expectLater(server.setSystemProxyEnable(true), throwsStateError);

      expect(gateway.configuredSnapshotCalls, 0);
      expect(gateway.takeOwnershipCalls, 0);
    });

    test('rolls back the snapshotted service if the active service switches during takeover', () async {
      final original = _surgeSnapshot();
      final gateway = _FakeSystemProxyGateway(
        configured: original,
        effective: original,
        activeServiceAfterTakeStarts: 'USB 10/100/1000 LAN',
      );
      gateway.setServiceSnapshot(SystemProxySnapshot(
        http: ProxyInfo.of('127.0.0.1', 7777),
        https: ProxyInfo.of('127.0.0.1', 7777),
        networkService: 'USB 10/100/1000 LAN',
      ));
      final configuration = _configuration(firstHop: true);
      final server = _server(configuration, gateway);

      await expectLater(server.setSystemProxyEnable(true), throwsStateError);

      expect(gateway.lastTakeNetworkService, 'Wi-Fi');
      expect(gateway.snapshotFor('Wi-Fi').hasSameRouting(original), isTrue);
      expect(gateway.snapshotFor('USB 10/100/1000 LAN').http?.port, 7777);
      expect(gateway.restoreCalls, 1);
    });

    test('freezes a validated manual upstream for the active lease', () async {
      final original = _surgeSnapshot();
      final gateway = _FakeSystemProxyGateway(configured: original, effective: original);
      final configuration = _configuration(firstHop: true)
        ..externalProxy = (ProxyInfo.of('127.0.0.1', 8888)..enabled = true);
      final server = _server(configuration, gateway);

      await server.setSystemProxyEnable(true);
      configuration.externalProxy = ProxyInfo.of('127.0.0.1', 7777)..enabled = true;

      expect(configuration.effectiveExternalProxy?.port, 8888);
    });
  });

  group('first hop configuration', () {
    test('is disabled by default', () {
      expect(Configuration.fromJson({}).firstHopProxyMode, isFalse);
    });

    test('rejects persisted port zero and keeps the safe default', () {
      expect(Configuration.fromJson({'port': 0}).port, 9099);
    });

    test('round trips independently from upstream chaining', () {
      final configuration = Configuration.fromJson({
        'firstHopProxyMode': true,
        'chainSystemProxy': false,
      });

      final json = configuration.toJson();

      expect(json['firstHopProxyMode'], isTrue);
      expect(json['chainSystemProxy'], isFalse);
    });

    test('keeps routing locked while a recovery lease exists', () {
      final configuration = _configuration(firstHop: false)
        ..systemProxyBackup = _surgeSnapshot()
        ..runtimeExternalProxy = (ProxyInfo.of('127.0.0.1', 8888)..enabled = true);

      expect(configuration.systemProxyLeaseLocked, isTrue);
      expect(configuration.effectiveExternalProxy?.port, 8888);
    });
  });
}

Configuration _configuration({required bool firstHop}) {
  return Configuration.fromJson({
    'port': 9099,
    'enableSystemProxy': true,
    'firstHopProxyMode': firstHop,
    'chainSystemProxy': true,
  });
}

ProxyServer _server(
  Configuration configuration,
  _FakeSystemProxyGateway gateway, {
  bool upstreamReachable = true,
  bool listenerReady = true,
  List<bool>? upstreamReachabilityResults,
}) {
  final probeResults = [...?upstreamReachabilityResults];
  return ProxyServer(
    configuration,
    systemProxyGateway: gateway,
    isDesktop: true,
    isMacOS: true,
    listenerReady: () => listenerReady,
    upstreamReachabilityProbe: (_) async => probeResults.isEmpty ? upstreamReachable : probeResults.removeAt(0),
    systemProxyPropagationDelay: (_) async {},
    persistConfiguration: () async {},
    interceptorFactory: () => [],
  );
}

Future<int> _unusedPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

SystemProxySnapshot _surgeSnapshot() {
  return SystemProxySnapshot(
    http: ProxyInfo.of('127.0.0.1', 8888),
    https: ProxyInfo.of('127.0.0.1', 8888),
    bypassDomains: 'localhost;*.local',
    networkService: 'Wi-Fi',
  );
}

class _FakeSystemProxyGateway implements SystemProxyGateway {
  _FakeSystemProxyGateway({
    required SystemProxySnapshot configured,
    required this.effective,
    this.mirrorEffectiveOnTakeOwnership = true,
    this.failTakeAfterHttp = false,
    this.failTakeBeforeWrite = false,
    this.activeServiceAfterTakeStarts,
    this.mutateConfiguredOnSnapshotCall,
    this.configuredMutation,
    this.mutateEffectiveOnSnapshotCall,
    this.effectiveMutation,
    List<SystemProxySnapshot>? effectiveAfterTakeSequence,
  })  : effectiveAfterTakeSequence = [...?effectiveAfterTakeSequence],
        activeNetworkService = configured.networkService ?? 'default' {
    setServiceSnapshot(configured);
  }

  final Map<String, SystemProxySnapshot> _configuredByService = {};
  SystemProxySnapshot effective;
  final bool mirrorEffectiveOnTakeOwnership;
  final bool failTakeAfterHttp;
  final bool failTakeBeforeWrite;
  final String? activeServiceAfterTakeStarts;
  final int? mutateConfiguredOnSnapshotCall;
  final SystemProxySnapshot? configuredMutation;
  final int? mutateEffectiveOnSnapshotCall;
  final SystemProxySnapshot? effectiveMutation;
  final List<SystemProxySnapshot> effectiveAfterTakeSequence;
  late String activeNetworkService;
  bool failRestore = false;
  int configuredSnapshotCalls = 0;
  int takeOwnershipCalls = 0;
  int restoreCalls = 0;
  int effectiveSnapshotCalls = 0;
  bool keepEffectiveRouteOnRestore = false;
  Completer<void>? restoreStarted;
  Completer<void>? restoreBarrier;
  String? lastTakeNetworkService;
  String? lastRestoreNetworkService;

  SystemProxySnapshot get configured => snapshotFor(activeNetworkService);

  set configured(SystemProxySnapshot snapshot) {
    setServiceSnapshot(snapshot);
    activeNetworkService = snapshot.networkService ?? activeNetworkService;
  }

  SystemProxySnapshot snapshotFor(String service) {
    return _configuredByService[service] ?? SystemProxySnapshot(networkService: service);
  }

  void setServiceSnapshot(SystemProxySnapshot snapshot) {
    final service = snapshot.networkService ?? activeNetworkService;
    _configuredByService[service] = SystemProxySnapshot(
      http: snapshot.http,
      https: snapshot.https,
      bypassDomains: snapshot.bypassDomains,
      autoConfigEnabled: snapshot.autoConfigEnabled,
      networkService: service,
    );
  }

  @override
  Future<SystemProxySnapshot> configuredSnapshot({String? networkService}) async {
    configuredSnapshotCalls += 1;
    if (configuredSnapshotCalls == mutateConfiguredOnSnapshotCall && configuredMutation != null) {
      setServiceSnapshot(configuredMutation!);
    }
    return snapshotFor(networkService ?? activeNetworkService);
  }

  @override
  Future<SystemProxySnapshot> effectiveSnapshot() async {
    effectiveSnapshotCalls += 1;
    if (takeOwnershipCalls > 0 && effectiveAfterTakeSequence.isNotEmpty) {
      effective = effectiveAfterTakeSequence.removeAt(0);
    }
    if (effectiveSnapshotCalls == mutateEffectiveOnSnapshotCall && effectiveMutation != null) {
      effective = effectiveMutation!;
    }
    return effective;
  }

  @override
  Future<void> takeOwnership({
    required int port,
    required String passDomains,
    required String? networkService,
    required SystemProxySnapshot expected,
  }) async {
    takeOwnershipCalls += 1;
    if (failTakeBeforeWrite) {
      throw const SystemProxyTransactionException(
        message: 'authorization denied',
        code: 'SYSTEM_PROXY_AUTHORIZATION_DENIED',
        mayHaveChanged: false,
      );
    }
    final service = networkService ?? activeNetworkService;
    lastTakeNetworkService = service;
    final before = snapshotFor(service);
    if (activeServiceAfterTakeStarts != null) {
      activeNetworkService = activeServiceAfterTakeStarts!;
    }
    setServiceSnapshot(SystemProxySnapshot(
      http: ProxyInfo.of('127.0.0.1', port),
      https: failTakeAfterHttp ? before.https : ProxyInfo.of('127.0.0.1', port),
      bypassDomains: expected.bypassDomains,
      networkService: service,
    ));
    if (failTakeAfterHttp) throw StateError('secure proxy write failed');
    if (mirrorEffectiveOnTakeOwnership && activeNetworkService == service) {
      effective = SystemProxySnapshot(
        http: ProxyInfo.of('127.0.0.1', port),
        https: ProxyInfo.of('127.0.0.1', port),
      );
    }
  }

  @override
  Future<void> restoreOwnedEndpoints({
    required SystemProxySnapshot backup,
    required String ownerHost,
    required int ownerPort,
    required String expectedBypassDomains,
  }) async {
    restoreCalls += 1;
    final started = restoreStarted;
    if (started != null && !started.isCompleted) started.complete();
    await restoreBarrier?.future;
    if (failRestore) throw StateError('restore failed');
    final service = backup.networkService ?? activeNetworkService;
    lastRestoreNetworkService = service;
    final current = snapshotFor(service);
    final owner = ProxyInfo.of(ownerHost, ownerPort);
    setServiceSnapshot(SystemProxySnapshot(
      http: current.http?.hasSameEndpoint(owner) == true ? backup.http : current.http,
      https: current.https?.hasSameEndpoint(owner) == true ? backup.https : current.https,
      bypassDomains: current.bypassDomains == expectedBypassDomains ? backup.bypassDomains : current.bypassDomains,
      networkService: service,
    ));
    if (!keepEffectiveRouteOnRestore) effective = snapshotFor(service);
  }
}
