import 'package:flutter/material.dart';
import 'package:proxypin/features/workbench/ui/api_assets_page.dart';
import 'package:proxypin/features/workbench/ui/capture_plans_page.dart';
import 'package:proxypin/features/workbench/ui/capture_projects_page.dart';
import 'package:proxypin/features/workbench/ui/data_export_page.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/features/workbench/ui/connection_doctor_page.dart';
import 'package:proxypin/features/workbench/ui/mock_scenarios_page.dart';

class AutomationWorkbenchPage extends StatelessWidget {
  final Iterable<HttpRequest> Function() requestsProvider;
  final VoidCallback onOpenHistory;
  final ProxyServer proxyServer;

  const AutomationWorkbenchPage({
    super.key,
    required this.requestsProvider,
    required this.onOpenHistory,
    required this.proxyServer,
  });

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 6,
      child: Builder(
        builder: (tabContext) => Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: false,
            toolbarHeight: 48,
            titleSpacing: 18,
            title: const Text('自动化工作台', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            bottom: const TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                Tab(icon: Icon(Icons.inventory_2_outlined, size: 18), text: '采集方案'),
                Tab(icon: Icon(Icons.folder_copy_outlined, size: 18), text: '抓包项目'),
                Tab(icon: Icon(Icons.account_tree_outlined, size: 18), text: 'API 资产'),
                Tab(icon: Icon(Icons.file_download_outlined, size: 18), text: '数据导出'),
                Tab(icon: Icon(Icons.layers_outlined, size: 18), text: 'Mock 场景'),
                Tab(icon: Icon(Icons.health_and_safety_outlined, size: 18), text: '连接诊断'),
              ],
            ),
          ),
          body: TabBarView(
            physics: const NeverScrollableScrollPhysics(),
            children: [
              CapturePlansPage(
                onOpenHistory: onOpenHistory,
                onOpenExport: () => DefaultTabController.of(tabContext).index = 3,
              ),
              CaptureProjectsPage(onOpenHistory: onOpenHistory),
              ApiAssetsPage(requestsProvider: requestsProvider),
              DataExportPage(requestsProvider: requestsProvider, proxyServer: proxyServer),
              MockScenariosPage(),
              ConnectionDoctorPage(proxyServer: proxyServer, requestsProvider: requestsProvider),
            ],
          ),
        ),
      ),
    );
  }
}
