import 'package:proxypin/network/http/http.dart';

/// MCP 断点拦截队列
///
/// 当 [RequestBreakpointInterceptor] 命中断点规则时，除了打开 UI 窗口，
/// 同时把挂起信息写入此队列，供 MCP Tool 查询和放行。
///
/// 使用流程：
///   1. AI 调用 `add_breakpoint` 添加规则
///   2. ProxyPin 捕获到匹配请求 → 拦截器调用 [addPendingRequest] / [addPendingResponse]
///   3. AI 调用 `get_pending_intercepts` 查看队列
///   4. AI 调用 `release_intercept`（可携带修改后数据）→ 放行
class McpInterceptQueue {
  static final McpInterceptQueue instance = McpInterceptQueue._();
  McpInterceptQueue._();

  final Map<String, _PendingItem> _pending = {};

  // ── 写入 ──────────────────────────────────────────────────────────────────

  void addPendingRequest(String requestId, HttpRequest request) {
    _pending[requestId] = _PendingItem(
      type: 'request',
      requestId: requestId,
      pausedAt: DateTime.now(),
      requestJson: request.toJson(),
    );
  }

  void addPendingResponse(String requestId, HttpRequest request, HttpResponse response) {
    _pending[requestId] = _PendingItem(
      type: 'response',
      requestId: requestId,
      pausedAt: DateTime.now(),
      requestJson: request.toJson(),
      responseJson: response.toJson(),
    );
  }

  void remove(String requestId) => _pending.remove(requestId);

  // ── 查询 ──────────────────────────────────────────────────────────────────

  bool hasPending(String requestId) => _pending.containsKey(requestId);

  String? getPendingType(String requestId) => _pending[requestId]?.type;

  /// 返回队列快照（含 request/response JSON，供 AI 读取后修改再放行）
  List<Map<String, dynamic>> getPendingList() => _pending.values.map((e) => e.toJson()).toList();

  /// 按 requestId 获取原始 JSON（用于 release_intercept 重建对象）
  Map<String, dynamic>? getRawRequestJson(String requestId) => _pending[requestId]?.requestJson;

  Map<String, dynamic>? getRawResponseJson(String requestId) => _pending[requestId]?.responseJson;
}

class _PendingItem {
  final String type; // 'request' | 'response'
  final String requestId;
  final DateTime pausedAt;
  final Map<String, dynamic> requestJson;
  final Map<String, dynamic>? responseJson;

  _PendingItem({
    required this.type,
    required this.requestId,
    required this.pausedAt,
    required this.requestJson,
    this.responseJson,
  });

  Map<String, dynamic> toJson() => {
        'requestId': requestId,
        'type': type,
        'pausedAt': pausedAt.toIso8601String(),
        'waitingSeconds': DateTime.now().difference(pausedAt).inSeconds,
        'request': requestJson,
        if (responseJson != null) 'response': responseJson,
      };
}
