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

import 'package:proxypin/network/channel/host_port.dart';
import 'package:proxypin/network/util/file_read.dart';
import 'package:proxypin/network/components/host_filter.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/network/util/system_proxy.dart';
import 'package:proxypin/network/util/system_proxy_snapshot.dart';
import 'package:proxypin/utils/platform.dart';

class Configuration {
  ///代理相关配置
  int port = 9099;

  //是否启用https抓包
  bool enableSsl = Platforms.isMobile();

  //是否设置系统代理
  bool enableSystemProxy = true;

  //代理忽略域名
  String proxyPassDomains = SystemProxy.proxyPassDomains;

  //enabled socks5 proxy
  bool enableSocks5 = true;

  //外部代理
  ProxyInfo? externalProxy;

  //是否将接管前检测到的兼容 HTTP/HTTPS 代理作为唯一上游。
  //仅在启动或切换模式时检测一次，不进入请求热路径或后台轮询。
  bool chainSystemProxy = true;

  //Proxyman 风格第一跳模式：ProxyPin 临时接管 macOS HTTP/HTTPS，
  //再把接管前的代理作为唯一上游。默认关闭，绝不自动修改 Surge。
  bool firstHopProxyMode = false;

  //本次运行自动识别出的上游，不写入配置文件。
  ProxyInfo? runtimeExternalProxy;

  //主动接管系统代理前的状态。持久化用于同一进程的安全恢复；
  //被动共存不会根据历史备份自动写回网络配置。
  SystemProxySnapshot? systemProxyBackup;

  // Immutable identity of the system-proxy lease written together with
  // [systemProxyBackup]. Recovery must not rely on an editable live port or
  // bypass preference after a restart.
  String? systemProxyLeaseOwnerHost;
  int? systemProxyLeaseOwnerPort;
  String? systemProxyLeaseBypassDomains;

  // Runtime-only guard for the conservative case where macOS still points at
  // this process but no trustworthy backup is available. Never persist this:
  // every launch must re-evaluate the actual configured/effective route.
  bool systemProxyRecoveryRequired = false;

  /// True while a first-hop preference is active or a persisted ownership
  /// lease still needs recovery. UI and routing must stay frozen in either
  /// case, even if a recovery launch temporarily set the preference false.
  bool get systemProxyLeaseLocked => firstHopProxyMode || systemProxyBackup != null || systemProxyRecoveryRequired;

  //启动时读取到的“实际生效”代理。它与 networksetup 配置快照分开保存：
  //Surge/VPN 的 Network Extension 可能让两者不同。持久化是为了在
  //ProxyPin 异常退出后仍能恢复唯一上游，使用前会做一次快速可达性检查。
  SystemProxySnapshot? effectiveSystemProxyBackup;

  ProxyInfo? get effectiveExternalProxy {
    // Freeze the validated upstream for the lifetime of a first-hop lease.
    // Editing the persistent external-proxy preference must never reroute live
    // system traffic behind ProxyPin without another preflight transaction.
    if (systemProxyLeaseLocked) {
      return runtimeExternalProxy?.enabled == true ? runtimeExternalProxy : null;
    }
    if (externalProxy?.enabled == true) return externalProxy;
    if (runtimeExternalProxy?.enabled == true) return runtimeExternalProxy;
    return null;
  }

  //白名单应用
  List<String> appWhitelist = [];

  //白名单应用是否启用
  bool appWhitelistEnabled = true;

  //应用黑名单
  List<String>? appBlacklist;

  //远程连接 不持久化保存
  String? remoteHost;

  bool enabledHttp2 = false; // 是否启用http2

  //历史记录缓存时间
  int historyCacheTime = 0;

  //默认是否启动
  bool startup = false;

  Configuration._();

  /// 单例
  static Configuration? _instance;

  static Future<Configuration> get instance async {
    if (_instance == null) {
      try {
        var loadConfig = await _loadConfig();
        _instance = Configuration.fromJson(loadConfig);
      } catch (e) {
        logger.e('初始化配置失败', error: e, stackTrace: StackTrace.current);
        _instance = Configuration._();
      }
    }
    return _instance!;
  }

  /// 加载配置
  Configuration.fromJson(Map<String, dynamic> config) {
    final configuredPort = config['port'];
    if (configuredPort is int && configuredPort >= 1 && configuredPort <= 65535) {
      port = configuredPort;
    }
    enableSsl = config['enableSsl'] == true;
    startup = config['startup'] ?? Platforms.isDesktop();
    enableSystemProxy = config['enableSystemProxy'] ?? (config['enableDesktop'] ?? true);
    enableSocks5 = config['enableSocks5'] ?? true;
    enabledHttp2 = config['enabledHttp2'] ?? false;

    proxyPassDomains = config['proxyPassDomains'] ?? SystemProxy.proxyPassDomains;
    historyCacheTime = config['historyCacheTime'] ?? 0;
    if (config['externalProxy'] != null) {
      externalProxy = ProxyInfo.fromJson(config['externalProxy']);
    }
    chainSystemProxy = config['chainSystemProxy'] ?? true;
    firstHopProxyMode = config['firstHopProxyMode'] == true;
    if (config['systemProxyBackup'] is Map) {
      systemProxyBackup = SystemProxySnapshot.fromJson(
        Map<String, dynamic>.from(config['systemProxyBackup']),
      );
    }
    systemProxyLeaseOwnerHost = config['systemProxyLeaseOwnerHost'] as String?;
    final leaseOwnerPort = config['systemProxyLeaseOwnerPort'];
    if (leaseOwnerPort is int && leaseOwnerPort >= 1 && leaseOwnerPort <= 65535) {
      systemProxyLeaseOwnerPort = leaseOwnerPort;
    }
    systemProxyLeaseBypassDomains = config['systemProxyLeaseBypassDomains'] as String?;
    if (config['effectiveSystemProxyBackup'] is Map) {
      effectiveSystemProxyBackup = SystemProxySnapshot.fromJson(
        Map<String, dynamic>.from(config['effectiveSystemProxyBackup']),
      );
    }
    appWhitelist = List<String>.from(config['appWhitelist'] ?? []);
    appWhitelistEnabled = config['appWhitelistEnabled'] ?? true;
    appBlacklist = config['appBlacklist'] == null ? null : List<String>.from(config['appBlacklist']);
    HostFilter.whitelist.load(config['whitelist']);
    HostFilter.blacklist.load(config['blacklist']);
  }

