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

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:proxypin/network/channel/host_port.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/network/util/system_proxy_snapshot.dart';
import 'package:proxypin/utils/ip.dart';
import 'package:proxypin/utils/lang.dart';
import 'package:proxy_manager/proxy_manager.dart';

class SystemProxyTransactionException implements Exception {
  final String message;
  final String code;
  final bool mayHaveChanged;

  const SystemProxyTransactionException({
    required this.message,
    required this.code,
    required this.mayHaveChanged,
  });

  @override
  String toString() => message;
}

/// @author wanghongen
/// 2023/7/26
class SystemProxy {
  static SystemProxy? _instance;

  ///单例
  static SystemProxy get instance {
    if (_instance == null) {
      if (Platform.isMacOS) {
        _instance = MacSystemProxy();
      } else if (Platform.isWindows) {
        _instance = WindowsSystemProxy();
      } else if (Platform.isLinux) {
        _instance = LinuxSystemProxy();
      } else {
        _instance = SystemProxy();
      }
    }
    return _instance!;
  }

  ///获取代理忽略地址
  static String get proxyPassDomains {
    if (Platform.isMacOS) {
      return '192.168.0.0/16;10.0.0.0/8;172.16.0.0/12;127.0.0.1;localhost;*.local;timestamp.apple.com';
    }
    if (Platform.isWindows) {
      return '192.168.0.*;10.0.0.*;172.16.0.*;127.0.0.1;localhost;*.local;<local>';
    }

    if (Platform.isAndroid) {
      return '192.168.0.0/16;10.0.0.0/8;172.16.0.0/12;127.0.0.1;localhost';
    }
    if (Platform.isIOS) {
      return '192.168.0.0/16;10.0.0.0/8;172.16.0.0/12;127.0.0.1;localhost;*.local;timestamp.apple.com';
    }

    return '';
  }

  ///获取系统代理
  static Future<ProxyInfo?> getSystemProxy(ProxyTypes types) async {
    return instance._getSystemProxy(types);
  }

  /// Capture the current HTTP/HTTPS proxy state before ProxyPin takes over.
  static Future<SystemProxySnapshot> getSystemProxySnapshot({String? networkService}) {
    return instance._getSystemProxySnapshot(networkService: networkService);
  }

  /// Capture the proxy route that is currently effective for new requests.
  ///
  /// macOS resolves this from `scutil --proxy`; other platforms fall back to
  /// their configured proxy snapshot.
  static Future<SystemProxySnapshot> getEffectiveSystemProxySnapshot() {
    return instance._getEffectiveSystemProxySnapshot();
  }

  /// Restore a state previously returned by [getSystemProxySnapshot].
  static Future<void> restoreSystemProxy(SystemProxySnapshot snapshot) {
    return instance._restoreSystemProxy(snapshot);
  }

  /// Take ownership of one immutable network service for the whole
  /// transaction. macOS must not re-resolve the active service between the
  /// backup and the write.
  static Future<void> takeSystemProxyOwnership({
    required int port,
    required String passDomains,
    String? networkService,
    SystemProxySnapshot? expected,
  }) {
    return instance._takeSystemProxyOwnership(
      port: port,
      passDomains: passDomains,
      networkService: networkService,
      expected: expected,
    );
  }

  /// Restore only protocol endpoints that still belong to ProxyPin. This
  /// preserves a newer owner that may have changed HTTP or HTTPS meanwhile.
  static Future<void> restoreOwnedSystemProxyEndpoints({
    required SystemProxySnapshot backup,
    required String ownerHost,
    required int ownerPort,
    required String expectedBypassDomains,
  }) {
    return instance._restoreOwnedSystemProxyEndpoints(
      backup: backup,
      ownerHost: ownerHost,
      ownerPort: ownerPort,
      expectedBypassDomains: expectedBypassDomains,
    );
  }

  ///设置系统代理
  static Future<void> setSystemProxy(int port, bool sslSetting, String proxyPassDomains) async {
    await instance._setSystemProxy(port, sslSetting, proxyPassDomains);
  }

