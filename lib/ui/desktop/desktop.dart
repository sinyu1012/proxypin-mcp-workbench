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
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/bin/listener.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/channel/channel.dart';
import 'package:proxypin/network/channel/channel_context.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/http/websocket.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/network/util/source_address.dart';
import 'package:proxypin/storage/histories.dart';
import 'package:proxypin/ui/component/memory_cleanup.dart';
import 'package:proxypin/ui/component/widgets.dart';
import 'package:proxypin/ui/configuration.dart';
import 'package:proxypin/ui/content/panel.dart';
import 'package:proxypin/ui/desktop/left_menus/favorite.dart';
import 'package:proxypin/ui/desktop/left_menus/history.dart';
import 'package:proxypin/ui/desktop/left_menus/navigation.dart';
import 'package:proxypin/ui/desktop/request/list.dart';
import 'package:proxypin/ui/desktop/toolbar/toolbar.dart';
import 'package:proxypin/ui/desktop/widgets/windows_toolbar.dart';
import 'package:proxypin/ui/launch/launch.dart';
import 'package:proxypin/utils/lang.dart';
import 'package:proxypin/utils/listenable_list.dart';

import 'package:proxypin/network/mcp/mcp_server.dart';
import 'package:proxypin/features/workbench/logic/capture_project_controller.dart';
import 'package:proxypin/features/workbench/ui/automation_workbench_page.dart';

import '../app_update/app_update_repository.dart';
import '../component/split_view.dart';
import '../toolbox/mcp_server_page.dart';
import '../toolbox/toolbox.dart';

/// @author wanghongen
/// 2023/10/8
class DesktopHomePage extends StatefulWidget {
  final Configuration configuration;
  final AppConfiguration appConfiguration;

  const DesktopHomePage(this.configuration, this.appConfiguration, {super.key, required});

  @override
  State<DesktopHomePage> createState() => _DesktopHomePagePageState();
}

class _DesktopHomePagePageState extends State<DesktopHomePage> implements EventListener {
  static final container = ListenableList<HttpRequest>();

  static final GlobalKey<DesktopRequestListState> requestListStateKey = GlobalKey<DesktopRequestListState>();

  final ValueNotifier<int> _selectIndex = ValueNotifier(DesktopNavigationIndex.capture);
  final ValueNotifier<CaptureSourceScope> _captureViewMode = ValueNotifier(CaptureSourceScope.external);
  StreamSubscription<HistoryItem>? _remoteHistorySubscription;
  final List<({Channel channel, HttpRequest request})> _pendingRequests = [];
  final List<({ChannelContext context, HttpResponse response})> _pendingResponses = [];
  Timer? _captureFlushTimer;

  late ProxyServer proxyServer = ProxyServer(widget.configuration);
  late NetworkTabController panel;

  //ProxyServer 状态变化订阅（确保 MCP 启停代理后 UI 同步）
  StreamSubscription<bool>? _proxyStatusSub;

  AppLocalizations get localizations => AppLocalizations.of(context)!;

  @override
  void onRequest(Channel channel, HttpRequest request) {
    _pendingRequests.add((channel: channel, request: request));
    _scheduleCaptureFlush();

    if (request.attributes['quickShare'] == true) {
      _selectIndex.value = isLoopbackSourceAddress(request.sourceIp)
          ? DesktopNavigationIndex.localCapture
          : DesktopNavigationIndex.capture;
      panel.change(request, request.response);
    }

    //监控内存 到达阈值清理
    MemoryCleanupMonitor.onMonitor(onCleanup: () {
      requestListStateKey.currentState?.cleanupEarlyData(32);
    });
  }

  @override
  void onResponse(ChannelContext channelContext, HttpResponse response) {
    _pendingResponses.add((context: channelContext, response: response));
    _scheduleCaptureFlush();
  }

  void _scheduleCaptureFlush() {
    _captureFlushTimer ??= Timer(const Duration(milliseconds: 48), _flushCaptureEvents);
  }