  /// 配置文件
  static Future<File> configFile() async {
    var separator = Platform.pathSeparator;
    var home = await FileRead.homeDir();
    return File("${home.path}${separator}config.cnf");
  }

  static Future<File> _leaseFile() async {
    final file = await configFile();
    return File('${file.path}.system-proxy-lease');
  }

  static Future<void> _atomicWrite(File file, String contents) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(contents, flush: true);
    if (Platform.isWindows && await file.exists()) {
      // Windows does not replace an existing destination via File.rename.
      await file.delete();
    }
    await temporary.rename(file.path);
  }

  /// 刷新配置文件
  Future<void> _flushTail = Future<void>.value();

  Future<void> flushConfig() {
    HostFilter.whitelist.toJson();
    HostFilter.blacklist.toJson();
    final jsonMap = toJson();
    final json = jsonEncode(jsonMap);
    logger.d('Refresh configuration file $runtimeType $jsonMap');
    final operation = _flushTail.then((_) async {
      final file = await configFile();
      await _atomicWrite(file, json);

      final leaseFile = await _leaseFile();
      if (jsonMap['systemProxyBackup'] != null) {
        final lease = <String, dynamic>{
          'systemProxyBackup': jsonMap['systemProxyBackup'],
          'effectiveSystemProxyBackup': jsonMap['effectiveSystemProxyBackup'],
          'systemProxyLeaseOwnerHost': jsonMap['systemProxyLeaseOwnerHost'],
          'systemProxyLeaseOwnerPort': jsonMap['systemProxyLeaseOwnerPort'],
          'systemProxyLeaseBypassDomains': jsonMap['systemProxyLeaseBypassDomains'],
        };
        await _atomicWrite(leaseFile, jsonEncode(lease));
      } else {
        if (await leaseFile.exists()) await leaseFile.delete();
        final temporaryLease = File('${leaseFile.path}.tmp');
        if (await temporaryLease.exists()) await temporaryLease.delete();
      }
    });
    // Serialize even un-awaited UI writes. A failed write is returned to its
    // caller, while later writes still get a chance to repair the main file.
    _flushTail = operation.catchError((_) {});
    return operation;
  }

  /// 加载配置文件
  static Future<Map<String, dynamic>> _loadConfig() async {
    final file = await configFile();
    Map<String, dynamic>? config;
    Object? configError;
    if (await file.exists()) {
      try {
        config = Map<String, dynamic>.from(jsonDecode(await file.readAsString()) as Map);
      } catch (error) {
        configError = error;
        logger.e('主配置损坏，尝试读取独立系统代理恢复租约', error: error);
      }
    }

    final leaseFile = await _leaseFile();
    if (await leaseFile.exists()) {
      try {
        final lease = Map<String, dynamic>.from(jsonDecode(await leaseFile.readAsString()) as Map);
        if (lease['systemProxyBackup'] is Map) {
          config ??= <String, dynamic>{};
          for (final key in [
            'systemProxyBackup',
            'effectiveSystemProxyBackup',
            'systemProxyLeaseOwnerHost',
            'systemProxyLeaseOwnerPort',
            'systemProxyLeaseBypassDomains',
          ]) {
            config[key] = lease[key];
          }
          // A recovery lease must start the listener even if the main config
          // was lost. It does not automatically opt back into first-hop.
          config['startup'] = true;
          config['firstHopProxyMode'] = false;
        }
      } catch (error) {
        logger.e('独立系统代理恢复租约损坏', error: error);
        if (config == null) rethrow;
      }
    }

    if (config == null) {
      if (configError != null) throw configError;
      return {};
    }
    logger.i('加载配置文件 [$file]');
    return config;
  }

  Map<String, dynamic> toJson() {
    return {
      'port': port,
      'enableSsl': enableSsl,
      'startup': startup,
      'enableSystemProxy': enableSystemProxy,
      'enableSocks5': enableSocks5,
      'proxyPassDomains': proxyPassDomains,
      'externalProxy': externalProxy?.toJson(),
      'chainSystemProxy': chainSystemProxy,
      'firstHopProxyMode': firstHopProxyMode,
      'systemProxyBackup': systemProxyBackup?.toJson(),
      'systemProxyLeaseOwnerHost': systemProxyBackup == null ? null : systemProxyLeaseOwnerHost,
      'systemProxyLeaseOwnerPort': systemProxyBackup == null ? null : systemProxyLeaseOwnerPort,
      'systemProxyLeaseBypassDomains': systemProxyBackup == null ? null : systemProxyLeaseBypassDomains,
      'effectiveSystemProxyBackup': effectiveSystemProxyBackup?.toJson(),
      'appWhitelist': appWhitelist,
      'appWhitelistEnabled': appWhitelistEnabled,
      'appBlacklist': appBlacklist,
      'historyCacheTime': historyCacheTime,
      'enabledHttp2': enabledHttp2,
      'whitelist': HostFilter.whitelist.toJson(),
      'blacklist': HostFilter.blacklist.toJson(),
    };
  }
}
