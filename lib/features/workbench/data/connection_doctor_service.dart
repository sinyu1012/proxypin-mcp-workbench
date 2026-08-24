import 'dart:io';

import 'package:proxypin/features/workbench/domain/connection_check.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/util/crts.dart';
import 'package:proxypin/network/util/system_proxy.dart';
import 'package:proxypin/ui/desktop/ssl/cert_installer.dart';
import 'package:proxypin/utils/ip.dart';

class ConnectionDoctorService {
  const ConnectionDoctorService();

  Future<List<ConnectionCheck>> run(ProxyServer proxyServer, Iterable<HttpRequest> requests) async {
    final checks = <ConnectionCheck>[];
    checks.add(ConnectionCheck(
      id: 'proxy',
      title: '代理服务',
      detail: proxyServer.isRunning ? '正在监听 ${proxyServer.port}' : '代理未启动，手机设置代理后会无法联网',
      level: proxyServer.isRunning ? ConnectionCheckLevel.success : ConnectionCheckLevel.error,
      action: proxyServer.isRunning ? null : '启动代理',
    ));

    if (Platform.isMacOS && proxyServer.configuration.enableSystemProxy) {
      try {
        final configuredProxy = await SystemProxy.getSystemProxySnapshot();
        final effectiveProxy = await SystemProxy.getEffectiveSystemProxySnapshot();
        final configuredOwned = configuredProxy.isOwnedBy(host: '127.0.0.1', port: proxyServer.port);
        final effectiveOwned = effectiveProxy.isOwnedBy(host: '127.0.0.1', port: proxyServer.port);
        final currentOwner = effectiveProxy.http ?? effectiveProxy.https;
        final configuration = proxyServer.configuration;
        final upstream = configuration.effectiveExternalProxy;
        final firstHopReady = effectiveOwned && configuration.chainSystemProxy && upstream != null;
        final recoveryRequired = proxyServer.systemProxyActivation.state == SystemProxyActivationState.recoveryRequired;
        final detail = recoveryRequired
            ? '系统代理恢复尚未完成，ProxyPin 已保持 ${proxyServer.port} 监听；请重试关闭第一跳，恢复成功前不要强制退出'
            : configuration.firstHopProxyMode
                ? firstHopReady
                    ? '第一跳已生效：本机应用 → ProxyPin ${proxyServer.port}'
                        ' → ${upstream.host}:${upstream.port} → 网络'
                    : effectiveOwned && upstream == null
                        ? '系统已指向 ProxyPin ${proxyServer.port}，但要求的唯一 HTTP 上游缺失；请立即关闭第一跳模式以恢复原代理'
                        : '第一跳未生效或已安全回滚；当前有效代理为 '
                            '${currentOwner == null ? '无' : '${currentOwner.host}:${currentOwner.port}'}，ProxyPin 不会后台争抢'
                : effectiveOwned
                    ? '当前实际生效的 HTTP/HTTPS 已指向 ProxyPin 127.0.0.1:${proxyServer.port}'
                    : configuredOwned && currentOwner != null
                        ? 'Wi-Fi 已配置 ProxyPin ${proxyServer.port}，但当前实际生效仍是 '
                            '${currentOwner.host}:${currentOwner.port}。ProxyPin 已将其保留为唯一上游；为避免断网与多重代理，'
                            '不会自动争抢，当前仅显式走 ${proxyServer.port} 的请求会进入抓包列表'
                        : configuredOwned && effectiveProxy.autoConfigEnabled
                            ? 'Wi-Fi 已配置 ProxyPin ${proxyServer.port}，但当前由自动代理脚本接管；为避免多重代理，ProxyPin 未强行覆盖'
                            : configuredOwned
                                ? 'Wi-Fi 已配置 ProxyPin ${proxyServer.port}，但当前有效网络服务尚未采用该配置；本机请求暂时不会进入 ProxyPin'
                                : '安全共存已开启：macOS HTTP/HTTPS 未改为 ProxyPin；本机仅显式走 ${proxyServer.port} 的请求会被捕获';
        checks.add(ConnectionCheck(
          id: 'system_proxy',
          title: '本机系统代理',
          detail: detail,
          level: recoveryRequired
              ? ConnectionCheckLevel.error
              : configuration.firstHopProxyMode
                  ? firstHopReady
                      ? ConnectionCheckLevel.success
                      : ConnectionCheckLevel.error
                  : effectiveOwned
                      ? ConnectionCheckLevel.success
                      : ConnectionCheckLevel.warning,
        ));
      } catch (error) {
        checks.add(ConnectionCheck(
          id: 'system_proxy',
          title: '本机系统代理',
          detail: '无法读取 macOS 系统代理：$error',
          level: ConnectionCheckLevel.error,
        ));
      }
    }

    var portReachable = false;
    try {
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, proxyServer.port,
          timeout: const Duration(milliseconds: 600));
      portReachable = true;
      socket.destroy();
    } catch (_) {}
    checks.add(ConnectionCheck(
      id: 'port',
      title: '端口可达',
      detail: portReachable ? '本机端口 ${proxyServer.port} 响应正常' : '本机无法连接端口 ${proxyServer.port}，可能被占用或服务异常',
      level: portReachable ? ConnectionCheckLevel.success : ConnectionCheckLevel.error,
    ));