  ///设置Https代理启用状态
  static void setSslProxyEnable(bool proxyEnable, port) {
    instance._setSslProxyEnable(proxyEnable, port);
  }

  /// 设置系统代理
  /// @param sslSetting 是否设置https代理只在mac中有效
  static Future<void> setSystemProxyEnable(int port, bool enable, bool sslSetting,
      {required String passDomains}) async {
    //启用系统代理
    if (enable) {
      await setSystemProxy(port, sslSetting, passDomains);
      return;
    }

    await instance._setProxyEnable(enable, sslSetting);
  }

  ///设置代理忽略地址
  static Future<void> setProxyPassDomains(String proxyPassDomains) async {
    instance._setProxyPassDomains(proxyPassDomains);
  }

  //子类抽象方法

  ///获取系统代理
  Future<ProxyInfo?> _getSystemProxy(ProxyTypes types) async {
    return null;
  }

  Future<SystemProxySnapshot> _getSystemProxySnapshot({String? networkService}) async {
    final proxies = await Future.wait([
      _getSystemProxy(ProxyTypes.http),
      _getSystemProxy(ProxyTypes.https),
    ]);
    return SystemProxySnapshot(http: proxies[0], https: proxies[1]);
  }

  Future<SystemProxySnapshot> _getEffectiveSystemProxySnapshot() {
    return _getSystemProxySnapshot();
  }

  Future<void> _takeSystemProxyOwnership({
    required int port,
    required String passDomains,
    String? networkService,
    SystemProxySnapshot? expected,
  }) {
    return _setSystemProxy(port, true, passDomains).then((_) {});
  }

  Future<void> _restoreOwnedSystemProxyEndpoints({
    required SystemProxySnapshot backup,
    required String ownerHost,
    required int ownerPort,
    required String expectedBypassDomains,
  }) async {
    final current = await _getSystemProxySnapshot(networkService: backup.networkService);
    if (current.ownsAnyEndpoint(host: ownerHost, port: ownerPort)) {
      await _restoreSystemProxy(backup);
    }
  }

  Future<void> _restoreSystemProxy(SystemProxySnapshot snapshot) async {
    final manager = ProxyManager();
    await manager.cleanSystemProxy();
    if (snapshot.http != null) {
      await manager.setAsSystemProxy(ProxyTypes.http, snapshot.http!.host, snapshot.http!.port!);
    }
    if (snapshot.https != null) {
      await manager.setAsSystemProxy(ProxyTypes.https, snapshot.https!.host, snapshot.https!.port!);
    }
    if (snapshot.bypassDomains != null) {
      await _setProxyPassDomains(snapshot.bypassDomains!);
    }
  }

  ///设置系统代理
  Future<void> _setSystemProxy(int port, bool sslSetting, String proxyPassDomains) async {
    ProxyManager manager = ProxyManager();
    await manager.setAsSystemProxy(sslSetting ? ProxyTypes.https : ProxyTypes.http, "127.0.0.1", port);
    setProxyPassDomains(proxyPassDomains);
  }

  ///设置代理是否启用
  Future<void> _setProxyEnable(bool proxyEnable, bool sslSetting) async {
    ProxyManager manager = ProxyManager();
    await manager.cleanSystemProxy();
  }

  ///设置Https代理启用状态
  Future<bool> _setSslProxyEnable(bool proxyEnable, int port) async {
    return false;
  }

  ///设置代理忽略地址
  Future<void> _setProxyPassDomains(String proxyPassDomains) async {}
}

class MacSystemProxy implements SystemProxy {
  static String? _hardwarePort;
  static const MethodChannel _systemProxyChannel = MethodChannel('com.proxy/systemProxy');

  static Future<String> _refreshHardwarePort() async {
    final name = await hardwarePort();
    _hardwarePort = name;
    return name;
  }

  // Helper to safely quote a string for sh (single-quote and escape any internal single quotes)
  static String _shellQuote(String s) {
    // Replace ' with '\'' which is the safe way to include single quotes inside single-quoted strings in shell
    return "'${s.replaceAll("'", "'\\''")}'";
  }