  void _flushCaptureEvents() {
    _captureFlushTimer = null;
    if (!mounted) return;

    final requests = List<({Channel channel, HttpRequest request})>.from(_pendingRequests);
    final responses = List<({ChannelContext context, HttpResponse response})>.from(_pendingResponses);
    _pendingRequests.clear();
    _pendingResponses.clear();

    final requestListState = requestListStateKey.currentState;
    if (requests.isNotEmpty) {
      if (requestListState != null) {
        requestListState.addBatch(requests);
      } else {
        container.addAll(requests.map((entry) => entry.request));
      }
    }
    if (responses.isNotEmpty) {
      requestListState?.addResponses(responses);
      panel.updateResponses(responses.map((entry) => entry.response));
    }
  }

  @override
  void onMessage(Channel channel, HttpMessage message, WebSocketFrame frame) {
    logger.d(
        "[DesktopHomePage] onMessage: message=${message.hashCode} panel.response=${panel.response.get()?.hashCode} panel.request=${panel.request.get()?.hashCode}");

    if (!panel.isSelectedMessage(message)) {
      return;
    }

    // 检查是否是 SSE 或 WebSocket 消息
    bool isStreamMessage =
        message.isWebSocket || message.headers.contentType.toLowerCase().startsWith('text/event-stream');

    if (isStreamMessage) {
      panel.updateForStreamMessage(message);
      logger.d("[DesktopHomePage] onMessage: refreshing selected SSE/WebSocket exchange");
    } else {
      logger.d("[DesktopHomePage] onMessage: triggering changeState");
      panel.changeState();
    }
  }

