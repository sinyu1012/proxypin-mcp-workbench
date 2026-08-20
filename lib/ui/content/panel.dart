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

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/ui/component/state_component.dart';
import 'package:proxypin/ui/component/utils.dart';
import 'package:proxypin/ui/content/web_socket.dart';
import 'package:proxypin/utils/lang.dart';
import 'package:proxypin/utils/platform.dart';

import 'body.dart';
import 'headers.dart';
import 'menu.dart';
import 'mock_diagnostics.dart';

///网络请求详情页
///@Author: wanghongen
class NetworkTabController extends StatefulWidget {
  static GlobalKey<NetworkTabState>? currentKey;
  final int? windowId;
  final ProxyServer? proxyServer;
  final ValueWrap<HttpRequest> request = ValueWrap();
  final ValueWrap<HttpResponse> response = ValueWrap();
  final Widget? title;
  final TextStyle? tabStyle;

  NetworkTabController(
      {HttpRequest? httpRequest,
      HttpResponse? httpResponse,
      this.title,
      this.tabStyle,
      this.proxyServer,
      this.windowId})
      : super(key: GlobalKey<NetworkTabState>()) {
    currentKey = key as GlobalKey<NetworkTabState>;
    request.set(httpRequest);
    response.set(httpResponse);
  }

  void change(HttpRequest? request, HttpResponse? response) {
    this.request.set(request);
    this.response.set(response);
    var state = key as GlobalKey<NetworkTabState>;
    state.currentState?.changeState();
  }

  void changeState() {
    var state = key as GlobalKey<NetworkTabState>;
    state.currentState?.changeState();
  }

  /// 当当前选中请求收到延迟响应时，同步刷新详情右栏。
  void updateResponses(Iterable<HttpResponse> responses) {
    final selectedRequest = request.get();
    if (selectedRequest == null) return;

    for (final candidate in responses) {
      final responseRequest = candidate.request;
      if (identical(responseRequest, selectedRequest) || responseRequest?.requestId == selectedRequest.requestId) {
        response.set(candidate);
        selectedRequest.response = candidate;
        changeState();
        return;
      }
    }
  }

  /// 检查当前实际可见页是否为 SSE/WebSocket。
  bool get isSseTabVisible {
    var state = key as GlobalKey<NetworkTabState>;
    return state.currentState?._isSseTabVisible() ?? false;
  }

  bool isSelectedMessage(HttpMessage message) {
    final selectedRequest = request.get();
    if (selectedRequest == null) return false;
    if (message is HttpRequest) {
      return identical(message, selectedRequest) || message.requestId == selectedRequest.requestId;
    }

    final selectedResponse = response.get() ?? selectedRequest.response;
    final messageResponse = message as HttpResponse;
    return identical(messageResponse, selectedResponse) ||
        messageResponse.requestId == selectedResponse?.requestId ||
        messageResponse.request?.requestId == selectedRequest.requestId;
  }

  /// 更新 panel 的 request 和 response（用于 SSE/WebSocket 消息自动刷新）
  void updateForStreamMessage(HttpMessage message) {
    if (!isSelectedMessage(message)) return;
    if (message is HttpRequest) {
      request.set(message);
      if (message.response != null) {
        response.set(message.response);
      }
    } else if (message is HttpResponse) {
      response.set(message);
      if (message.request != null) {
        request.set(message.request);
      }
    }
    // 无论当前是否在 SSE Tab，都更新消息引用
    // 这样当用户切换到 SSE Tab 时，panel 已经包含了正确的消息引用
    changeState();
  }

  @override
  State<StatefulWidget> createState() {
    return NetworkTabState();
  }

  static NetworkTabController? get current => currentKey?.currentWidget as NetworkTabController?;
}

const double _networkDetailSplitBreakpoint = 720;

bool useSplitNetworkDetail(double width, {required bool desktop}) => desktop && width >= _networkDetailSplitBreakpoint;