  ///获取系统代理
  @override
  Future<ProxyInfo?> _getSystemProxy(ProxyTypes proxyTypes) async {
    _hardwarePort = _hardwarePort ?? await hardwarePort();

    // ensure we have a name
    if (_hardwarePort == null || _hardwarePort!.isEmpty) {
      logger.e('hardwarePort is empty, cannot get system proxy');
      return null;
    }

    final quotedName = _shellQuote(_hardwarePort!);

    final commandResult = await Process.run('bash',
        ['-c', 'networksetup ${proxyTypes == ProxyTypes.http ? '-getwebproxy' : '-getsecurewebproxy'} $quotedName']);
    if (commandResult.exitCode != 0) {
      throw StateError('读取 macOS 系统代理失败: ${commandResult.stderr}');
    }
    final result = commandResult.stdout.toString().split('\n');

    // defensive parsing: find lines safely
    String enabledLine = result.firstWhere((item) => item.contains('Enabled'), orElse: () => '');
    if (enabledLine.isEmpty) {
      throw StateError('无法解析 macOS 系统代理状态: ${result.join('\n')}');
    }

    var proxyEnableParts = enabledLine.trim().split(RegExp(r":\s*"));
    var proxyEnable = proxyEnableParts.length > 1 ? proxyEnableParts[1] : 'No';
    if (proxyEnable == 'No') {
      return null;
    }

    String serverLine = result.firstWhere((item) => item.contains('Server'), orElse: () => '');
    String portLine = result.firstWhere((item) => item.contains('Port'), orElse: () => '');
    if (serverLine.isEmpty || portLine.isEmpty) {
      throw StateError('无法解析 macOS 系统代理地址: ${result.join('\n')}');
    }

    var proxyServer = serverLine.trim().split(RegExp(r":\s*"))[1];
    var proxyPort = portLine.trim().split(RegExp(r":\s*"))[1];
    if (proxyEnable == 'Yes' && proxyServer.isNotEmpty) {
      return ProxyInfo.of(proxyServer, int.parse(proxyPort));
    }
    return null;
  }

  Future<ProxyInfo?> _getProxyForService(ProxyTypes proxyTypes, String networkService) async {
    final quotedName = _shellQuote(networkService);
    final commandResult = await Process.run('bash',
        ['-c', 'networksetup ${proxyTypes == ProxyTypes.http ? '-getwebproxy' : '-getsecurewebproxy'} $quotedName']);
    if (commandResult.exitCode != 0) {
      throw StateError('读取 macOS 系统代理失败: ${commandResult.stderr}');
    }
    final result = commandResult.stdout.toString().split('\n');
    final enabledLine = result.firstWhere((item) => item.contains('Enabled'), orElse: () => '');
    if (enabledLine.isEmpty) {
      throw StateError('无法解析 macOS 系统代理状态: ${result.join('\n')}');
    }
    final enabledParts = enabledLine.trim().split(RegExp(r":\s*"));
    if ((enabledParts.length > 1 ? enabledParts[1] : 'No') == 'No') return null;

    final serverLine = result.firstWhere((item) => item.contains('Server'), orElse: () => '');
    final portLine = result.firstWhere((item) => item.contains('Port'), orElse: () => '');
    if (serverLine.isEmpty || portLine.isEmpty) {
      throw StateError('无法解析 macOS 系统代理地址: ${result.join('\n')}');
    }
    final proxyServer = serverLine.trim().split(RegExp(r":\s*"))[1];
    final proxyPort = int.tryParse(portLine.trim().split(RegExp(r":\s*"))[1]);
    if (proxyServer.isEmpty || proxyPort == null) {
      throw StateError('无法解析 macOS 系统代理地址: ${result.join('\n')}');
    }
    return ProxyInfo.of(proxyServer, proxyPort);
  }