  @override
  void initState() {
    super.initState();
    _selectIndex.addListener(_handleNavigationChanged);
    proxyServer.addListener(this);
    panel = NetworkTabController(tabStyle: const TextStyle(fontSize: 16), proxyServer: proxyServer);
    _remoteHistorySubscription = HistoryStorage.onRemoteImported.listen((_) {
      if (mounted) {
        _selectIndex.value = DesktopNavigationIndex.history;
      }
    });

    unawaited(CaptureProjectController.instance.initialize(container));

    final mcpServer = McpServer.instance;
    mcpServer.bindRequestContainer(container);
    unawaited(mcpServer.start().catchError((error, stackTrace) {
      logger.e('MCP Server 自动启动失败', error: error, stackTrace: stackTrace);
    }));

    // 订阅 ProxyServer 状态变化，让 MCP 启停代理后 UI 同步刷新
    _proxyStatusSub = proxyServer.onStatusChanged.listen((running) {
      if (!mounted) return;
      // 同步到 SocketLaunch 的全局 startStatus，使工具栏按钮状态实时变化
      SocketLaunch.startStatus.value = ValueWrap.of(running);
      setState(() {});
    });

    if (widget.appConfiguration.upgradeNoticeV28) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        showUpgradeNotice();
      });
    } else {
      AppUpdateRepository.checkUpdate(context);
    }
  }

  @override
  void dispose() {
    _captureFlushTimer?.cancel();
    _flushCaptureEvents();
    _proxyStatusSub?.cancel();
    _proxyStatusSub = null;
    _remoteHistorySubscription?.cancel();
    _selectIndex.removeListener(_handleNavigationChanged);
    _selectIndex.dispose();
    _captureViewMode.dispose();
    super.dispose();
  }

  void _handleNavigationChanged() {
    switch (_selectIndex.value) {
      case DesktopNavigationIndex.capture:
        _captureViewMode.value = CaptureSourceScope.external;
        break;
      case DesktopNavigationIndex.localCapture:
        _captureViewMode.value = CaptureSourceScope.localMachine;
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    var navigationView = [
      DesktopRequestListWidget(
        key: requestListStateKey,
        proxyServer: proxyServer,
        list: container,
        panel: panel,
        captureViewMode: _captureViewMode,
      ),
      AutomationWorkbenchPage(
        requestsProvider: () => container.source,
        onOpenHistory: () => _selectIndex.value = DesktopNavigationIndex.history,
        proxyServer: proxyServer,
      ),
      Favorites(panel: panel),
      HistoryPageWidget(proxyServer: proxyServer, container: container, panel: panel),
      const Toolbox(),
      const McpServerPage(),
    ];

    return Scaffold(
        appBar: Tab(
            child: Container(
          padding: EdgeInsets.only(bottom: 2.5),
          margin: EdgeInsets.only(bottom: 5),
          decoration: BoxDecoration(
              // color: Theme.of(context).brightness == Brightness.dark ? null : Color(0xFFF9F9F9),
              border: Border(
                  bottom: BorderSide(
                      color: Theme.of(context).dividerColor.withValues(alpha: 0.3),
                      width: Platform.isMacOS ? 0.2 : 0.55))),
          child: Platform.isMacOS
              ? Toolbar(proxyServer, requestListStateKey)
              : WindowsToolbar(title: Toolbar(proxyServer, requestListStateKey)),
        )),
        body: Row(
          children: [
            LeftNavigationBar(
                selectIndex: _selectIndex, appConfiguration: widget.appConfiguration, proxyServer: proxyServer),
            Expanded(
              child: ValueListenableBuilder(
                valueListenable: _selectIndex,
                builder: (_, navigationIndex, __) {
                  final contentIndex = DesktopNavigationIndex.contentIndex(navigationIndex);
                  // 工作台、历史、工具箱和 MCP 都是独立页面，不应被请求详情面板挤占。
                  // 抓包、本机抓包与收藏复用同一个右侧请求详情面板。
                  if (!DesktopNavigationIndex.usesRequestPanel(navigationIndex)) {
                    return LazyIndexedStack(index: contentIndex < 0 ? 0 : contentIndex, children: navigationView);
                  }
                  return VerticalSplitView(
                      ratio: widget.appConfiguration.panelRatio,
                      minRatio: 0.15,
                      maxRatio: 0.9,
                      onRatioChanged: (ratio) {
                        widget.appConfiguration.panelRatio = double.parse(ratio.toStringAsFixed(2));
                        widget.appConfiguration.flushConfig();
                      },
                      left: LazyIndexedStack(index: contentIndex < 0 ? 0 : contentIndex, children: navigationView),
                      right: panel);
                },
              ),
            )
          ],
        ));
  }

  //更新引导
  void showUpgradeNotice() {
    bool isCN = Localizations.localeOf(context) == const Locale.fromSubtags(languageCode: 'zh');

    showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) {
          return AlertDialog(
              scrollable: true,
              actions: [
                TextButton(
                    onPressed: () {
                      widget.appConfiguration.upgradeNoticeV28 = false;
                      widget.appConfiguration.flushConfig();
                      Navigator.pop(context);
                    },
                    child: Text(localizations.close))
              ],
              title: Text(isCN ? '更新内容V${AppConfiguration.version}' : "What's new in V${AppConfiguration.version}",
                  style: const TextStyle(fontSize: 18)),
              content: Container(
                  constraints: const BoxConstraints(maxWidth: 600),
                  child: SelectableText(
                      isCN
                          ? '提示：默认不会开启HTTPS抓包，请安装证书后再开启HTTPS抓包。\n'
                              '点击HTTPS抓包(加锁图标)，选择安装根证书，按照提示操作即可。\n\n'
                              '1. 新增多选功能，支持批量删除、导出、重放；\n'
                              '2. 增强请求重写，支持目标请求失败时自动重写；\n'
                              '3. 新增最小化到托盘功能；\n'
                              '4. 修复 macOS 退出后端口号占用问题；\n'
                              '5. Windows 系统关闭系统代理时自动清理；\n'
                              '6. 优化 Android 应用过滤列表的图标加载与缓存；\n'
                              '7. 优化请求菜单，新增 Copy as fetch 等剪贴板相关操作；\n'
                              '8. 服务上报新增分离式 report server 模式；\n'
                          : 'Note: HTTPS capture is disabled by default — please install the certificate before enabling HTTPS capture.\n'
                              'Click the HTTPS capture (lock) icon, choose "Install Root Certificate", and follow the prompts to complete installation.\n\n'
                              '1. Added multi-select support for batch delete, export, and replay;\n'
                              '2. Improved request rewrite, supporting automatic rewrite when the target request fails;\n'
                              '3. Added minimize to tray support;\n'
                              '4. Fixed the port occupation issue after macOS exit;\n'
                              '5. Added automatic system proxy cleanup when disabling system proxy on Windows;\n'
                              '6. Optimized app icon loading and caching in Android app filter list;\n'
                              '7. Optimized the request menu with clipboard actions such as Copy as fetch;\n'
                              '8. Added a separated report server mode for reporting service;\n',
                      style: const TextStyle(fontSize: 14))));
        });
  }
}