class NetworkTabState extends State<NetworkTabController> with TickerProviderStateMixin {
  final TextStyle textStyle = const TextStyle(fontSize: 14);
  late final TabController _compactTabController;
  late final TabController _requestPaneTabController;
  bool _wideLayoutActive = false;
  final ScrollController _requestScrollController = ScrollController();
  final ScrollController _responseScrollController = ScrollController();

  final GlobalKey<HttpBodyState> requestHttpBodyKey = GlobalKey<HttpBodyState>();
  final GlobalKey<HttpBodyState> responseHttpBodyKey = GlobalKey<HttpBodyState>();

  void changeState() {
    if (mounted) setState(() {});
  }

  /// 宽屏时流消息入口在左栏，窄屏保持原有第 4 个 Tab。
  bool _isSseTabVisible() {
    return _isStreamMessages &&
        (_wideLayoutActive ? _requestPaneTabController.index == 2 : _compactTabController.index == 3);
  }

  bool get _requestBodyVisible =>
      _wideLayoutActive ? _requestPaneTabController.index == 0 : _compactTabController.index == 1;

  bool get _responseBodyVisible => _wideLayoutActive || _compactTabController.index == 2;

  AppLocalizations get localizations => AppLocalizations.of(context)!;

  @override
  void initState() {
    super.initState();
    _compactTabController = TabController(length: 5, vsync: this);
    _requestPaneTabController = TabController(length: 4, vsync: this);
    _compactTabController.addListener(_hideInactiveSearchOverlays);
    _requestPaneTabController.addListener(_hideInactiveSearchOverlays);

    if (widget.windowId != null) {
      HardwareKeyboard.instance.addHandler(onKeyEvent);
    }
  }

