import 'dart:io';

import 'package:proxypin/features/workbench/domain/connection_check.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/util/crts.dart';
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
    if (configuration.externalProxy?.enabled == true) {
      checks.add(const ConnectionCheck(
        id: 'external_proxy',
        title: '外部代理链',
        detail: '当前还启用了外部代理。若手机请求超时，请先临时关闭外部代理以排除链路问题。',
        level: ConnectionCheckLevel.warning,
      ));
    }
    return checks;
  }
}
