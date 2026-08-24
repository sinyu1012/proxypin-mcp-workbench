import 'package:proxypin/network/channel/host_port.dart';

enum SystemProxyOwnership { none, partial, full }

/// HTTP/HTTPS system proxy state captured before ProxyPin takes ownership.
///
/// SOCKS is intentionally not represented: ProxyPin no longer changes the
/// system SOCKS proxy, which avoids interfering with Surge/VPN configurations.
class SystemProxySnapshot {
  final ProxyInfo? http;
  final ProxyInfo? https;
  final String? bypassDomains;
  final bool autoConfigEnabled;
  final String? networkService;

  const SystemProxySnapshot({
    this.http,
    this.https,
    this.bypassDomains,
    this.autoConfigEnabled = false,
    this.networkService,
  });

  factory SystemProxySnapshot.fromJson(Map<String, dynamic> json) {
    return SystemProxySnapshot(
      http: _proxyFromJson(json['http']),
      https: _proxyFromJson(json['https']),
      bypassDomains: json['bypassDomains'] as String?,
      autoConfigEnabled: json['autoConfigEnabled'] == true,
      networkService: json['networkService'] as String?,
    );
  }

  /// Parse only the top-level values reported by macOS `scutil --proxy`.
  ///
  /// Per-interface values under `__SCOPED__` and other nested dictionaries do
  /// not describe the globally effective proxy and are intentionally ignored.
  factory SystemProxySnapshot.fromScutilProxyOutput(String output) {
    final values = _topLevelScutilValues(output);
    final autoConfigEnabled = _enabledValue(
      values,
      key: 'ProxyAutoConfigEnable',
      allowMissing: true,
    );
    return SystemProxySnapshot(
      http: _effectiveProxy(values, prefix: 'HTTP'),
      https: _effectiveProxy(values, prefix: 'HTTPS'),
      autoConfigEnabled: autoConfigEnabled,
    );
  }

  bool get hasEnabledProxy => autoConfigEnabled || http != null || https != null;

  /// Returns the single upstream represented by the snapshot.
  ///
  /// Automatic chaining is deliberately conservative. If HTTP and HTTPS point
  /// to different proxies, ProxyPin refuses to collapse them into one upstream
  /// because that would silently change routing semantics.
  ProxyInfo? compatibleUpstream({required int localPort}) {
    if (autoConfigEnabled) {
      throw StateError('系统启用了 PAC 自动代理配置，无法安全合并为单一上游');
    }
    final endpoints = [http, https].whereType<ProxyInfo>().toList(growable: false);
    if (endpoints.isEmpty) return null;
    if (http == null || https == null) {
      throw StateError('HTTP 与 HTTPS 系统代理未同时启用，无法安全合并为单一上游');
    }
    final first = endpoints.first;
    if (endpoints.any((endpoint) => !endpoint.hasSameEndpoint(first))) {
      throw StateError('HTTP 与 HTTPS 系统代理不一致，无法安全合并为单一上游');
    }
    if (first.pointsToLocalPort(localPort)) return null;
    return first.copy()..enabled = true;
  }

  bool isOwnedBy({required String host, required int port}) {
    return ownershipBy(host: host, port: port) == SystemProxyOwnership.full;
  }

  /// Ownership is evaluated per protocol so recovery remains safe if a crash,
  /// an older ProxyPin build, or another network-settings owner leaves only
  /// one endpoint pointing at this listener.
  SystemProxyOwnership ownershipBy({required String host, required int port}) {
    if (autoConfigEnabled) return SystemProxyOwnership.none;
    final owner = ProxyInfo.of(host, port);
    final ownsHttp = http?.hasSameEndpoint(owner) == true;
    final ownsHttps = https?.hasSameEndpoint(owner) == true;
    if (ownsHttp && ownsHttps) return SystemProxyOwnership.full;
    if (ownsHttp || ownsHttps) return SystemProxyOwnership.partial;
    return SystemProxyOwnership.none;
  }

  bool ownsAnyEndpoint({required String host, required int port}) {
    return ownershipBy(host: host, port: port) != SystemProxyOwnership.none;
  }

  bool hasSameRouting(SystemProxySnapshot other) {
    return hasSameEndpoints(other) &&
        bypassDomains == other.bypassDomains &&
        autoConfigEnabled == other.autoConfigEnabled &&
        networkService == other.networkService;
  }

  bool hasSameEndpoints(SystemProxySnapshot other) {
    return _sameOptionalEndpoint(http, other.http) && _sameOptionalEndpoint(https, other.https);
  }

  Map<String, dynamic> toJson() => {
        'http': http?.toJson(),
        'https': https?.toJson(),
        'bypassDomains': bypassDomains,
        'autoConfigEnabled': autoConfigEnabled,
        'networkService': networkService,
      };

  static Map<String, String> _topLevelScutilValues(String output) {
    final values = <String, String>{};
    var depth = 0;
    var foundRoot = false;

    for (final line in output.split(RegExp(r'[\r\n]+'))) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      final depthBeforeLine = depth;
      final opens = RegExp(r'<(?:dictionary|array)>\s*\{$').hasMatch(trimmed) ? 1 : 0;
      final closes = trimmed == '}' ? 1 : 0;

      if (!foundRoot) {
        if (opens > 0) foundRoot = true;
      } else if (depthBeforeLine == 1) {
        final separator = trimmed.indexOf(':');
        if (separator > 0) {
          final key = trimmed.substring(0, separator).trim();
          final value = trimmed.substring(separator + 1).trim();
          if (value.isNotEmpty && !value.startsWith('<dictionary>') && !value.startsWith('<array>')) {
            values[key] = value;
          }
        }
      }

      depth += opens - closes;
      if (depth < 0) {
        throw StateError('无法解析 macOS 有效系统代理：scutil 输出结构无效');
      }
    }

    if (!foundRoot || depth != 0) {
      throw StateError('无法解析 macOS 有效系统代理：scutil 输出结构不完整');
    }
    return values;
  }

  static ProxyInfo? _effectiveProxy(Map<String, String> values, {required String prefix}) {
    final enableKey = '${prefix}Enable';
    final hostKey = '${prefix}Proxy';
    final portKey = '${prefix}Port';
    final enabled = _enabledValue(
      values,
      key: enableKey,
      allowMissing: !values.containsKey(hostKey) && !values.containsKey(portKey),
    );
    if (!enabled) return null;

    final host = values[hostKey]?.trim();
    final portText = values[portKey]?.trim();
    if (host == null || host.isEmpty || portText == null || portText.isEmpty) {
      throw StateError('$prefix 系统代理已启用，但地址或端口缺失');
    }

    final port = int.tryParse(portText);
    if (port == null || port < 1 || port > 65535) {
      throw StateError('$prefix 系统代理端口无效: $portText');
    }
    return ProxyInfo.of(host, port);
  }

  static bool _enabledValue(
    Map<String, String> values, {
    required String key,
    required bool allowMissing,
  }) {
    final value = values[key];
    if (value == null) {
      if (allowMissing) return false;
      throw StateError('macOS 系统代理状态不完整：缺少 $key');
    }
    if (value == '0') return false;
    if (value == '1') return true;
    throw StateError('macOS 系统代理状态无效：$key = $value');
  }

  static ProxyInfo? _proxyFromJson(dynamic value) {
    if (value is! Map) return null;
    return ProxyInfo.fromJson(Map<String, dynamic>.from(value));
  }

  static bool _sameOptionalEndpoint(ProxyInfo? left, ProxyInfo? right) {
    if (left == null || right == null) return left == null && right == null;
    return left.hasSameEndpoint(right);
  }
}