  void _hideInactiveSearchOverlays() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_requestBodyVisible) {
        requestHttpBodyKey.currentState?.hideSearchOverlay();
      }
      if (!_responseBodyVisible) {
        responseHttpBodyKey.currentState?.hideSearchOverlay();
      }
    });
  }

  @override
  void dispose() {
    _compactTabController.dispose();
    _requestPaneTabController.dispose();
    _requestScrollController.dispose();
    _responseScrollController.dispose();
    HardwareKeyboard.instance.removeHandler(onKeyEvent);
    super.dispose();
  }

  bool onKeyEvent(KeyEvent event) {
    if ((HardwareKeyboard.instance.isMetaPressed || HardwareKeyboard.instance.isControlPressed) &&
        event.logicalKey == LogicalKeyboardKey.keyW) {
      HardwareKeyboard.instance.removeHandler(onKeyEvent);
      WindowController.fromWindowId(widget.windowId!).close();
      return true;
    }

    return false;
  }

  @override
  Widget build(BuildContext context) {
    final linkedResponse = widget.request.get()?.response;
    if (linkedResponse != null && widget.response.get() != linkedResponse) {
      widget.response.set(linkedResponse);
    }

    return LayoutBuilder(builder: (context, constraints) {
      final useWideLayout = useSplitNetworkDetail(
        constraints.maxWidth,
        desktop: Platforms.isDesktop(),
      );
      final layoutChanged = _wideLayoutActive != useWideLayout;
      _wideLayoutActive = useWideLayout;
      if (layoutChanged) _hideInactiveSearchOverlays();
      return useWideLayout ? _wideScaffold() : _compactScaffold();
    });
  }

  Widget _contentPadding(Widget child) => Padding(
        padding: const EdgeInsets.only(left: 20, right: 20, top: 10),
        child: child,
      );

  String get _streamTabTitle {
    final response = widget.response.get() ?? widget.request.get()?.response;
    final isSse = response?.headers.contentType.toLowerCase().startsWith('text/event-stream') == true;
    if (isSse) return 'SSE';
    if (widget.request.get()?.isWebSocket == true) return 'WebSocket';
    return 'Cookies';
  }

  bool get _isStreamMessages => _streamTabTitle == 'SSE' || _streamTabTitle == 'WebSocket';

  PreferredSizeWidget? _windowAppBar({PreferredSizeWidget? bottom}) {
    if (widget.title == null) return bottom;
    return AppBar(
      title: widget.title,
      bottom: bottom,
      centerTitle: true,
      actions: [
        ShareWidget(
          proxyServer: widget.proxyServer,
          request: widget.request.get(),
          response: widget.response.get(),
        ),
        const SizedBox(width: 3),
        DetailMenuWidget(request: widget.request.get()),
        const SizedBox(width: 10),
      ],
    );
  }

  Widget _compactScaffold() {
    final tabs = ['General', 'Request', 'Response', _streamTabTitle, 'Mock'];
    final tabBar = TabBar(
      padding: const EdgeInsets.only(bottom: 0),
      controller: _compactTabController,
      isScrollable: true,
      tabAlignment: TabAlignment.start,
      dividerColor: Theme.of(context).dividerColor.withValues(alpha: 0.15),
      labelPadding: const EdgeInsets.symmetric(horizontal: 10),
      tabs: tabs.map((title) => Tab(child: Text(title, style: widget.tabStyle, maxLines: 1))).toList(),
    );

    return Scaffold(
      key: const Key('network-detail-compact'),
      endDrawerEnableOpenDragGesture: false,
      appBar: _windowAppBar(bottom: tabBar),
      body: TabBarView(
        physics: Platforms.isDesktop() ? const NeverScrollableScrollPhysics() : null,
        controller: _compactTabController,
        children: [
          _contentPadding(SelectionArea(child: General(widget.request, widget.response))),
          _contentPadding(KeyedSubtree(
            key: const Key('request-body'),
            child: KeepAliveWrapper(child: request()),
          )),
          _contentPadding(KeyedSubtree(
            key: const Key('response-body'),
            child: KeepAliveWrapper(child: response()),
          )),
          _contentPadding(SelectionArea(child: _streamContent())),
          _contentPadding(MockDiagnosticsPanel(request: widget.request.get())),
        ],
      ),
    );
  }

  Widget _wideScaffold() {
    final request = widget.request.get();
    final response = widget.response.get() ?? request?.response;
    final requestTabs = ['Details', 'General', _streamTabTitle, 'Mock'];

    return Scaffold(
      endDrawerEnableOpenDragGesture: false,
      appBar: _windowAppBar(),
      body: Row(
        key: const Key('network-detail-wide'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _NetworkMessagePane(
              key: const Key('request-pane'),
              title: 'Request',
              badge: request?.method.name.toUpperCase(),
              tabBar: TabBar(
                controller: _requestPaneTabController,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                dividerColor: Colors.transparent,
                padding: EdgeInsets.zero,
                labelPadding: const EdgeInsets.symmetric(horizontal: 10),
                labelStyle: widget.tabStyle ?? const TextStyle(fontSize: 13),
                tabs: requestTabs.map((title) => Tab(text: title)).toList(),
              ),
              child: TabBarView(
                controller: _requestPaneTabController,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  request == null
                      ? const _MessageEmptyState(
                          icon: Icons.north_east_rounded,
                          message: '选择一个请求',
                        )
                      : _panePadding(KeyedSubtree(
                          key: const Key('request-body'),
                          child: KeepAliveWrapper(child: this.request()),
                        )),
                  _panePadding(SelectionArea(child: General(widget.request, widget.response))),
                  _panePadding(SelectionArea(child: _streamContent())),
                  _panePadding(MockDiagnosticsPanel(request: widget.request.get())),
                ],
              ),
            ),
          ),
          VerticalDivider(
            width: 1,
            thickness: 0.6,
            color: Theme.of(context).dividerColor,
          ),
          Expanded(
            child: _NetworkMessagePane(
              key: const Key('response-pane'),
              title: 'Response',
              badge: response?.status.toString(),
              child: response == null
                  ? const _MessageEmptyState(
                      icon: Icons.hourglass_top_rounded,
                      message: '等待响应',
                    )
                  : _panePadding(KeyedSubtree(
                      key: const Key('response-body'),
                      child: KeepAliveWrapper(child: this.response()),
                    )),
            ),
          ),
        ],
      ),
    );
  }

  Widget _panePadding(Widget child) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: child,
      );

  Widget _streamContent() =>
      _isStreamMessages ? Websocket(widget.request, widget.response) : Cookies(widget.request, widget.response);

  Widget request() {
    if (widget.request.get() == null) {
      return const SizedBox();
    }

    var path = widget.request.get()?.path ?? '';
    try {
      path = Uri.decodeFull(path);
    } catch (_) {}

    return SingleChildScrollView(
        controller: _requestScrollController,
        child: Column(children: [
          RowWidget("Path", path),
          RequestParams(widget.request),
          ...message(widget.request.get(), "Request", _requestScrollController)
        ]));
  }

  Widget response() {
    final response = widget.response.get() ?? widget.request.get()?.response;
    if (response == null) {
      return const SizedBox();
    }

    return SingleChildScrollView(
        controller: _responseScrollController,
        child: Column(children: [
          RowWidget("StatusCode", response.status.toString()),
          ...message(response, "Response", _responseScrollController)
        ]));
  }

  List<Widget> message(HttpMessage? message, String type, ScrollController scrollController) {
    Widget bodyWidgets = HttpBodyWidget(
        key: type == "Request" ? requestHttpBodyKey : responseHttpBodyKey,
        hideRequestRewrite: widget.windowId != null,
        httpMessage: message,
        scrollController: scrollController,
        disposeScrollController: false);

    return [HeadersWidget(title: type, message: message, valueTextStyle: textStyle), bodyWidgets];
  }
}