  ///mac设置代理地址
  @override
  Future<bool> _setSystemProxy(int port, bool sslSetting, String proxyPassDomains) async {
    final networkService = await _refreshHardwarePort();
    if (networkService.isEmpty) {
      logger.e('hardwarePort is empty, cannot set system proxy');
      return false;
    }

    await _takeSystemProxyOwnership(
      port: port,
      passDomains: proxyPassDomains,
      networkService: networkService,
    );
    return true;
  }

  @override
  Future<void> _takeSystemProxyOwnership({
    required int port,
    required String passDomains,
    String? networkService,
    SystemProxySnapshot? expected,
  }) async {
    final service = networkService ?? await _refreshHardwarePort();
    if (service.isEmpty) throw StateError('无法识别 macOS 网络服务，未接管系统代理');
    if (port < 1 || port > 65535) throw StateError('ProxyPin 监听端口无效: $port');

    final quotedName = _shellQuote(service);

    if (expected != null) {
      try {
        await _systemProxyChannel.invokeMethod<void>('takeOwnership', {
          'networkService': service,
          'expected': expected.toJson(),
          'ownerHost': '127.0.0.1',
          'ownerPort': port,
        });
      } on PlatformException catch (error) {
        final details = error.details;
        final mayHaveChanged = details is Map ? details['mayHaveChanged'] == true : true;
        throw SystemProxyTransactionException(
          message: error.message ?? 'macOS 系统代理事务失败',
          code: error.code,
          mayHaveChanged: mayHaveChanged,
        );
      }
      return;
    }

    List<String> commands = [
      'networksetup -setwebproxy $quotedName 127.0.0.1 $port',
      'networksetup -setsecurewebproxy $quotedName 127.0.0.1 $port',
      'networksetup -setproxybypassdomains $quotedName ${_proxyBypassArgs(passDomains)}',
    ];
    var results = await Process.run('bash', ['-c', _concatCommands(commands)]);
    logger.d('set proxyServer, name: $service, exitCode: ${results.exitCode}, stdout: ${results.stdout}');
    bool success = results.exitCode == 0;
    if (!success) {
      logger.e('setSystemProxy failed, stderr: ${results.stderr}');
      // A modal administrator prompt creates an unbounded race window in
      // which Surge can change the same service. Until ProxyPin has a signed
      // privileged helper that performs an atomic compare-and-swap, fail
      // closed instead of replaying stale commands after authorization.
      throw StateError('设置 macOS 系统代理失败；为避免覆盖授权期间变化的 Surge 配置，本次未使用管理员重试');
    }
  }

  ///设置Https代理
  @override
  Future<bool> _setSslProxyEnable(bool proxyEnable, port) async {
    var name = await _refreshHardwarePort();
    if (name.isEmpty) {
      logger.e('hardwarePort is empty, cannot set ssl proxy state');
      return false;
    }
    final quotedName = _shellQuote(name);

    List<String> commands = [
      proxyEnable
          ? 'networksetup -setsecurewebproxy $quotedName 127.0.0.1 $port'
          : 'networksetup -setsecurewebproxystate $quotedName off'
    ];

    var results = await Process.run('bash', ['-c', _concatCommands(commands)]);
    bool success = results.exitCode == 0;
    if (!success) {
      logger.e('setSystemProxy failed, stderr: ${results.stderr}');
      return setProxyWithAuth(commands);
    }
    return success;
  }

  ///mac获取当前网络名称
  static Future<String> hardwarePort() async {
    final primaryService = await _primaryNetworkServiceName();
    if (primaryService.isNotEmpty) return primaryService;

    // Older macOS versions or unusual network states may not expose a global
    // PrimaryService. Keep the physical-interface lookup as a compatibility
    // fallback, but never prefer en0 over an active VPN/Network Extension.
    var name = await networkName();
    // Use a safer pipeline that avoids embedding awk's $2 (which complicates Dart string quoting).
    // This command finds the Device line, takes the following Hardware Port line, and extracts the part after ':'
    var cmd =
        'networksetup -listnetworkserviceorder | grep "Device: $name" -A 1 | grep "Hardware Port" | cut -d: -f2 | sed -n \'1p\'';
    var results = await Process.run('bash', ['-c', cmd]);
    var out = results.stdout.toString().trim();
    if (out.isEmpty) return '';
    // split on newlines or commas and take the first non-empty token
    var parts = out.split(RegExp(r"[\r\n,]+"));
    return parts.first.trim();
  }

