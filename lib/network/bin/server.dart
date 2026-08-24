/*
 * Copyright 2023 Hongen Wang All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/components/hosts.dart';
import 'package:proxypin/network/components/interceptor.dart';
import 'package:proxypin/network/components/report_server_interceptor.dart';
import 'package:proxypin/network/components/request_block.dart';
import 'package:proxypin/network/components/request_rewrite.dart';
import 'package:proxypin/network/components/script.dart';
import 'package:proxypin/network/handle/http_proxy_handle.dart';
import 'package:proxypin/network/util/crts.dart';
import 'package:proxypin/utils/platform.dart';

import '../components/request_map.dart';
import '../http/codec.dart';
import '../channel/network.dart';
import '../channel/host_port.dart';
import '../util/logger.dart';
import '../util/system_proxy.dart';
import '../util/system_proxy_snapshot.dart';
import 'listener.dart';
import 'package:proxypin/network/components/request_breakpoint.dart';

Future<void> main() async {
  var configuration = await Configuration.instance;
  ProxyServer(configuration).start();
}

enum SystemProxyActivationState { disabled, owned, overridden, recoveryRequired }

class SystemProxyActivationResult {
  final SystemProxyActivationState state;
  final ProxyInfo? effectiveProxy;

  const SystemProxyActivationResult(this.state, {this.effectiveProxy});

  bool get isOverridden => state == SystemProxyActivationState.overridden;
}

/// Injectable boundary around macOS system proxy operations.
///
/// Production delegates to [SystemProxy]. Tests can use an in-memory fake so
/// they never invoke `networksetup`, `scutil`, or change the developer machine.
abstract interface class SystemProxyGateway {
  Future<SystemProxySnapshot> configuredSnapshot({String? networkService});

  Future<SystemProxySnapshot> effectiveSnapshot();

  Future<void> takeOwnership({
    required int port,
    required String passDomains,
    required String? networkService,
    required SystemProxySnapshot expected,
  });

  Future<void> restoreOwnedEndpoints({
    required SystemProxySnapshot backup,
    required String ownerHost,
    required int ownerPort,
    required String expectedBypassDomains,
  });
}

class PlatformSystemProxyGateway implements SystemProxyGateway {
  const PlatformSystemProxyGateway();

  @override
  Future<SystemProxySnapshot> configuredSnapshot({String? networkService}) =>
      SystemProxy.getSystemProxySnapshot(networkService: networkService);

  @override
  Future<SystemProxySnapshot> effectiveSnapshot() => SystemProxy.getEffectiveSystemProxySnapshot();

  @override
  Future<void> takeOwnership({
    required int port,
    required String passDomains,
    required String? networkService,
    required SystemProxySnapshot expected,
  }) {
    return SystemProxy.takeSystemProxyOwnership(
      port: port,
      passDomains: passDomains,
      networkService: networkService,
      expected: expected,
    );
  }

  @override
  Future<void> restoreOwnedEndpoints({
    required SystemProxySnapshot backup,
    required String ownerHost,
    required int ownerPort,
    required String expectedBypassDomains,
  }) {
    return SystemProxy.restoreOwnedSystemProxyEndpoints(
      backup: backup,
      ownerHost: ownerHost,
      ownerPort: ownerPort,
      expectedBypassDomains: expectedBypassDomains,
    );
  }
}

/// 代理服务器
class ProxyServer {
  static ProxyServer? current;

  //socket服务
  Server? server;

  //请求事件监听
  List<EventListener> listeners = [];

  //配置
  final Configuration configuration;

  SystemProxyActivationResult _systemProxyActivation =
      const SystemProxyActivationResult(SystemProxyActivationState.disabled);

  SystemProxyActivationResult get systemProxyActivation => _systemProxyActivation;

  set systemProxyActivation(SystemProxyActivationResult value) {
    _systemProxyActivation = value;
    configuration.systemProxyRecoveryRequired = value.state == SystemProxyActivationState.recoveryRequired;
  }

  /// Whether this process actually changed macOS system proxy settings.
  /// Passive coexistence must never restore settings it did not mutate.
  bool _didMutateSystemProxyThisRun = false;

  final SystemProxyGateway _systemProxyGateway;
  final bool _isDesktop;
  final bool _isMacOS;
  late final Future<bool> Function(ProxyInfo upstream) _upstreamReachabilityProbe;
  late final Future<void> Function(Duration duration) _systemProxyPropagationDelay;
  late final Future<void> Function() _persistConfiguration;
  late final bool Function() _listenerReady;
  late final Future<void> Function() _initializeCertificates;
  late final List<Interceptor> Function() _interceptorFactory;

  int? _boundPort;

  /// Serializes start/stop and mode switches so backups cannot be interleaved
  /// by rapid UI changes.
  Future<void> _systemProxyTransition = Future<void>.value();

  /// A stop requested while CA initialization or socket binding is still in
  /// progress must wait for start to finish, then restore the proxy lease
  /// before closing the listener.
  Future<Server>? _pendingStart;

  /// Prevents a route-acquisition request from overtaking the final socket
  /// close. Without this, an MCP/UI enable queued behind restore could point
  /// macOS back to this port immediately before stop() closes the listener.
  Future<Server?>? _pendingStop;

  /// Monotonic intent token for the proxy listener lifecycle. Every public
  /// start/stop/restart request advances it so continuations queued behind a
  /// slow stop cannot override a newer user intent.
  int _lifecycleGeneration = 0;
  bool _desiredRunning = false;

  /// AppKit keeps the process alive briefly while Flutter restores a leased
  /// system proxy. Keep this lock in the server (not only in the toolbar) so
  /// MCP, diagnostics, retryBind and every other entry point fail closed too.
  int? _appTerminationRequestId;

  /// 状态变化广播流（start/stop 后通知订阅者更新 UI）
  final StreamController<bool> _statusController = StreamController<bool>.broadcast();

  /// 状态变化事件，参数为新的 running 状态
  Stream<bool> get onStatusChanged => _statusController.stream;

  ProxyServer(
    this.configuration, {
    SystemProxyGateway? systemProxyGateway,
    bool? isDesktop,
    bool? isMacOS,
    Future<bool> Function(ProxyInfo upstream)? upstreamReachabilityProbe,
    Future<void> Function(Duration duration)? systemProxyPropagationDelay,
    Future<void> Function()? persistConfiguration,
    bool Function()? listenerReady,
    Future<void> Function()? initializeCertificates,
    List<Interceptor> Function()? interceptorFactory,
  })  : _systemProxyGateway = systemProxyGateway ?? const PlatformSystemProxyGateway(),
        _isDesktop = isDesktop ?? Platforms.isDesktop(),
        _isMacOS = isMacOS ?? Platform.isMacOS {
    _upstreamReachabilityProbe = upstreamReachabilityProbe ?? _isAutomaticUpstreamReachable;
    _systemProxyPropagationDelay = systemProxyPropagationDelay ?? ((duration) => Future<void>.delayed(duration));
    _persistConfiguration = persistConfiguration ?? configuration.flushConfig;
    _listenerReady = listenerReady ?? (() => server?.isRunning ?? false);
    _initializeCertificates = initializeCertificates ?? CertificateManager.initCAConfig;
    _interceptorFactory = interceptorFactory ??
        () => [
              Hosts(),
              RequestMapInterceptor.instance,
              RequestRewriteInterceptor.instance,
              ScriptInterceptor(),
              RequestBlockInterceptor(),
              RequestBreakpointInterceptor.instance,
              ReportServerInterceptor(),
            ];
    current = this;
  }

  //是否启动
  bool get isRunning => server?.isRunning ?? false;

  ///是否启用https抓包
  bool get enableSsl => configuration.enableSsl;

  int get port => _boundPort ?? configuration.port;

  bool get systemProxyRoutingLocked =>
      configuration.systemProxyLeaseLocked || _pendingStart != null || _pendingStop != null || appTerminationLocked;

  bool get isStarting => _pendingStart != null;

  bool get isStopping => _pendingStop != null;

  bool get appTerminationLocked => _appTerminationRequestId != null;

  void beginAppTermination(int requestId) {
    _lifecycleGeneration += 1;
    _desiredRunning = false;
    _appTerminationRequestId = requestId;
  }

  void cancelAppTermination(int requestId) {
    if (_appTerminationRequestId == requestId) {
      _appTerminationRequestId = null;
    }
  }

  set enableSsl(bool enableSsl) {
    configuration.enableSsl = enableSsl;
  }

  /// 启动代理服务
  Future<Server> start() {
    if (appTerminationLocked) {
      return Future<Server>.error(StateError('应用正在安全退出，已拒绝重新启动代理'));
    }
    final generation = ++_lifecycleGeneration;
    _desiredRunning = true;
    return _startForIntent(generation);
  }

  Future<Server> _startForIntent(int generation) {
    if (appTerminationLocked) {
      return Future<Server>.error(StateError('应用正在安全退出，已拒绝重新启动代理'));
    }
    if (!_isCurrentRunningIntent(generation)) {
      return Future<Server>.error(StateError('启动请求已被更新的停止意图取消'));
    }
    final pendingStop = _pendingStop;
    if (pendingStop != null) {
      // Ordinary rapid stop/start is serialized. App termination is checked
      // again after stop completes. The generation check also makes a newer
      // stop win over this queued start.
      return pendingStop.then((_) => _startForIntent(generation));
    }
    if (isRunning) return Future<Server>.value(server!);
    final pending = _pendingStart;
    if (pending != null) return pending;

    final operation = _startInternal();
    _pendingStart = operation;
    operation.then(
      (_) {
        if (identical(_pendingStart, operation)) _pendingStart = null;
      },
      onError: (_, __) {
        if (identical(_pendingStart, operation)) _pendingStart = null;
      },
    );
    return operation;
  }

  Future<Server> _startInternal() async {
    final nextServer = Server(configuration, listener: CombinedEventListener(listeners));
    final desiredPort = configuration.port;
    final recoveryBackup = _isMacOS ? configuration.systemProxyBackup : null;
    final recoveryPort =
        recoveryBackup == null ? desiredPort : (configuration.systemProxyLeaseOwnerPort ?? desiredPort);
    if (recoveryPort < 1 || recoveryPort > 65535) {
      throw StateError('ProxyPin 监听端口无效: $recoveryPort');
    }

    final interceptors = _interceptorFactory();

    interceptors.sort((a, b) => a.priority.compareTo(b.priority));

    nextServer.initChannel((channel) {
      channel.dispatcher.handle(
        HttpRequestCodec(),
        HttpResponseCodec(),
        HttpProxyChannelHandler(listener: CombinedEventListener(listeners), interceptors: interceptors),
      );
    });

    var bound = false;
    try {
      // Bind the immutable lease port before CA work. A previous crashed
      // process may have left live system traffic pointing here; listening
      // early is safer than leaving a dead endpoint during certificate I/O.
      await nextServer.bind(recoveryPort);
      bound = true;
      _boundPort = recoveryPort;
      logger.i("listen on $recoveryPort");
      server = nextServer;

      await _initializeCertificates();
      if (recoveryBackup != null) {
        try {
          _configureRecoveryRuntimeUpstream();
        } catch (error) {
          // The network event path is fail-closed while the lease remains, so
          // a missing upstream cannot silently bypass Surge.
          configuration.runtimeExternalProxy = null;
          logger.e('无法重建第一跳恢复上游，恢复期间将拒绝转发请求', error: error);
        }
      }
      if (recoveryBackup != null) {
        // A persisted lease means a previous process did not complete its
        // restore. Recover first and leave first-hop off for this launch; the
        // user can opt in again after verifying connectivity.
        configuration.firstHopProxyMode = false;
        await setSystemProxyEnable(false);
        if (recoveryPort != desiredPort) {
          await nextServer.stop();
          bound = false;
          _boundPort = null;
          await nextServer.bind(desiredPort);
          bound = true;
          _boundPort = desiredPort;
          logger.i("recovery complete, listen on $desiredPort");
        }
      }
      if (configuration.enableSystemProxy) {
        await setSystemProxyEnable(true);
      }

      _statusController.add(true);
      return nextServer;
    } catch (error, stackTrace) {
      logger.e('启动代理失败，正在回滚', error: error, stackTrace: StackTrace.current);
      Object? restoreError;
      if (configuration.enableSystemProxy || _didMutateSystemProxyThisRun || configuration.systemProxyBackup != null) {
        try {
          await setSystemProxyEnable(false);
        } catch (caught) {
          restoreError = caught;
          logger.e('启动失败后的系统代理恢复也失败', error: caught);
        }
      }
      if (_didMutateSystemProxyThisRun || restoreError != null) {
        // A protocol may still point at 9099. Stopping the listener here would
        // turn a recoverable failure into immediate loss of connectivity.
        systemProxyActivation = const SystemProxyActivationResult(SystemProxyActivationState.recoveryRequired);
        if (bound) {
          server = nextServer;
          _statusController.add(true);
        } else {
          server = null;
          _boundPort = null;
          _statusController.add(false);
        }
        Error.throwWithStackTrace(
          StateError(
            bound
                ? '启动失败：$error；系统代理恢复未完成：$restoreError。ProxyPin 已保持监听，请在设置中重试关闭第一跳。'
                : '启动失败：$error；系统代理恢复未完成：$restoreError，且租约端口无法监听。请立即手动恢复 macOS 系统代理。',
          ),
          stackTrace,
        );
      }
      if (bound) await nextServer.stop();
      server = null;
      _boundPort = null;
      _statusController.add(false);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// 停止代理服务
  Future<Server?> stop() {
    _lifecycleGeneration += 1;
    _desiredRunning = false;
    return _scheduleStop();
  }

  Future<Server?> _scheduleStop() {
    final pendingStop = _pendingStop;
    if (pendingStop != null) return pendingStop;

    final operation = _stopInternal();
    _pendingStop = operation;
    operation.then(
      (_) {
        if (identical(_pendingStop, operation)) _pendingStop = null;
      },
      onError: (_, __) {
        if (identical(_pendingStop, operation)) _pendingStop = null;
      },
    );
    return operation;
  }

  Future<Server?> _stopInternal() async {
    final pending = _pendingStart;
    if (pending != null) {
      try {
        await pending;
      } catch (error) {
        logger.w('等待启动完成后执行安全停止: $error');
      }
    }

    final stoppingServer = server;
    if (stoppingServer == null || !stoppingServer.isRunning) {
      if (_didMutateSystemProxyThisRun || configuration.systemProxyBackup != null) {
        await setSystemProxyEnable(false);
      }
      if (_listenerReady()) {
        await _refuseDeadOwnedListenerWithoutLease();
      }
      return server;
    }

    if (configuration.enableSystemProxy || _didMutateSystemProxyThisRun || configuration.systemProxyBackup != null) {
      await setSystemProxyEnable(false);
    }
    await _refuseDeadOwnedListenerWithoutLease();
    final stoppingPort = port;
    logger.i("stop on $stoppingPort");
    await stoppingServer.stop();
    if (identical(server, stoppingServer)) {
      _boundPort = null;
    }
    _statusController.add(false);
    return server;
  }

  Future<void> _refuseDeadOwnedListenerWithoutLease() async {
    if (!_isMacOS || configuration.systemProxyBackup != null) return;
    final ownerPort = port;
    final configured = await _systemProxyGateway.configuredSnapshot();
    final effective = await _systemProxyGateway.effectiveSnapshot();
    if (!configured.ownsAnyEndpoint(host: '127.0.0.1', port: ownerPort) &&
        !effective.ownsAnyEndpoint(host: '127.0.0.1', port: ownerPort)) {
      return;
    }
    systemProxyActivation = const SystemProxyActivationResult(SystemProxyActivationState.recoveryRequired);
    throw StateError('系统代理仍指向 ProxyPin 127.0.0.1:$ownerPort，但没有可验证的恢复备份；已保持监听，请先手动恢复系统代理');
  }

  /// 设置系统代理
  Future<SystemProxyActivationResult> setSystemProxyEnable(bool enable) async {
    if (enable && _proxyAcquisitionLocked) {
      throw StateError(_proxyAcquisitionLockMessage('接管系统代理'));
    }
    return _serializeSystemProxyTransition(() => _setSystemProxyEnable(enable));
  }

  /// Switches between passive coexistence and the explicit Proxyman-style
  /// first-hop route. The preference is safe by default and never starts or
  /// modifies Surge itself.
  Future<SystemProxyActivationResult> setFirstHopProxyMode(bool enable) {
    if (enable && _proxyAcquisitionLocked) {
      return Future<SystemProxyActivationResult>.error(StateError(_proxyAcquisitionLockMessage('启用第一跳')));
    }
    return _serializeSystemProxyTransition(() => _setFirstHopProxyMode(enable));
  }

  bool get _proxyAcquisitionLocked => appTerminationLocked || _pendingStop != null;

  bool _isCurrentRunningIntent(int generation) =>
      !appTerminationLocked && _desiredRunning && _lifecycleGeneration == generation;

  String _proxyAcquisitionLockMessage(String action) =>
      appTerminationLocked ? '应用正在安全退出，已拒绝$action' : '代理服务正在停止，已拒绝$action';

  Future<T> _serializeSystemProxyTransition<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _systemProxyTransition = _systemProxyTransition.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<SystemProxyActivationResult> _setFirstHopProxyMode(bool enable) async {
    if (enable && _proxyAcquisitionLocked) {
      throw StateError(_proxyAcquisitionLockMessage('启用第一跳'));
    }
    final previous = configuration.firstHopProxyMode;
    if (!enable &&
        systemProxyActivation.state == SystemProxyActivationState.recoveryRequired &&
        configuration.systemProxyBackup == null) {
      // With no backup we can only verify that the user/new owner has already
      // moved both configured and effective routing away from the live
      // listener. Never pretend the recovery lock was cleared otherwise.
      await _refuseDeadOwnedListenerWithoutLease();
      configuration.runtimeExternalProxy = null;
      configuration.effectiveSystemProxyBackup = null;
      configuration.firstHopProxyMode = false;
      systemProxyActivation = const SystemProxyActivationResult(SystemProxyActivationState.disabled);
      await _persistConfiguration();
      return systemProxyActivation;
    }
    if (previous == enable && !(enable == false && configuration.systemProxyBackup != null)) {
      return systemProxyActivation;
    }

    if (enable && !configuration.chainSystemProxy) {
      throw StateError('请先开启“将当前代理作为唯一上游”，避免第一跳绕过 Surge 直连');
    }

    if (!enable) {
      // Persist the disabled mode in the same write that clears the recovery
      // lease. This avoids a disk state that says first-hop is enabled while
      // the operating-system proxy has already been restored.
      configuration.firstHopProxyMode = false;
      try {
        if (_didMutateSystemProxyThisRun || configuration.systemProxyBackup != null) {
          await _setSystemProxyEnable(false);
        } else {
          await _persistConfiguration();
        }
      } catch (error, stackTrace) {
        if (_didMutateSystemProxyThisRun || configuration.systemProxyBackup != null) {
          configuration.firstHopProxyMode = true;
          try {
            await _persistConfiguration();
          } catch (persistError) {
            logger.w('保存第一跳恢复状态失败: $persistError');
          }
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
      if (configuration.enableSystemProxy && _listenerReady()) {
        return _setSystemProxyEnable(true);
      }
      return systemProxyActivation = const SystemProxyActivationResult(SystemProxyActivationState.disabled);
    }

    configuration.firstHopProxyMode = true;
    try {
      await _persistConfiguration();
      if (!configuration.enableSystemProxy || !_listenerReady()) {
        // Store the preference only. start() will activate it after the
        // listener and CA are ready, so no traffic can be sent to a dead port.
        return systemProxyActivation = const SystemProxyActivationResult(SystemProxyActivationState.disabled);
      }
      return await _setSystemProxyEnable(true);
    } catch (error, stackTrace) {
      if (_didMutateSystemProxyThisRun) {
        // Rollback failed and at least one protocol may still depend on 9099.
        // Keep the mode visible/persisted so restart and UI cannot mistake it
        // for passive coexistence and discard the recovery lease.
        configuration.firstHopProxyMode = true;
        try {
          await _persistConfiguration();
        } catch (persistError) {
          logger.w('保存第一跳恢复状态失败: $persistError');
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
      configuration.firstHopProxyMode = previous;
      try {
        await _persistConfiguration();
        if (configuration.enableSystemProxy && _listenerReady()) {
          await _setSystemProxyEnable(true);
        }
      } catch (passiveError) {
        logger.w('第一跳失败后恢复安全共存状态失败: $passiveError');
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<SystemProxyActivationResult> _setSystemProxyEnable(bool enable) async {
    if (enable && _proxyAcquisitionLocked) {
      throw StateError(_proxyAcquisitionLockMessage('接管系统代理'));
    }
    if (!_isDesktop) {
      return systemProxyActivation = const SystemProxyActivationResult(SystemProxyActivationState.disabled);
    }

    if (enable) {
      if (port < 1 || port > 65535) {
        throw StateError('ProxyPin 监听端口无效: $port');
      }
      if (_isMacOS && !_didMutateSystemProxyThisRun && configuration.systemProxyBackup != null) {
        await _recoverPersistedSystemProxyLease();
      }
      if (_isMacOS && configuration.firstHopProxyMode && !configuration.chainSystemProxy) {
        throw StateError('第一跳模式必须启用可验证的单一 HTTP 上游；本次未修改系统代理');
      }
      if (_isMacOS && configuration.firstHopProxyMode && !_listenerReady()) {
        configuration.runtimeExternalProxy = null;
        await _persistConfiguration();
        return systemProxyActivation = const SystemProxyActivationResult(SystemProxyActivationState.disabled);
      }

      final configuredBefore = await _systemProxyGateway.configuredSnapshot();
      final effectiveBefore = await _systemProxyGateway.effectiveSnapshot();
      final configuredAlreadyOwned = configuredBefore.isOwnedBy(host: '127.0.0.1', port: port);

      // Safe coexistence and upstream chaining are separate choices. Passive
      // mode only observes the current route and never changes macOS settings.
      final passiveCoexistence = _isMacOS && !configuration.firstHopProxyMode;
      if (passiveCoexistence) {
        try {
          await _prepareRuntimeUpstream(
            effectiveBefore,
            configuredBefore: configuredBefore,
            requireUpstream: false,
          );
        } catch (error) {
          configuration.runtimeExternalProxy = null;
          logger.w('当前有效代理无法安全合并为单一上游；ProxyPin 保持监听且不修改系统代理: $error');
        }
        await _persistConfiguration();

        final effectiveOwned = effectiveBefore.isOwnedBy(host: '127.0.0.1', port: port);
        final unleasedOwnership = configuration.systemProxyBackup == null &&
            !_didMutateSystemProxyThisRun &&
            (configuredAlreadyOwned || effectiveOwned);
        final overridingProxy = effectiveBefore.http ?? effectiveBefore.https;
        if (unleasedOwnership) {
          logger.w('macOS 仍指向当前 ProxyPin 监听端口，但没有可验证的恢复备份；已锁定路由设置并保持监听');
          return systemProxyActivation =
              SystemProxyActivationResult(SystemProxyActivationState.recoveryRequired, effectiveProxy: overridingProxy);
        }
        if (effectiveOwned) {
          logger.i('macOS 安全共存模式：当前路由已指向 ProxyPin，本次未改写系统代理');
        } else {
          logger.w(
            'macOS 安全共存模式'
            '${overridingProxy == null ? '' : '，检测到现有代理 ${overridingProxy.host}:${overridingProxy.port}'}；'
            'ProxyPin 不修改 Surge/VPN 或系统代理，仅捕获显式发送到 127.0.0.1:$port 的请求',
          );
        }
        return systemProxyActivation = SystemProxyActivationResult(
          effectiveOwned ? SystemProxyActivationState.owned : SystemProxyActivationState.overridden,
          effectiveProxy: overridingProxy,
        );
      }

      if (_isMacOS && configuration.firstHopProxyMode && effectiveBefore.autoConfigEnabled) {
        throw StateError('当前由 PAC 自动代理接管，无法安全建立 ProxyPin 第一跳；本次未修改系统代理');
      }
      if (_isMacOS && configuration.firstHopProxyMode && configuredBefore.networkService == null) {
        throw StateError('无法固定当前 macOS 网络服务；本次未修改系统代理');
      }

      final previousSystemBackup = configuration.systemProxyBackup;
      final previousEffectiveBackup = configuration.effectiveSystemProxyBackup;
      final previousRuntimeUpstream = configuration.runtimeExternalProxy;
      final previousLeaseOwnerHost = configuration.systemProxyLeaseOwnerHost;
      final previousLeaseOwnerPort = configuration.systemProxyLeaseOwnerPort;
      final previousLeaseBypassDomains = configuration.systemProxyLeaseBypassDomains;
      var takeoverAttempted = false;
      var leasePersisted = false;

      try {
        if (!configuredAlreadyOwned) {
          configuration.systemProxyBackup = configuredBefore;
          configuration.systemProxyLeaseOwnerHost = '127.0.0.1';
          configuration.systemProxyLeaseOwnerPort = port;
          // First-hop preserves the current owner's bypass list. Only HTTP
          // and HTTPS endpoints are leased.
          configuration.systemProxyLeaseBypassDomains = configuredBefore.bypassDomains ?? '';
        } else if (configuration.systemProxyBackup == null) {
          throw StateError('系统已指向 ProxyPin，但缺少可验证的原代理备份；为避免断网，本次拒绝接管');
        } else if (_isMacOS &&
            (configuration.systemProxyBackup!.networkService == null ||
                configuration.systemProxyBackup!.networkService != configuredBefore.networkService)) {
          throw StateError('系统代理备份不属于当前网络服务；为避免把旧配置写入新网络，本次拒绝接管');
        }

        await _prepareRuntimeUpstream(
          effectiveBefore,
          configuredBefore: configuredBefore,
          requireUpstream: _isMacOS && configuration.firstHopProxyMode,
        );
        // Persist a recovery lease before the first system write.
        await _persistConfiguration();
        leasePersisted = true;

        final latestConfigured =
            await _systemProxyGateway.configuredSnapshot(networkService: configuredBefore.networkService);
        if (!latestConfigured.hasSameRouting(configuredBefore)) {
          throw StateError('上游在接管前发生变化；已取消第一跳且未修改系统代理，请确认 Surge 稳定后重试');
        }
        final latestEffective = await _systemProxyGateway.effectiveSnapshot();
        if (!latestEffective.hasSameRouting(effectiveBefore)) {
          throw StateError('实际生效代理在接管前发生变化；已取消第一跳且未修改系统代理，请确认 Surge 稳定后重试');
        }
        final frozenUpstream = configuration.runtimeExternalProxy;
        if (frozenUpstream == null || !await _upstreamReachabilityProbe(frozenUpstream)) {
          throw StateError('冻结的一跳上游在接管前已不可达；已取消且未修改系统代理');
        }

        takeoverAttempted = true;
        _didMutateSystemProxyThisRun = true;
        try {
          await _systemProxyGateway.takeOwnership(
            port: port,
            passDomains: configuration.proxyPassDomains,
            networkService: configuredBefore.networkService,
            expected: configuredBefore,
          );
        } on SystemProxyTransactionException catch (error, stackTrace) {
          if (!error.mayHaveChanged) {
            takeoverAttempted = false;
            _didMutateSystemProxyThisRun = false;
          }
          Error.throwWithStackTrace(error, stackTrace);
        }

        final configuredAfter =
            await _systemProxyGateway.configuredSnapshot(networkService: configuredBefore.networkService);
        if (!configuredAfter.isOwnedBy(host: '127.0.0.1', port: port)) {
          throw StateError('系统代理未成功切换到 ProxyPin 127.0.0.1:$port');
        }

        final effectiveAfter = await _waitForStableEffectiveOwnership(
          networkService: configuredBefore.networkService,
          ownerHost: '127.0.0.1',
          ownerPort: port,
        );
        if (effectiveAfter.isOwnedBy(host: '127.0.0.1', port: port)) {
          if (!await _upstreamReachabilityProbe(frozenUpstream)) {
            throw StateError('第一跳接管后上游 ${frozenUpstream.host}:${frozenUpstream.port} 已不可达；正在恢复原系统代理');
          }
          logger.i(
            '第一跳已建立：ProxyPin 127.0.0.1:$port'
            '${configuration.effectiveExternalProxy == null ? '' : ' → ${configuration.effectiveExternalProxy!.host}:${configuration.effectiveExternalProxy!.port}'}',
          );
          return systemProxyActivation = const SystemProxyActivationResult(SystemProxyActivationState.owned);
        }

        final overridingProxy = effectiveAfter.http ?? effectiveAfter.https;
        if (_isMacOS && configuration.firstHopProxyMode) {
          throw StateError(
            '第一跳未生效，macOS 当前仍由'
            '${overridingProxy == null ? '其他网络服务' : ' ${overridingProxy.host}:${overridingProxy.port}'} 接管；'
            '已停止争抢并准备恢复原代理',
          );
        }
        return systemProxyActivation = SystemProxyActivationResult(
          SystemProxyActivationState.overridden,
          effectiveProxy: overridingProxy,
        );
      } catch (error, stackTrace) {
        Object? rollbackError;
        if (takeoverAttempted) {
          try {
            final rollbackTarget = configuration.systemProxyBackup;
            if (rollbackTarget == null) {
              throw StateError('缺少原系统代理备份，无法自动恢复');
            }
            // Always run the selective restore: a newer owner may have
            // replaced both endpoints while ProxyPin's bypass value remains.
            await _restoreAndVerify(rollbackTarget);
            _didMutateSystemProxyThisRun = false;
          } catch (restoreError) {
            rollbackError = restoreError;
            // Keep the listener, ownership flag and persisted recovery lease so
            // a later stop/retry can restore instead of abandoning 9099.
            _didMutateSystemProxyThisRun = true;
            systemProxyActivation = const SystemProxyActivationResult(SystemProxyActivationState.recoveryRequired);
          }
        }

        if (rollbackError == null) {
          configuration.systemProxyBackup = previousSystemBackup;
          configuration.effectiveSystemProxyBackup = previousEffectiveBackup;
          configuration.runtimeExternalProxy = previousRuntimeUpstream;
          configuration.systemProxyLeaseOwnerHost = previousLeaseOwnerHost;
          configuration.systemProxyLeaseOwnerPort = previousLeaseOwnerPort;
          configuration.systemProxyLeaseBypassDomains = previousLeaseBypassDomains;
        }
        if (leasePersisted || takeoverAttempted) {
          try {
            await _persistConfiguration();
          } catch (persistError) {
            rollbackError ??= persistError;
          }
        }

        if (rollbackError != null) {
          throw StateError('第一跳启用失败：$error；自动恢复也失败：$rollbackError。ProxyPin 继续监听，请勿退出后再重试关闭。');
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
    }

    if (!_didMutateSystemProxyThisRun) {
      final persistedBackup = configuration.systemProxyBackup;
      if (persistedBackup != null) {
        // Even if a newer owner replaced both endpoints, the bypass list may
        // still be the value written by ProxyPin. Keep the lease until the
        // selective compare-and-swap restore has inspected all three fields.
        _didMutateSystemProxyThisRun = true;
      }
      if (!_didMutateSystemProxyThisRun) {
        // This process never changed the system proxy and no persisted lease
        // still owns an endpoint. Passive coexistence must not infer ownership
        // from an unrelated 9099 configuration.
        if (_listenerReady()) {
          await _refuseDeadOwnedListenerWithoutLease();
        }
        configuration.runtimeExternalProxy = null;
        configuration.effectiveSystemProxyBackup = null;
        await _persistConfiguration();
        return systemProxyActivation = const SystemProxyActivationResult(SystemProxyActivationState.disabled);
      }
    }

    final previous = configuration.systemProxyBackup;
    if (previous == null) {
      throw StateError('系统代理可能仍指向 ProxyPin，但缺少原代理备份；保持监听以避免断网');
    }
    final current = await _systemProxyGateway.configuredSnapshot(networkService: previous.networkService);
    final ownership = current.ownershipBy(host: _leasedOwnerHost, port: _leasedOwnerPort);

    if (ownership == SystemProxyOwnership.none && !current.hasSameRouting(previous)) {
      // Surge/VPN/user changed the proxy after ProxyPin started. Never
      // overwrite those newer endpoints during shutdown. The restore gateway
      // still performs a separate compare-and-swap for ProxyPin's bypass list.
      logger.w('系统代理已由其他程序接管，仅检查并恢复 ProxyPin 写入的绕过列表');
    }
    try {
      await _restoreAndVerify(previous);
    } catch (_) {
      systemProxyActivation = const SystemProxyActivationResult(SystemProxyActivationState.recoveryRequired);
      rethrow;
    }

    configuration.runtimeExternalProxy = null;
    configuration.effectiveSystemProxyBackup = null;
    _clearSystemProxyLease();
    _didMutateSystemProxyThisRun = false;
    await _persistConfiguration();
    return systemProxyActivation = const SystemProxyActivationResult(SystemProxyActivationState.disabled);
  }

  static const _systemProxyConvergenceDelays = <Duration>[
    Duration.zero,
    Duration(milliseconds: 100),
    Duration(milliseconds: 150),
    Duration(milliseconds: 200),
    Duration(milliseconds: 300),
    Duration(milliseconds: 400),
    Duration(milliseconds: 500),
  ];

  /// Applying a committed SystemConfiguration change is asynchronous from
  /// the Dynamic Store observed by `scutil --proxy`. Wait only during this
  /// explicit takeover, never retry the write, and require two stable samples
  /// so a competing owner cannot create a transient false success.
  Future<SystemProxySnapshot> _waitForStableEffectiveOwnership({
    required String? networkService,
    required String ownerHost,
    required int ownerPort,
  }) async {
    var stableSamples = 0;
    SystemProxySnapshot? latestEffective;

    for (final delay in _systemProxyConvergenceDelays) {
      if (delay > Duration.zero) await _systemProxyPropagationDelay(delay);

      final configured = await _systemProxyGateway.configuredSnapshot(networkService: networkService);
      if (!configured.isOwnedBy(host: ownerHost, port: ownerPort)) {
        final newerOwner = configured.http ?? configured.https;
        throw StateError(
          '第一跳等待生效期间，系统代理已由'
          '${newerOwner == null ? '其他程序' : ' ${newerOwner.host}:${newerOwner.port}'} 接管；'
          '已停止等待并准备恢复原代理',
        );
      }

      latestEffective = await _systemProxyGateway.effectiveSnapshot();
      if (latestEffective.isOwnedBy(host: ownerHost, port: ownerPort)) {
        stableSamples += 1;
        if (stableSamples >= 2) return latestEffective;
      } else {
        stableSamples = 0;
      }
    }

    return latestEffective ?? await _systemProxyGateway.effectiveSnapshot();
  }

  Future<void> _restoreAndVerify(SystemProxySnapshot snapshot) async {
    await _systemProxyGateway.restoreOwnedEndpoints(
      backup: snapshot,
      ownerHost: _leasedOwnerHost,
      ownerPort: _leasedOwnerPort,
      expectedBypassDomains: _leasedBypassDomains,
    );
    final restored = await _systemProxyGateway.configuredSnapshot(networkService: snapshot.networkService);
    if (restored.ownsAnyEndpoint(host: _leasedOwnerHost, port: _leasedOwnerPort)) {
      throw StateError('系统代理恢复校验失败；已保留备份，避免继续覆盖网络设置');
    }
    if (_leasedBypassDomains != snapshot.bypassDomains && restored.bypassDomains == _leasedBypassDomains) {
      throw StateError('系统代理绕过列表恢复校验失败；已保留备份以便重试');
    }
    final effective = await _systemProxyGateway.effectiveSnapshot();
    if (effective.ownsAnyEndpoint(host: _leasedOwnerHost, port: _leasedOwnerPort)) {
      throw StateError('macOS 实际生效代理仍指向 ProxyPin；已保留监听与恢复租约，稍后可安全重试');
    }
  }

  String get _leasedOwnerHost => configuration.systemProxyLeaseOwnerHost ?? '127.0.0.1';

  int get _leasedOwnerPort => configuration.systemProxyLeaseOwnerPort ?? port;

  String get _leasedBypassDomains => configuration.systemProxyLeaseBypassDomains ?? configuration.proxyPassDomains;

  void _clearSystemProxyLease() {
    configuration.systemProxyBackup = null;
    configuration.systemProxyLeaseOwnerHost = null;
    configuration.systemProxyLeaseOwnerPort = null;
    configuration.systemProxyLeaseBypassDomains = null;
  }

  /// Recover an ownership lease left by an interrupted previous run before
  /// taking over the currently active service. The lease always names the
  /// exact service that was originally changed.
  Future<void> _recoverPersistedSystemProxyLease() async {
    final backup = configuration.systemProxyBackup;
    if (backup == null) return;

    _didMutateSystemProxyThisRun = true;
    try {
      await _restoreAndVerify(backup);
    } catch (_) {
      systemProxyActivation = const SystemProxyActivationResult(SystemProxyActivationState.recoveryRequired);
      rethrow;
    }

    _didMutateSystemProxyThisRun = false;
    configuration.effectiveSystemProxyBackup = null;
    configuration.runtimeExternalProxy = null;
    _clearSystemProxyLease();
    await _persistConfiguration();
  }

  /// Re-evaluate the automatic upstream without reading system settings.
  /// Called by the UI when the preference changes; existing connections are
  /// allowed to finish and new connections use the updated single-hop route.
  void refreshRuntimeUpstream() {
    if (systemProxyRoutingLocked) {
      logger.w('第一跳运行中禁止直接切换上游；请先关闭第一跳并恢复系统代理');
      return;
    }
    _configureRuntimeUpstream(configuration.effectiveSystemProxyBackup);
  }

  Future<void> _prepareRuntimeUpstream(
    SystemProxySnapshot effectiveBefore, {
    required SystemProxySnapshot configuredBefore,
    required bool requireUpstream,
  }) async {
    configuration.runtimeExternalProxy = null;

    final manual = configuration.externalProxy?.enabled == true ? configuration.externalProxy : null;
    if (manual != null) {
      await _validateUpstreamForActivation(manual);
      if (requireUpstream && !await _upstreamReachabilityProbe(manual)) {
        throw StateError('手动上游 ${manual.host}:${manual.port} 当前不可达；本次未修改系统代理');
      }
      configuration.runtimeExternalProxy = manual.copy()..enabled = true;
      return;
    }
    if (!configuration.chainSystemProxy) {
      if (requireUpstream) throw StateError('第一跳模式要求启用一个可验证的 HTTP 上游');
      return;
    }

    SystemProxySnapshot? source;
    var shouldPersistSource = false;
    if (effectiveBefore.isOwnedBy(host: '127.0.0.1', port: port) || !effectiveBefore.hasEnabledProxy) {
      source = configuration.effectiveSystemProxyBackup;
      if (source == null &&
          configuredBefore.hasEnabledProxy &&
          !configuredBefore.isOwnedBy(host: '127.0.0.1', port: port)) {
        source = configuredBefore;
        shouldPersistSource = true;
      }
    } else {
      source = effectiveBefore;
      shouldPersistSource = true;
    }
    if (source == null) {
      if (requireUpstream) throw StateError('未检测到可作为第一跳上游的现有 HTTP/HTTPS 代理');
      return;
    }

    final automatic = source.compatibleUpstream(localPort: port);
    if (automatic == null) {
      if (requireUpstream) throw StateError('检测到的上游指向 ProxyPin 自身，已阻止代理循环');
      return;
    }
    await _validateUpstreamForActivation(automatic);
    if (!await _upstreamReachabilityProbe(automatic)) {
      configuration.effectiveSystemProxyBackup = null;
      if (requireUpstream) {
        throw StateError('现有上游 ${automatic.host}:${automatic.port} 当前不可达；本次未修改系统代理');
      }
      logger.w('自动上游 ${automatic.host}:${automatic.port} 当前不可达，已跳过以避免本机断网');
      return;
    }

    if (shouldPersistSource) configuration.effectiveSystemProxyBackup = source;
    configuration.runtimeExternalProxy = automatic;
    logger.i('使用接管前的实际有效代理作为单一上游 ${automatic.host}:${automatic.port}');
  }

  void _configureRuntimeUpstream(SystemProxySnapshot? previous) {
    configuration.runtimeExternalProxy = null;

    final manual = configuration.externalProxy?.enabled == true ? configuration.externalProxy : null;
    if (manual != null) {
      _validateUpstream(manual);
      configuration.runtimeExternalProxy = manual.copy()..enabled = true;
      return;
    }

    if (!configuration.chainSystemProxy || previous == null) return;
    final automatic = previous.compatibleUpstream(localPort: port);
    if (automatic == null) return;
    _validateUpstream(automatic);
    configuration.runtimeExternalProxy = automatic;
    logger.i('使用接管前的系统代理作为单一上游 ${automatic.host}:${automatic.port}');
  }

  void _configureRecoveryRuntimeUpstream() {
    configuration.runtimeExternalProxy = null;
    final manual = configuration.externalProxy?.enabled == true ? configuration.externalProxy : null;
    if (manual != null) {
      _validateUpstream(manual);
      configuration.runtimeExternalProxy = manual.copy()..enabled = true;
      return;
    }

    final previous = configuration.effectiveSystemProxyBackup ?? configuration.systemProxyBackup;
    if (previous == null) throw StateError('恢复租约缺少原上游快照');
    final upstream = previous.compatibleUpstream(localPort: _leasedOwnerPort);
    if (upstream == null) throw StateError('恢复租约的上游指向 ProxyPin 自身');
    _validateUpstream(upstream);
    configuration.runtimeExternalProxy = upstream;
  }

  Future<bool> _isAutomaticUpstreamReachable(ProxyInfo upstream) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        upstream.host,
        upstream.port!,
        timeout: const Duration(milliseconds: 700),
      );
      final authorization = upstream.isAuthenticated
          ? 'Proxy-Authorization: Basic ${base64Encode(utf8.encode('${upstream.username}:${upstream.password ?? ''}'))}\r\n'
          : '';
      socket.write(
        'CONNECT example.com:443 HTTP/1.1\r\n'
        'Host: example.com:443\r\n'
        'Proxy-Connection: close\r\n'
        '$authorization'
        '\r\n',
      );
      await socket.flush();
      final statusLine = await utf8.decoder
          .bind(socket)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(milliseconds: 900));
      final match = RegExp(r'^HTTP/\d(?:\.\d)?\s+(\d{3})').firstMatch(statusLine);
      final statusCode = int.tryParse(match?.group(1) ?? '');
      return statusCode != null && statusCode >= 200 && statusCode < 300;
    } catch (_) {
      return false;
    } finally {
      socket?.destroy();
    }
  }

  Future<void> _validateUpstreamForActivation(ProxyInfo upstream) async {
    _validateUpstream(upstream);
    if (upstream.port != port) return;

    try {
      final resolved = await InternetAddress.lookup(upstream.host).timeout(const Duration(milliseconds: 350));
      final interfaces = await NetworkInterface.list().timeout(const Duration(milliseconds: 350));
      final localAddresses = <String>{
        InternetAddress.loopbackIPv4.address,
        InternetAddress.loopbackIPv6.address,
        for (final interface in interfaces) ...interface.addresses.map((address) => address.address),
      };
      if (resolved.any((address) => localAddresses.contains(address.address))) {
        throw StateError('上游代理解析到本机 ProxyPin 端口 $port，已阻止代理循环');
      }
    } on StateError {
      rethrow;
    } catch (error) {
      throw StateError('无法安全验证上游 ${upstream.host}:$port 是否指向本机：$error');
    }
  }

  void _validateUpstream(ProxyInfo upstream) {
    if (upstream.host.trim().isEmpty || upstream.port == null || upstream.port! <= 0 || upstream.port! > 65535) {
      throw StateError('上游代理地址无效');
    }
    if (upstream.pointsToLocalPort(port)) {
      throw StateError('上游代理不能指向 ProxyPin 自身端口 $port');
    }
  }

  /// 重启代理服务
  Future<void> restart() async {
    if (appTerminationLocked) return;
    final generation = ++_lifecycleGeneration;
    _desiredRunning = true;
    await _restartForIntent(generation);
  }

  Future<void> _restartForIntent(int generation) async {
    if (!_isCurrentRunningIntent(generation)) return;
    await _scheduleStop();
    if (!_isCurrentRunningIntent(generation)) return;
    await _startForIntent(generation);
  }

  ///检查是否监听端口 没有监听则启动
  Future<void> retryBind() async {
    final generation = _lifecycleGeneration;
    if (!_isCurrentRunningIntent(generation) || isStopping) return;
    try {
      await Socket.connect('127.0.0.1', port, timeout: const Duration(milliseconds: 350));
    } catch (e) {
      if (!_isCurrentRunningIntent(generation) || isStopping) return;
      logger.d('端口未被占用，尝试重新绑定 $port');
      await _restartForIntent(generation);
    }
  }

  ///添加监听器
  void addListener(EventListener listener) {
    listeners.add(listener);
  }

  /// 释放资源，关闭状态广播流控制器，防止内存泄漏
  void dispose() {
    _statusController.close();
  }
}