class _NetworkMessagePane extends StatelessWidget {
  final String title;
  final String? badge;
  final PreferredSizeWidget? tabBar;
  final Widget child;

  const _NetworkMessagePane({
    super.key,
    required this.title,
    required this.child,
    this.badge,
    this.tabBar,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          constraints: const BoxConstraints(minHeight: 54),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: theme.dividerColor.withValues(alpha: 0.35),
                width: 0.6,
              ),
            ),
          ),
          child: Row(children: [
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            if (badge?.isNotEmpty == true) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  badge!,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
            if (tabBar != null) ...[
              const SizedBox(width: 10),
              Expanded(child: tabBar!),
            ],
          ]),
        ),
        Expanded(child: child),
      ],
    );
  }
}

class _MessageEmptyState extends StatelessWidget {
  final IconData icon;
  final String message;

  const _MessageEmptyState({required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 34, color: color.withValues(alpha: 0.55)),
          const SizedBox(height: 12),
          Text(message, style: TextStyle(color: color)),
        ],
      ),
    );
  }
}

Widget expansionTile(String title, List<Widget> content,
    {bool initiallyExpanded = true, ValueChanged<bool>? onExpansionChanged}) {
  return ExpansionTile(
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14)),
      tilePadding: const EdgeInsets.only(left: 0),
      expandedAlignment: Alignment.topLeft,
      initiallyExpanded: initiallyExpanded,
      onExpansionChanged: onExpansionChanged,
      shape: const Border(),
      children: content);
}

class RequestParams extends StatelessWidget {
  static bool initiallyExpanded = false;

  final ValueWrap<HttpRequest> request;

  const RequestParams(this.request, {super.key});

