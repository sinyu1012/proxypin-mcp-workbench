/*
 * Copyright 2024 Hongen Wang All rights reserved.
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
import 'dart:convert';
import 'dart:io' as io;

import 'package:proxypin/network/http/http.dart' as http;
import 'package:proxypin/network/mcp/mcp_tools.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/utils/listenable_list.dart';

/// MCP (Model Context Protocol) Server
/// 提供 SSE 传输的 MCP 服务，让外部 AI 工具能够访问抓包数据
/// @author ProxyPin
class McpServer {
  static const Set<String> _allowedToolNames = {
    'get_request_list',
    'get_request_detail',
    'get_request_stats',
    'search_requests',
    'get_request_body',
    'analyze_encrypted_content',
    'get_domain_summary',
    'get_cookie_info',
    'compare_requests',
    'generate_code',
    'list_breakpoints',
    'get_pending_intercepts',
    'list_rewrite_rules',
    'add_rewrite_rule',
    'remove_rewrite_rule',
    'list_scripts',
    'get_script_content',
    'find_sensitive_data',
    'analyze_auth',
    'extract_api_endpoints',
    'start_capture',
    'stop_capture',
    'diagnose_mock',
    'get_api_catalog',
    'preview_data_export',
    'list_capture_projects',
    'start_capture_project',
    'stop_capture_project',
    'list_mock_scenarios',
    'activate_mock_scenario',
    'run_connection_doctor',
  };

  static McpServer? _instance;
  io.HttpServer? _server;
  int _port;
  bool _running = false;

  /// SSE 客户端连接列表
  final List<_SseClient> _sseClients = [];

  /// 抓包数据源引用
  ListenableList<http.HttpRequest>? _requestContainer;

  McpServer._({int port = 9101}) : _port = port;

  static McpServer get instance {
    _instance ??= McpServer._();
    return _instance!;
  }

  bool get isRunning => _running;
  int get port => _port;

  static List<Map<String, dynamic>> get allowedToolDefinitions =>
      McpTools.getToolDefinitions().where((tool) => _allowedToolNames.contains(tool['name'])).toList(growable: false);

  set port(int value) {
    if (value <= 0 || value >= 65536) {
      throw ArgumentError.value(value, 'port', '必须介于 1 和 65535 之间');
    }
    _port = value;
  }

  /// 绑定抓包数据容器
  void bindRequestContainer(ListenableList<http.HttpRequest> container) {
    _requestContainer = container;
  }

  ListenableList<http.HttpRequest>? get requestContainer => _requestContainer;

  /// 启动 MCP Server
  /// 如果指定端口被占用，会自动尝试递增端口（最多尝试 10 次）
  Future<void> start() async {
    if (_running) return;

    // 确保旧实例已关闭
    if (_server != null) {
      await stop();
    }

    // 尝试绑定端口，失败则自动递增
    int attempts = 0;
    const maxAttempts = 10;
    int tryPort = _port;

    while (attempts < maxAttempts) {
      try {
        _server = await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, tryPort);
        _port = tryPort;
        _running = true;
        logger.i('MCP Server started on port $_port');

        _server!.listen((io.HttpRequest httpRequest) {
          _handleRequest(httpRequest);
        }, onError: (error) {
          logger.e('MCP Server error: $error');
        });
        return;
      } catch (e) {
        attempts++;
        if (attempts >= maxAttempts) {
          logger.e('Failed to start MCP Server after $maxAttempts attempts: $e');
          rethrow;
        }
        logger.w('Port $tryPort is in use, trying port ${tryPort + 1}...');
        tryPort++;
      }
    }
  }

  /// 停止 MCP Server
  Future<void> stop() async {
    if (!_running) return;

    // 关闭所有 SSE 连接
    for (var client in _sseClients) {
      client.close();
    }
    _sseClients.clear();

    await _server?.close(force: true);
    _server = null;
    _running = false;
    logger.i('MCP Server stopped');
  }

  /// 处理 HTTP 请求路由
  void _handleRequest(io.HttpRequest request) {
    final path = request.uri.path;
    final method = request.method;

    if (method == 'OPTIONS') {
      request.response
        ..statusCode = io.HttpStatus.methodNotAllowed
        ..close();
      return;
    }

    if (path == '/sse' && method == 'GET') {
      _handleSseConnection(request);
    } else if (path == '/message' && method == 'POST') {
      _handleMessage(request);
    } else if (path == '/health' && method == 'GET') {
      _handleHealth(request);
    } else {
      request.response
        ..statusCode = io.HttpStatus.notFound
        ..write(jsonEncode({'error': 'Not Found'}))
        ..close();
    }
  }

  /// 健康检查端点
  void _handleHealth(io.HttpRequest request) {
    request.response
      ..statusCode = io.HttpStatus.ok
      ..headers.contentType = io.ContentType.json
      ..write(jsonEncode({
        'status': 'ok',
        'server': 'ProxyPin MCP Server',
        'version': '1.0.0',
        'bindAddress': io.InternetAddress.loopbackIPv4.address,
        'mode': 'mock-automation',
        'requestCount': _requestContainer?.length ?? 0,
      }))
      ..close();
  }

  /// 处理 SSE 连接
  void _handleSseConnection(io.HttpRequest request) {
    final response = request.response;
    response.statusCode = io.HttpStatus.ok;
    response.headers.set('Content-Type', 'text/event-stream; charset=utf-8');
    response.headers.set('Cache-Control', 'no-cache');
    response.headers.set('Connection', 'keep-alive');
    response.bufferOutput = false;

    final sessionId = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final messageEndpoint = 'http://${request.requestedUri.host}:$_port/message?sessionId=$sessionId';

    final client = _SseClient(sessionId, response);
    _sseClients.add(client);

    logger.i('MCP SSE client connected: $sessionId, endpoint: $messageEndpoint');

    // 发送 endpoint 事件
    client.sendEvent('endpoint', messageEndpoint);

    // 心跳保活
    client.startHeartbeat();

    // 监听连接关闭
    request.response.done.then((_) {
      _sseClients.remove(client);
      client.close();
      logger.i('MCP SSE client disconnected: $sessionId');
    }).catchError((e) {
      _sseClients.remove(client);
      client.close();
    });
  }

  /// 处理 MCP JSON-RPC 消息
  Future<void> _handleMessage(io.HttpRequest request) async {
    try {
      final body = await utf8.decoder.bind(request).join();
      final json = jsonDecode(body) as Map<String, dynamic>;

      final sessionId = request.uri.queryParameters['sessionId'];
      final client = _sseClients.firstWhere(
        (c) => c.sessionId == sessionId,
        orElse: () => _SseClient('', request.response),
      );

      final jsonRpcResponse = await _handleJsonRpc(json);

      // 通过 SSE 发送响应
      if (client.sessionId.isNotEmpty) {
        client.sendEvent('message', jsonEncode(jsonRpcResponse));
      }

      // 同时在 HTTP 响应中返回
      request.response
        ..statusCode = io.HttpStatus.ok
        ..headers.contentType = io.ContentType.json
        ..write(jsonEncode(jsonRpcResponse))
        ..close();
    } catch (e) {
      logger.e('MCP message handling error: $e');
      request.response
        ..statusCode = io.HttpStatus.badRequest
        ..headers.contentType = io.ContentType.json
        ..write(jsonEncode({
          'jsonrpc': '2.0',
          'error': {'code': -32700, 'message': 'Parse error: $e'},
          'id': null,
        }))
        ..close();
    }
  }

  /// 处理 JSON-RPC 方法调用
  Future<Map<String, dynamic>> _handleJsonRpc(Map<String, dynamic> request) async {
    final method = request['method'] as String?;
    final id = request['id'];
    final params = request['params'] as Map<String, dynamic>? ?? {};

    switch (method) {
      case 'initialize':
        return _buildResponse(id, {
          'protocolVersion': '2024-11-05',
          'capabilities': {
            'tools': {},
          },
          'serverInfo': {
            'name': 'proxypin-mcp-server',
            'version': '1.0.0',
          },
        });

      case 'notifications/initialized':
        return _buildResponse(id, {});

      case 'tools/list':
        return _buildResponse(id, {
          'tools': allowedToolDefinitions,
        });

      case 'tools/call':
        final toolName = params['name'] as String?;
        if (toolName == null || !_allowedToolNames.contains(toolName)) {
          return _buildResponse(id, _toolErrorResult('Mock 自动化模式未开放工具: ${toolName ?? ''}'));
        }
        final arguments = params['arguments'] as Map<String, dynamic>? ?? {};
        final result = await McpTools.callTool(toolName, arguments, _requestContainer);
        return _buildResponse(id, result);

      case 'ping':
        return _buildResponse(id, {});

      default:
        return {
          'jsonrpc': '2.0',
          'error': {'code': -32601, 'message': 'Method not found: $method'},
          'id': id,
        };
    }
  }

  Map<String, dynamic> _buildResponse(dynamic id, Map<String, dynamic> result) {
    return {
      'jsonrpc': '2.0',
      'result': result,
      'id': id,
    };
  }

  Map<String, dynamic> _toolErrorResult(String message) {
    return {
      'content': [
        {'type': 'text', 'text': message}
      ],
      'isError': true,
    };
  }
}

/// SSE 客户端连接
class _SseClient {
  final String sessionId;
  final io.HttpResponse _response;
  Timer? _heartbeat;
  bool _closed = false;

  _SseClient(this.sessionId, this._response);

  /// 发送 SSE 事件
  void sendEvent(String event, String data) {
    if (_closed) return;
    try {
      _response.write('event: $event\ndata: $data\n\n');
      _response.flush();
    } catch (e) {
      // 连接已关闭
    }
  }

  /// 启动心跳
  void startHeartbeat() {
    _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!_closed) {
        try {
          _response.write(':heartbeat\n\n');
          _response.flush();
        } catch (e) {
          close();
        }
      }
    });
  }

  /// 关闭连接
  void close() {
    _closed = true;
    _heartbeat?.cancel();
    try {
      _response.close();
    } catch (_) {}
  }
}
