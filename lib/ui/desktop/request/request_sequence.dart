/*
 * Copyright 2023 Hongen Wang
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
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/ui/component/multi_select_controller.dart';
import 'package:proxypin/ui/component/utils.dart';
import 'package:proxypin/ui/desktop/request/request.dart';
import 'package:proxypin/utils/keyword_highlight.dart';
import 'package:proxypin/utils/listenable_list.dart';

import '../../component/model/search_model.dart';

///请求序列 列表
/// @author wanghongen
class RequestSequence extends StatefulWidget {
  final ListenableList<HttpRequest> container;
  final ProxyServer proxyServer;
  final bool displayDomain;
  final Function(List<HttpRequest>)? onRemove;
  final MultiSelectController selectionController;
  final RequestSelectionHandlers selectionHandlers;
  final bool Function(HttpRequest request) requestFilter;

  const RequestSequence(
      {super.key,
      required this.container,
      required this.proxyServer,
      this.displayDomain = true,
      this.onRemove,
      required this.requestFilter,
      required this.selectionController,
      required this.selectionHandlers});

  @override
  State<StatefulWidget> createState() {
    return RequestSequenceState();
  }
}

class RequestSequenceState extends State<RequestSequence> with AutomaticKeepAliveClientMixin {
  late Configuration configuration;

  ///显示的请求列表 最新的在前面
  List<HttpRequest> view = [];
  final Map<String, GlobalKey> rowKeys = <String, GlobalKey>{};
  bool changing = false;

  bool sortDesc = true;

  // 滚动期间隐藏右侧图标的列表长度阈值（含 50）
  static const int iconHiddenThreshold = 50;

  // 滚动停止后恢复 trailing 的延迟，容忍惯性滚动
  static const Duration scrollStopDelay = Duration(milliseconds: 150);

  // 当前是否处于滚动状态
  bool _isScrolling = false;
  Timer? _scrollEndTimer;

  /// 列表右侧图标（应用进程图标）是否应该展示。
  /// - 列表长度 <= [iconHiddenThreshold]：始终展示
  /// - 列表长度 > [iconHiddenThreshold]：仅在 [isScrolling] 为 false 时展示
  @visibleForTesting
  static bool shouldShowTrailing(int viewLength, bool isScrolling) {
    return viewLength <= iconHiddenThreshold || !isScrolling;
  }

  AppLocalizations get localizations => AppLocalizations.of(context)!;

  //搜索的内容
  SearchModel? searchModel;

  //关键词高亮监听
  late VoidCallback highlightListener;
  late MultiSelectListener<String> selectionListener;

  MultiSelectController get selectionController => widget.selectionController;

  @override
  void initState() {
    super.initState();
    configuration = widget.proxyServer.configuration;
    view.addAll(widget.container.where(widget.requestFilter));

    highlightListener = () {
      //回调时机在高亮设置页面dispose之后。所以需要在下一帧刷新，否则会报错
      WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
        highlightHandler();
      });
    };
    KeywordHighlights.addListener(highlightListener);

    selectionListener = MultiSelectListener((items) {
      if (!mounted) {
        return;
      }
      _refreshChangedRows(items);
    });
    selectionController.selectedIds.addListener(selectionListener);
  }

  void changeState() {
    //防止频繁刷新
    if (!changing) {
      changing = true;
      Future.delayed(const Duration(milliseconds: 500), () {
        setState(() {
          changing = false;
        });
      });
    }
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _scrollEndTimer?.cancel();
    selectionController.selectedIds.removeListener(selectionListener);
    KeywordHighlights.removeListener(highlightListener);
    super.dispose();
  }

  /// 处理 Scrollable 抛出的滚动事件。
  /// 返回 false 让事件继续冒泡给其他监听者。
  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification || notification is ScrollUpdateNotification) {
      if (!_isScrolling) {
        setState(() => _isScrolling = true);
      }
      _scrollEndTimer?.cancel();
    } else if (notification is ScrollEndNotification) {
      _scrollEndTimer?.cancel();
      _scrollEndTimer = Timer(scrollStopDelay, () {
        if (!mounted) return;
        setState(() => _isScrolling = false);
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return NotificationListener<ScrollNotification>(
      onNotification: _handleScrollNotification,
      child: ListView.separated(
        cacheExtent: 1000,
        separatorBuilder: (context, index) => Divider(thickness: 0.2, height: 0, color: Theme.of(context).dividerColor),
        itemCount: view.length,
        itemBuilder: (context, index) {
          final physicalIndex = sortDesc ? view.length - index - 1 : index;
          final request = view[physicalIndex];
          final requestId = request.requestId;
          final key = rowKeys.putIfAbsent(requestId, () => GlobalKey());
          return RequestWidget(
            key: key,
            request,
            index: sortDesc ? view.length - index : index,
            trailing: appIcon(request),
            proxyServer: widget.proxyServer,
            displayDomain: widget.displayDomain,
            multiSelectController: selectionController,
            selectionHandlers: widget.selectionHandlers,
            remove: (requestWidget) {
              setState(() {
                view.remove(requestWidget.request);
                rowKeys.remove(requestWidget.request.requestId);
                widget.onRemove?.call([requestWidget.request]);
              });
            },
          );
        },
      ),
    );
  }

  Widget? appIcon(HttpRequest request) {
    var processInfo = request.processInfo;
    if (processInfo == null) {
      return null;
    }
    if (!shouldShowTrailing(view.length, _isScrolling)) {
      return null;
    }

    return futureWidget(
        processInfo.getIcon(),
        (data) => data.isEmpty
            ? const SizedBox()
            : Image.memory(
                data,
                width: 23,
                height: Platform.isWindows ? 16 : null,
                errorBuilder: (BuildContext context, Object error, StackTrace? stackTrace) => const SizedBox(),
              ));
  }

  ///高亮处理
  void highlightHandler() {
    setState(() {});
  }

  ///添加请求
  void add(HttpRequest request) {
    ///过滤
    if (!widget.requestFilter(request) ||
        (searchModel?.isNotEmpty == true && !searchModel!.filter(request, request.response))) {
      return;
    }

    view.add(request);

    rowKeys.putIfAbsent(request.requestId, () => GlobalKey());

    changeState();
  }

  void addBatch(Iterable<HttpRequest> requests) {
    var changed = false;
    for (final request in requests) {
      if (!widget.requestFilter(request) ||
          (searchModel?.isNotEmpty == true && !searchModel!.filter(request, request.response))) {
        continue;
      }
      view.add(request);
      rowKeys.putIfAbsent(request.requestId, () => GlobalKey());
      changed = true;
    }
    if (changed) changeState();
  }

  ///添加响应
  void addResponse(HttpResponse response) {
    if (response.request != null && !widget.requestFilter(response.request!)) {
      return;
    }
    if (searchModel == null || searchModel!.isEmpty || response.request == null) {
      changeState();
      return;
    }

    //搜索视图
    if (searchModel?.filter(response.request!, response) == true) {
      if (!view.contains(response.request)) {
        view.add(response.request!);
        rowKeys.putIfAbsent(response.request!.requestId, () => GlobalKey());
        changeState();
      }
    }
  }

  void addResponses(Iterable<HttpResponse> responses) {
    var changed = false;
    for (final response in responses) {
      if (response.request != null && !widget.requestFilter(response.request!)) {
        continue;
      }
      if (searchModel == null || searchModel!.isEmpty || response.request == null) {
        changed = true;
        continue;
      }
      if (searchModel!.filter(response.request!, response) && !view.contains(response.request)) {
        view.add(response.request!);
        rowKeys.putIfAbsent(response.request!.requestId, () => GlobalKey());
        changed = true;
      }
    }
    if (changed) changeState();
  }

  ///过滤
  void search(SearchModel searchModel) {
    this.searchModel = searchModel;
    _rebuildFilteredView();
  }

  void applyRequestFilter() {
    _rebuildFilteredView();
  }

  void _rebuildFilteredView() {
    view = widget.container.where((request) {
      if (!widget.requestFilter(request)) return false;
      return searchModel?.isNotEmpty != true || searchModel!.filter(request, request.response);
    }).toList();
    final visibleIds = view.map((request) => request.requestId).toSet();
    rowKeys.removeWhere((requestId, _) => !visibleIds.contains(requestId));
    selectionController.prune(view.map((request) => request.requestId));
    setState(() {});
  }

  void remove(List<HttpRequest> list) {
    final removed = list.toSet();
    setState(() {
      view.removeWhere(removed.contains);
      for (final request in list) {
        rowKeys.remove(request.requestId);
      }
    });
  }

  void clean() {
    setState(() {
      view.clear();
      rowKeys.clear();
      view.addAll(widget.container.where(widget.requestFilter));
    });
  }

  void selectRange(HttpRequest request) {
    setState(() {
      final visible = sortDesc ? view.reversed : view;
      selectionController.selectRange(visible.map((item) => item.requestId).toList(), request.requestId);
    });
  }

  ///排序
  void sort(bool desc) {
    sortDesc = desc;
    setState(() {});
  }

  void _refreshChangedRows(List<String> changedIds) {
    if (changedIds.isEmpty) {
      return;
    }

    for (final requestId in changedIds) {
      final key = rowKeys[requestId];
      key?.currentState?.setState(() {});
    }
  }
}