    List<String> ips = [];
    try {
      ips = await localIps(readCache: false);
    } catch (_) {}
    final lanIps = ips.where((value) => value != '127.0.0.1' && value != '0.0.0.0').toList();
    checks.add(ConnectionCheck(
      id: 'lan',
      title: '局域网地址',
      detail: lanIps.isEmpty ? '未找到可供手机连接的 IPv4 地址，请确认 Mac 与手机处于同一 Wi-Fi' : '${lanIps.join('、')}:${proxyServer.port}',
      level: lanIps.isEmpty ? ConnectionCheckLevel.error : ConnectionCheckLevel.success,
    ));

    checks.add(ConnectionCheck(
      id: 'https',
      title: 'HTTPS 解密',
      detail: proxyServer.enableSsl ? 'ProxyPin 已允许 HTTPS 解密' : 'HTTPS 解密未开启，只能看到 CONNECT，无法查看请求体',
      level: proxyServer.enableSsl ? ConnectionCheckLevel.success : ConnectionCheckLevel.warning,
      action: proxyServer.enableSsl ? null : '开启 HTTPS',
    ));

    try {
      await CertificateManager.initCAConfig();
      final cert = await CertificateManager.certificateFile();
      final details = await CertificateManager.getCertificateDetails();
      final trustedOnMac = await CertInstaller.isCertInstalled(cert, details);
      checks.add(ConnectionCheck(
        id: 'certificate',
        title: 'ProxyPin CA',
        detail: trustedOnMac ? '根证书存在且已在 Mac 信任；iPhone 仍需单独安装并开启“完全信任”' : '根证书已生成，但 Mac 尚未信任；iPhone 也需要安装并开启“完全信任”',
        level: trustedOnMac ? ConnectionCheckLevel.success : ConnectionCheckLevel.warning,
        action: '查看安装向导',
      ));
    } catch (error) {
      checks.add(ConnectionCheck(
        id: 'certificate',
        title: 'ProxyPin CA',
        detail: '证书初始化失败：$error',
        level: ConnectionCheckLevel.error,
      ));
    }

    final recent = requests.where((request) => DateTime.now().difference(request.requestTime).inMinutes < 5).toList();
    final decrypted = recent.any((request) => request.requestUri?.scheme == 'https' && request.response?.body != null);
    checks.add(ConnectionCheck(
      id: 'traffic',
      title: '最近流量',
      detail: decrypted
          ? '最近 5 分钟已有 ${recent.length} 条请求，并发现可读取的 HTTPS 响应体'
          : recent.isEmpty
              ? '最近 5 分钟没有请求进入 ProxyPin，请检查手机 Wi-Fi 代理地址与端口'
              : '已有 ${recent.length} 条请求，但尚未确认 HTTPS 正文解密',
      level: decrypted
          ? ConnectionCheckLevel.success
          : recent.isEmpty
              ? ConnectionCheckLevel.error
              : ConnectionCheckLevel.warning,
    ));

    final configuration = proxyServer.configuration;
    final upstream = configuration.effectiveExternalProxy;
    if (upstream != null) {
      checks.add(ConnectionCheck(
        id: 'external_proxy',
        title: '单层上游代理',
        detail: 'ProxyPin ${proxyServer.port} → ${upstream.host}:${upstream.port}；没有后台轮询或再次读取系统代理',
        level: ConnectionCheckLevel.success,
      ));
    }
    return checks;
  }
}