  static Future<String> _primaryNetworkServiceName() async {
    try {
      final globalIPv4 = await _scutilShow('State:/Network/Global/IPv4');
      final serviceId = RegExp(r'PrimaryService\s*:\s*([^\s}]+)').firstMatch(globalIPv4)?.group(1)?.trim();
      if (serviceId == null || serviceId.isEmpty) return '';

      final service = await _scutilShow('Setup:/Network/Service/$serviceId');
      return RegExp(r'UserDefinedName\s*:\s*(.+)').firstMatch(service)?.group(1)?.trim() ?? '';
    } catch (error) {
      logger.w('读取 macOS PrimaryService 失败，回退到物理网络服务: $error');
      return '';
    }
  }

  static Future<String> _scutilShow(String key) async {
    final process = await Process.start('/usr/sbin/scutil', const []);
    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    final stderrFuture = process.stderr.transform(utf8.decoder).join();
    process.stdin.writeln('show $key');
    process.stdin.writeln('quit');
    await process.stdin.close();

    final exitCode = await process.exitCode;
    final output = await stdoutFuture;
    final error = await stderrFuture;
    if (exitCode != 0) {
      throw StateError('scutil 读取 $key 失败: $error');
    }
    return output;
  }

  ///设置代理忽略地址
  @override
  Future<void> _setProxyPassDomains(String proxyPassDomains) async {
    await _refreshHardwarePort();
    if (_hardwarePort == null || _hardwarePort!.isEmpty) {
      logger.e('hardwarePort is empty, cannot set proxy bypass domains');
      return;
    }
    final quotedName = _shellQuote(_hardwarePort!);
    var results = await Process.run(
        'bash', ['-c', 'networksetup -setproxybypassdomains $quotedName ${_proxyBypassArgs(proxyPassDomains)}']);
    logger.d('set proxyPassDomains, name: $_hardwarePort, exitCode: ${results.exitCode}, stdout: ${results.stdout}');
  }

  ///mac设置代理是否启用
  @override
  Future<void> _setProxyEnable(bool proxyEnable, bool sslSetting) async {
    var proxyMode = proxyEnable ? 'on' : 'off';
    await _refreshHardwarePort();
    if (_hardwarePort == null || _hardwarePort!.isEmpty) {
      logger.e('hardwarePort is empty, cannot set proxy enable state');
      return;
    }
    logger.d('set proxyEnable: $proxyEnable, name: $_hardwarePort');
    final quotedName = _shellQuote(_hardwarePort!);
    List<String> commands = [
      'networksetup -setwebproxystate $quotedName $proxyMode',
      sslSetting ? 'networksetup -setsecurewebproxystate $quotedName $proxyMode' : ''
    ];

    var results = await Process.run('bash', ['-c', _concatCommands(commands)]);

    if (results.exitCode != 0) {
      logger.e('setProxyEnable failed, stderr: ${results.stderr}');
      await setProxyWithAuth(commands);
    }
  }

  Future<bool> setProxyWithAuth(List<String> commands) async {
    // 使用 quoted form of 确保 shell 指令被 AppleScript 正确转义
    String script = 'do shell script "${_concatCommands(commands)}" with administrator privileges';
    try {
      final result = await Process.run('osascript', ['-e', script]);
      bool success = result.exitCode == 0;
      if (!success) {
        logger.e("操作失败或用户取消: ${result.stderr}");
      }
      return success;
    } catch (e) {
      logger.e("执行 AppleScript 出错: $e");
      return false;
    }
  }

  static String _concatCommands(List<String> commands) {
    return commands.where((element) => element.isNotEmpty).join(' && ');
  }

  static String _proxyBypassArgs(String value) {
    final entries =
        value.split(';').map((entry) => entry.trim()).where((entry) => entry.isNotEmpty).map(_shellQuote).toList();
    return entries.isEmpty ? 'Empty' : entries.join(' ');
  }

