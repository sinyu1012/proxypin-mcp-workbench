import 'package:flutter/material.dart';
import 'package:proxypin/features/workbench/data/connection_doctor_service.dart';
import 'package:proxypin/features/workbench/domain/connection_check.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/ui/desktop/toolbar/phone_connect.dart';
import 'package:proxypin/utils/ip.dart';

class ConnectionDoctorPage extends StatefulWidget {
  final ProxyServer proxyServer;
  final Iterable<HttpRequest> Function() requestsProvider;

  const ConnectionDoctorPage({super.key, required this.proxyServer, required this.requestsProvider});

  @override
  State<ConnectionDoctorPage> createState() => _ConnectionDoctorPageState();
}

class _ConnectionDoctorPageState extends State<ConnectionDoctorPage> {
  final ConnectionDoctorService service = const ConnectionDoctorService();
  List<ConnectionCheck> checks = [];
  bool loading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    setState(() => loading = true);
    final result = await service.run(widget.proxyServer, widget.requestsProvider());
    if (!mounted) return;
    setState(() {
      checks = result;
      loading = false;
    });
  }

  Future<void> _openGuide() async {
    final ips = await localIps(readCache: false);
    if (!mounted) return;
    showDialog(context: context, builder: (_) => PhoneConnect(proxyServer: widget.proxyServer, hosts: ips));
  }

  Future<void> _handleAction(ConnectionCheck check) async {
    switch (check.id) {
      case 'proxy':
        await widget.proxyServer.start();
        await _run();
        return;
      case 'https':
        widget.proxyServer.enableSsl = true;
        await widget.proxyServer.configuration.flushConfig();
        await _run();
        return;
      default:
        await _openGuide();
        return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final errors = checks.where((check) => check.level == ConnectionCheckLevel.error).length;
    final warnings = checks.where((check) => check.level == ConnectionCheckLevel.warning).length;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(18),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('手机连接诊断', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 3),
              Text(
                checks.isEmpty
                    ? '检查代理、端口、局域网、证书和 HTTPS 解密链路'
                    : errors > 0
                        ? '发现 $errors 个阻断问题、$warnings 个提醒'
                        : warnings > 0
                            ? '链路基本可用，还有 $warnings 个提醒'
                            : '连接链路检查通过',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ]),
          ),
          OutlinedButton.icon(
              onPressed: _openGuide, icon: const Icon(Icons.qr_code_2, size: 18), label: const Text('连接手机')),
          const SizedBox(width: 8),
          FilledButton.icon(
              onPressed: loading ? null : _run,
              icon: const Icon(Icons.health_and_safety_outlined, size: 18),
              label: const Text('重新诊断')),
        ]),
      ),
      const Divider(height: 1),
      Expanded(
        child: loading && checks.isEmpty
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : ListView.separated(
                padding: const EdgeInsets.all(18),
                itemCount: checks.length,
                separatorBuilder: (_, __) => const SizedBox(height: 9),
                itemBuilder: (context, index) => _CheckCard(
                  check: checks[index],
                  onAction: checks[index].action == null ? null : () => _handleAction(checks[index]),
                ),
              ),
      ),
    ]);
  }
}

class _CheckCard extends StatelessWidget {
  final ConnectionCheck check;
  final VoidCallback? onAction;

  const _CheckCard({required this.check, this.onAction});

  @override
  Widget build(BuildContext context) {
    final (color, icon) = switch (check.level) {
      ConnectionCheckLevel.success => (Colors.green, Icons.check_circle_outline),
      ConnectionCheckLevel.warning => (Colors.orange, Icons.warning_amber_rounded),
      ConnectionCheckLevel.error => (Colors.red, Icons.error_outline),
      ConnectionCheckLevel.info => (Colors.blue, Icons.info_outline),
    };
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.055),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(width: 12),
        Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(check.title, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 3),
          Text(check.detail, style: Theme.of(context).textTheme.bodySmall),
        ])),
        if (check.action != null) TextButton(onPressed: onAction, child: Text(check.action!)),
      ]),
    );
  }
}