  @override
  Widget build(BuildContext context) {
    var request = this.request.get();
    if (request == null) {
      return const SizedBox();
    }
    var params = request.requestUri?.queryParametersAll;
    if (params == null || params.isEmpty) {
      return const SizedBox();
    }
    var content = <Widget>[];
    params.forEach((name, values) {
      for (var val in values) {
        content.add(RowWidget(name, val));
        content.add(const Divider(thickness: 0.1, height: 10));
      }
    });

    return expansionTile("Request Params", content, initiallyExpanded: initiallyExpanded,
        onExpansionChanged: (expanded) {
      //保存展开状态
      initiallyExpanded = expanded;
    });
  }
}

class General extends StatelessWidget {
  final ValueWrap<HttpRequest> request;
  final ValueWrap<HttpResponse> response;

  const General(this.request, this.response, {super.key});

  @override
  Widget build(BuildContext context) {
    var request = this.request.get();
    if (request == null) {
      return const SizedBox();
    }
    var response = this.response.get();
    String requestUrl = request.requestUrl;
    try {
      requestUrl = Uri.decodeFull(request.requestUrl);
    } catch (_) {}
    var content = [
      const SizedBox(height: 10),
      RowWidget("Request URL", requestUrl),
      const SizedBox(height: 15),
      RowWidget("Request Method", request.method.name),
      const SizedBox(height: 15),
      RowWidget("Protocol", request.protocolVersion),
      const SizedBox(height: 15),
      RowWidget("Status Code", response?.status.toString()),
      const SizedBox(height: 15),
      RowWidget("Remote Address",
          '${response?.remoteHost ?? ''}${response?.remotePort == null ? '' : ':${response?.remotePort}'}'),
      const SizedBox(height: 15),
      RowWidget("Request Time", request.requestTime.formatMillisecond()),
      const SizedBox(height: 15),
      RowWidget("Duration", response?.costTime()),
      const SizedBox(height: 15),
      RowWidget("Request Content-Type", request.headers.contentType),
      const SizedBox(height: 15),
      RowWidget("Response Content-Type", response?.headers.contentType),
      const SizedBox(height: 15),
      RowWidget("Request Package", getPackage(request.packageSize)),
      const SizedBox(height: 15),
      RowWidget("Response Package", getPackage(response?.packageSize)),
      const SizedBox(height: 15),
    ];
    if (request.processInfo != null) {
      content.add(RowWidget("App", request.processInfo!.name));
      content.add(const SizedBox(height: 15));
    }

    return ListView(children: [expansionTile("General", content)]);
  }
}

class Cookies extends StatelessWidget {
  final ValueWrap<HttpRequest> request;

  final ValueWrap<HttpResponse> response;

  const Cookies(this.request, this.response, {super.key});

  @override
  Widget build(BuildContext context) {
    var requestCookie = request.get()?.cookies.expand((cookie) => _cookieWidget(cookie)!);

    var responseCookie = response.get()?.headers.getList("Set-Cookie")?.expand((e) => _cookieWidget(e)!);
    return ListView(children: [
      requestCookie == null ? const SizedBox() : expansionTile("Request Cookies", requestCookie.toList()),
      const SizedBox(height: 15),
      responseCookie == null ? const SizedBox() : expansionTile("Response Cookies", responseCookie.toList()),
    ]);
  }

  Iterable<Widget>? _cookieWidget(String? cookie) {
    var headers = <Widget>[];

    cookie?.split(";").map((e) => Strings.splitFirst(e, "=")).where((element) => element != null).forEach((e) {
      headers.add(RowWidget(e!.key.trim(), e.value));
      headers.add(const Divider(thickness: 0.1, height: 10));
    });

    return headers;
  }
}

class RowWidget extends StatelessWidget {
  final String name;
  final String? value;
  final TextStyle textStyle = const TextStyle(fontSize: 14);

  const RowWidget(this.name, this.value, {super.key});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(
          flex: 2,
          child: SelectableText(name,
              contextMenuBuilder: contextMenu,
              style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14, color: Colors.deepOrangeAccent))),
      Expanded(flex: 4, child: SelectableText(contextMenuBuilder: contextMenu, style: textStyle, value ?? ''))
    ]);
  }
}