  @override
  Future<SystemProxySnapshot> _getEffectiveSystemProxySnapshot() async {
    final result = await Process.run('/usr/sbin/scutil', ['--proxy']);
    if (result.exitCode != 0) {
      throw StateError('读取 macOS 有效系统代理失败: ${result.stderr}');
    }
    return SystemProxySnapshot.fromScutilProxyOutput(result.stdout.toString());
  }

  @override
  Future<SystemProxySnapshot> _getSystemProxySnapshot({String? networkService}) async {
    final service = networkService ?? await _refreshHardwarePort();
    if (service.isEmpty) {
      throw StateError('无法识别当前 macOS 网络服务，未接管系统代理');
    }
    final proxies = await Future.wait([
      _getProxyForService(ProxyTypes.http, service),
      _getProxyForService(ProxyTypes.https, service),
      _getProxyPassDomains(service),
    ]);
    return SystemProxySnapshot(
      http: proxies[0] as ProxyInfo?,
      https: proxies[1] as ProxyInfo?,
      bypassDomains: proxies[2] as String,
      networkService: service,
    );
  }

  Future<String> _getProxyPassDomains(String networkService) async {
    if (networkService.isEmpty) {
      throw StateError('无法识别当前 macOS 网络服务，未读取代理绕过列表');
    }
    final result = await Process.run(
      'networksetup',
      ['-getproxybypassdomains', networkService],
    );
    if (result.exitCode != 0) {
      throw StateError('读取 macOS 代理绕过列表失败: ${result.stderr}');
    }

    final lines = result.stdout
        .toString()
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    if (lines.isEmpty || lines.first.startsWith("There aren't any")) return '';
    if (lines.first.startsWith('These are the bypass domains')) {
      lines.removeAt(0);
    }
    return lines.join(';');
  }

  @override
  Future<void> _restoreSystemProxy(SystemProxySnapshot snapshot) async {
    final service = snapshot.networkService ?? await _refreshHardwarePort();
    if (service.isEmpty) {
      throw StateError('hardwarePort is empty, cannot restore system proxy');
    }

    final quotedName = _shellQuote(service);
    final commands = <String>[
      snapshot.http == null
          ? 'networksetup -setwebproxystate $quotedName off'
          : 'networksetup -setwebproxy $quotedName ${_shellQuote(snapshot.http!.host)} ${snapshot.http!.port}',
      snapshot.https == null
          ? 'networksetup -setsecurewebproxystate $quotedName off'
          : 'networksetup -setsecurewebproxy $quotedName ${_shellQuote(snapshot.https!.host)} ${snapshot.https!.port}',
    ];
    if (snapshot.bypassDomains != null) {
      final entries = snapshot.bypassDomains!
          .split(';')
          .map((entry) => entry.trim())
          .where((entry) => entry.isNotEmpty)
          .map(_shellQuote)
          .toList();
      commands.add(
        'networksetup -setproxybypassdomains $quotedName ${entries.isEmpty ? 'Empty' : entries.join(' ')}',
      );
    }

    final result = await Process.run('bash', ['-c', _concatCommands(commands)]);
    if (result.exitCode == 0) return;
    logger.e('restoreSystemProxy failed, stderr: ${result.stderr}');
    final success = await setProxyWithAuth(commands);
    if (!success) throw StateError('恢复系统代理失败');
  }

  @override
  Future<void> _restoreOwnedSystemProxyEndpoints({
    required SystemProxySnapshot backup,
    required String ownerHost,
    required int ownerPort,
    required String expectedBypassDomains,
  }) async {
    final service = backup.networkService ?? await _refreshHardwarePort();
    if (service.isEmpty) throw StateError('无法识别恢复租约对应的 macOS 网络服务');
    await _systemProxyChannel.invokeMethod<void>('restoreOwnedEndpoints', {
      'networkService': service,
      'backup': backup.toJson(),
      'ownerHost': ownerHost,
      'ownerPort': ownerPort,
    });
  }
}

class WindowsSystemProxy extends SystemProxy {
  ///设置windows代理是否启用
  @override
  Future<void> _setProxyEnable(bool proxyEnable, bool sslSetting) async {
    await _internetSettings('add', ['ProxyEnable', '/t', 'REG_DWORD', '/f', '/d', proxyEnable ? '1' : '0']);
  }

  ///获取系统代理
  @override
  Future<ProxyInfo?> _getSystemProxy(ProxyTypes types) async {
    var results = await _internetSettings('query', ['ProxyEnable']);

    var proxyEnableLine = results.split('\r\n').where((item) => item.contains('ProxyEnable')).first.trim();
    if (proxyEnableLine.substring(proxyEnableLine.length - 1) != '1') {
      return null;
    }

    return _internetSettings('query', ['ProxyServer']).then((results) {
      var proxyServerLine = results.split('\r\n').where((item) => item.contains('ProxyServer')).firstOrNull;
      var proxyServerLineSplits = proxyServerLine?.split(RegExp(r"\s+"));

      if (proxyServerLineSplits == null || proxyServerLineSplits.length < 2) {
        return null;
      }

      var proxyLine = proxyServerLineSplits[proxyServerLineSplits.length - 1];
      if (proxyLine.startsWith("http://") || proxyLine.startsWith("https:///")) {
        proxyLine = proxyLine.replaceFirst("http://", "").replaceFirst("https:///", "");
      }

      var proxyServer = proxyLine.split(":")[0];
      var proxyPort = proxyLine.split(":")[1];
      logger.d("$proxyServer:$proxyPort");
      return ProxyInfo.of(proxyServer, int.parse(proxyPort));
    }).catchError((e) {
      logger.e('getSystemProxy error', error: e, stackTrace: StackTrace.current);
      return null;
    });
  }

  ///设置代理忽略地址
  @override
  Future<void> _setProxyPassDomains(String proxyPassDomains) async {
    var results = await _internetSettings('add', ['ProxyOverride', '/t', 'REG_SZ', '/d', proxyPassDomains, '/f']);
    logger.i('set proxyPassDomains, stdout: $results');
  }

  static Future<String> _internetSettings(String cmd, List<String> args) async {
    return Process.run('reg', [
      cmd,
      'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings',
      '/v',
      ...args,
    ]).then((results) => results.stdout.toString());
  }
}

class LinuxSystemProxy extends SystemProxy {
  @override
  Future<void> _setSystemProxy(int port, bool sslSetting, String proxyPassDomains) async {
    ProxyManager manager = ProxyManager();

    await manager.setAsSystemProxy(ProxyTypes.http, "127.0.0.1", port);
    if (sslSetting) await manager.setAsSystemProxy(ProxyTypes.https, "127.0.0.1", port);

    SystemProxy.setProxyPassDomains(proxyPassDomains);
  }

  ///linux 获取代理
  @override
  Future<ProxyInfo?> _getSystemProxy(ProxyTypes types) async {
    var mode = await Process.run("gsettings", ["get", "org.gnome.system.proxy", "mode"])
        .then((value) => value.stdout.toString().trim());
    if (mode.contains("manual")) {
      var hostFuture = Process.run("gsettings", ["get", "org.gnome.system.proxy.${types.name}", "host"])
          .then((value) => value.stdout.toString().trim());
      var portFuture = Process.run("gsettings", ["get", "org.gnome.system.proxy.${types.name}", "port"])
          .then((value) => value.stdout.toString().trim());

      return Future.wait([hostFuture, portFuture]).then((value) {
        var host = Strings.trimWrap(value[0], "'");
        var port = Strings.trimWrap(value[1], "'");
        if (host.isNotEmpty && port.isNotEmpty) {
          return ProxyInfo.of(host, int.parse(port));
        }
        return null;
      });
    }
    return null;
  }
}

void main() async {
  // single instance
  ProxyManager manager = ProxyManager();
// set a http proxy
  await manager.setAsSystemProxy(ProxyTypes.http, "127.0.0.1", 1087);
}
