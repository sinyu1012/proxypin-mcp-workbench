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

import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';

import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/components/manager/rewrite_rule.dart';
import 'package:proxypin/network/components/manager/request_breakpoint_manager.dart';
import 'package:proxypin/network/components/manager/request_rewrite_manager.dart';
import 'package:proxypin/network/components/manager/script_manager.dart';
import 'package:proxypin/network/components/request_breakpoint.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/mcp/mcp_intercept_queue.dart';
import 'package:proxypin/utils/listenable_list.dart';
import 'package:proxypin/features/workbench/data/api_catalog_service.dart';
import 'package:proxypin/features/workbench/data/connection_doctor_service.dart';
import 'package:proxypin/features/workbench/data/data_export_service.dart';
import 'package:proxypin/features/workbench/logic/capture_project_controller.dart';

/// MCP 工具定义和处理器
/// 提供给 AI 客户端调用的工具集
class McpTools {
  /// 获取所有工具定义
  static List<Map<String, dynamic>> getToolDefinitions() {
    return [
      // ── 基础抓包查询（原有 9 个）────────────────────────────────────────────
      {
        'name': 'get_request_list',
        'description': '获取 ProxyPin 抓包请求列表。返回当前捕获的 HTTP(S) 请求摘要列表，包含请求方法、URL、状态码、耗时等信息。支持按域名过滤、按状态码过滤、分页查询。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'domain': {'type': 'string', 'description': '按域名过滤（模糊匹配），例如 "api.example.com"'},
            'method': {'type': 'string', 'description': '按 HTTP 方法过滤，例如 "GET"、"POST"'},
            'statusCode': {'type': 'integer', 'description': '按响应状态码过滤，例如 200、404、500'},
            'keyword': {'type': 'string', 'description': '按 URL 关键词搜索（模糊匹配）'},
            'offset': {'type': 'integer', 'description': '分页偏移量，默认 0'},
            'limit': {'type': 'integer', 'description': '每页数量，默认 50，最大 200'},
          },
        },
      },
      {
        'name': 'get_request_detail',
        'description': '获取某个抓包请求的完整详情，包括请求头、请求体、响应头、响应体、耗时等完整信息。需要传入请求的 requestId。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'requestId': {'type': 'string', 'description': '请求 ID，从 get_request_list 返回结果中获取'},
            'includeBody': {'type': 'boolean', 'description': '是否包含请求体和响应体内容，默认 true'},
            'maxBodySize': {'type': 'integer', 'description': '响应体最大返回字符数，默认 10000'},
          },
          'required': ['requestId'],
        },
      },
      {
        'name': 'get_request_stats',
        'description': '获取抓包数据的统计摘要，包括总请求数、域名分布、状态码分布、HTTP 方法分布、平均耗时等分析数据。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'domain': {'type': 'string', 'description': '可选，只统计指定域名的请求'},
          },
        },
      },
      {
        'name': 'search_requests',
        'description': '高级搜索抓包请求。支持多条件组合搜索：URL 关键词、请求/响应体内容关键词、Header 关键词、时间范围等。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'urlKeyword': {'type': 'string', 'description': 'URL 中包含的关键词'},
            'bodyKeyword': {'type': 'string', 'description': '请求体或响应体中包含的关键词'},
            'headerKeyword': {'type': 'string', 'description': '请求头或响应头中包含的关键词'},
            'startTime': {'type': 'integer', 'description': '起始时间戳（毫秒）'},
            'endTime': {'type': 'integer', 'description': '结束时间戳（毫秒）'},
            'limit': {'type': 'integer', 'description': '最大返回数量，默认 50'},
          },
        },
      },
      {
        'name': 'get_request_body',
        'description': '单独获取某个请求的请求体或响应体的完整内容。适用于需要查看大体积内容的场景。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'requestId': {'type': 'string', 'description': '请求 ID'},
            'type': {
              'type': 'string',
              'description': '获取类型：request 或 response，默认 response',
              'enum': ['request', 'response']
            },
            'maxSize': {'type': 'integer', 'description': '最大返回字符数，默认 50000'},
          },
          'required': ['requestId'],
        },
      },
      {
        'name': 'analyze_encrypted_content',
        'description': '分析请求或响应中疑似加密/编码的内容。自动检测编码类型（Base64、Hex、URL编码等），尝试常见解码，分析数据特征（熵值、字符分布），推测可能的加密算法。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'requestId': {'type': 'string', 'description': '请求 ID，分析该请求的内容'},
            'type': {
              'type': 'string',
              'description': '分析目标：request、response、both，默认 both',
              'enum': ['request', 'response', 'both']
            },
            'rawContent': {'type': 'string', 'description': '直接传入待分析的内容字符串（与 requestId 二选一）'},
          },
        },
      },
      {
        'name': 'get_domain_summary',
        'description': '按域名分组汇总抓包数据。展示每个域名的请求数量、接口路径列表（去重）、HTTP 方法分布、Content-Type 分布、平均耗时。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'domain': {'type': 'string', 'description': '可选，只查看指定域名的详细信息（模糊匹配）'},
            'topN': {'type': 'integer', 'description': '返回请求数最多的前 N 个域名，默认 20'},
          },
        },
      },
      {
        'name': 'get_cookie_info',
        'description': '提取和分析指定域名的 Cookie 信息。从请求头和响应头中提取 Cookie/Set-Cookie，分析属性（HttpOnly、Secure 等）。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'domain': {'type': 'string', 'description': '目标域名（模糊匹配）'},
          },
          'required': ['domain'],
        },
      },
      {
        'name': 'compare_requests',
        'description': '对比两个请求的差异。比较 URL、Headers、Query 参数、请求体的不同之处。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'requestId1': {'type': 'string', 'description': '第一个请求的 ID'},
            'requestId2': {'type': 'string', 'description': '第二个请求的 ID'},
          },
          'required': ['requestId1', 'requestId2'],
        },
      },

      // ── A. 请求重放与代码生成 ─────────────────────────────────────────────
      {
        'name': 'replay_request',
        'description': '重放某个已捕获的 HTTP 请求。可以在重放时覆盖请求头或请求体进行改包测试。返回实际的响应结果（状态码、响应头、响应体）。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'requestId': {'type': 'string', 'description': '要重放的请求 ID'},
            'headers': {'type': 'object', 'description': '覆盖请求头（键值对），不填则使用原始请求头'},
            'body': {'type': 'string', 'description': '覆盖请求体内容，不填则使用原始请求体'},
            'timeoutSeconds': {'type': 'integer', 'description': '请求超时秒数，默认 30'},
          },
          'required': ['requestId'],
        },
      },
      {
        'name': 'generate_code',
        'description': '根据抓包请求生成可执行的代码片段。支持 Python（requests 库）、JavaScript（fetch API）、cURL 命令、Go 语言。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'requestId': {'type': 'string', 'description': '请求 ID'},
            'language': {
              'type': 'string',
              'description': '目标语言/工具：python、javascript、curl、go，默认 python',
              'enum': ['python', 'javascript', 'curl', 'go'],
            },
          },
          'required': ['requestId'],
        },
      },

      // ── B. 断点拦截（Fiddler 风格改包）────────────────────────────────────
      {
        'name': 'add_breakpoint',
        'description':
            '添加断点拦截规则。匹配的请求/响应将被暂停，AI 可通过 get_pending_intercepts 查看并通过 release_intercept 修改后放行。类似 Fiddler 的断点功能。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'url': {'type': 'string', 'description': 'URL 正则表达式，例如 ".*api/login.*"'},
            'name': {'type': 'string', 'description': '规则名称（可选）'},
            'interceptRequest': {'type': 'boolean', 'description': '是否拦截请求阶段，默认 true'},
            'interceptResponse': {'type': 'boolean', 'description': '是否拦截响应阶段，默认 false'},
            'method': {'type': 'string', 'description': '只匹配特定 HTTP 方法，不填则匹配所有方法'},
          },
          'required': ['url'],
        },
      },
      {
        'name': 'list_breakpoints',
        'description': '列出当前所有断点拦截规则，包含规则索引、启用状态、URL 模式等信息。',
        'inputSchema': {'type': 'object', 'properties': {}},
      },
      {
        'name': 'remove_breakpoint',
        'description': '删除指定索引的断点规则。索引从 list_breakpoints 返回结果中获取。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'index': {'type': 'integer', 'description': '规则索引（0 开始）'},
          },
          'required': ['index'],
        },
      },
      {
        'name': 'get_pending_intercepts',
        'description': '获取当前被断点暂停等待放行的请求/响应列表。返回完整的请求和响应数据，AI 可以查看后决定如何修改再放行。',
        'inputSchema': {'type': 'object', 'properties': {}},
      },
      {
        'name': 'release_intercept',
        'description': '放行被断点拦截的请求或响应（可选携带修改后的内容）。可修改请求头、请求体、响应状态码、响应头、响应体，也可选择直接中止请求。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'requestId': {'type': 'string', 'description': '要放行的请求 ID，从 get_pending_intercepts 获取'},
            'abort': {'type': 'boolean', 'description': '是否中止请求（true = 直接拒绝，不转发给服务器/客户端），默认 false'},
            'headers': {'type': 'object', 'description': '修改/新增请求头或响应头（键值对）'},
            'body': {'type': 'string', 'description': '修改请求体或响应体内容'},
            'statusCode': {'type': 'integer', 'description': '修改响应状态码（仅拦截响应时有效）'},
          },
          'required': ['requestId'],
        },
      },

      // ── C. 重写规则管理 ───────────────────────────────────────────────────
      {
        'name': 'list_rewrite_rules',
        'description': '列出当前所有 HTTP 重写规则（替换请求/响应体、修改 Header、重定向等）。',
        'inputSchema': {'type': 'object', 'properties': {}},
      },
      {
        'name': 'add_rewrite_rule',
        'description':
            '添加 HTTP 重写规则。支持：替换响应体（responseReplace）、替换请求体（requestReplace）、修改请求（requestUpdate）、修改响应（responseUpdate）、重定向（redirect）。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'url': {'type': 'string', 'description': 'URL 匹配模式（支持 * 通配符），例如 "*.api.example.com/v2/user*"'},
            'ruleType': {
              'type': 'string',
              'description': '规则类型',
              'enum': ['requestReplace', 'responseReplace', 'requestUpdate', 'responseUpdate', 'redirect'],
            },
            'name': {'type': 'string', 'description': '规则名称（可选）'},
            'group': {'type': 'string', 'description': 'Mock 合集名称（可选）'},
            'body': {'type': 'string', 'description': '替换的请求体或响应体内容（JSON 字符串等）'},
            'statusCode': {'type': 'integer', 'description': '替换响应状态码（仅 responseReplace 时有效）'},
            'headers': {'type': 'object', 'description': '替换的 Header 键值对'},
            'redirectUrl': {'type': 'string', 'description': '重定向目标 URL（仅 redirect 类型时必填）'},
          },
          'required': ['url', 'ruleType'],
        },
      },
      {
        'name': 'remove_rewrite_rule',
        'description': '删除指定索引的重写规则。索引从 list_rewrite_rules 返回结果中获取。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'index': {'type': 'integer', 'description': '规则索引（0 开始）'},
          },
          'required': ['index'],
        },
      },

      // ── D. JS 脚本管理 ────────────────────────────────────────────────────
      {
        'name': 'list_scripts',
        'description': '列出当前所有 JS 拦截脚本（脚本在每次匹配的请求/响应经过时自动执行）。',
        'inputSchema': {'type': 'object', 'properties': {}},
      },
      {
        'name': 'get_script_content',
        'description': '获取指定脚本的完整 JavaScript 代码。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'index': {'type': 'integer', 'description': '脚本索引，从 list_scripts 获取'},
          },
          'required': ['index'],
        },
      },
      {
        'name': 'create_or_update_script',
        'description': '创建或更新 JS 拦截脚本。脚本需包含 onRequest(context, request) 和 onResponse(context, request, response) 函数。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'name': {'type': 'string', 'description': '脚本名称'},
            'url': {'type': 'string', 'description': 'URL 匹配模式，支持 * 通配符，多个用逗号分隔'},
            'script': {'type': 'string', 'description': 'JavaScript 脚本代码'},
            'index': {'type': 'integer', 'description': '要更新的脚本索引（不填则创建新脚本）'},
          },
          'required': ['name', 'url', 'script'],
        },
      },

      // ── E. 安全分析 ───────────────────────────────────────────────────────
      {
        'name': 'find_sensitive_data',
        'description': '扫描抓包数据中的敏感信息：手机号、身份证、邮箱、JWT Token、Bearer Token、API Key、密码字段、IP 地址等。适用于安全测试和数据泄漏检查。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'domain': {'type': 'string', 'description': '只扫描指定域名的请求（模糊匹配），不填则扫描所有'},
            'requestId': {'type': 'string', 'description': '只扫描指定 requestId 的请求（与 domain 二选一）'},
          },
        },
      },
      {
        'name': 'analyze_auth',
        'description':
            '提取和分析认证相关信息：Authorization Header、Bearer Token、API Key Header、Cookie 中的 Session Token 等。帮助逆向分析认证机制。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'domain': {'type': 'string', 'description': '目标域名（模糊匹配），不填则分析所有'},
          },
        },
      },
      {
        'name': 'extract_api_endpoints',
        'description': '提取并归组 API 端点结构。将路径中的 ID、UUID 等替换为占位符，统计每个接口的调用次数、状态码分布、Content-Type。适用于逆向分析 API 设计。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'domain': {'type': 'string', 'description': '目标域名（模糊匹配），不填则分析所有'},
          },
        },
      },

      // ── F. 抓包控制 ───────────────────────────────────────────────────────
      {
        'name': 'start_capture',
        'description': '启动 ProxyPin 抓包服务。开启后系统代理会被设置，ProxyPin 将开始监听并捕获所有 HTTP(S) 流量。',
        'inputSchema': {'type': 'object', 'properties': {}},
      },
      {
        'name': 'stop_capture',
        'description': '停止 ProxyPin 抓包服务。停止后将不再捕获新的请求，已捕获的请求仍保留在列表中。',
        'inputSchema': {'type': 'object', 'properties': {}},
      },
      {
        'name': 'clear_requests',
        'description': '清空当前已捕获的所有请求列表。会移除容器中的全部请求数据，注意该操作不可恢复。',
        'inputSchema': {'type': 'object', 'properties': {}},
      },
      {
        'name': 'diagnose_mock',
        'description': '解释指定请求为什么命中或没有命中 Mock 规则，返回总开关、合集、规则、类型、Method、URL 和优先级检查结果。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'requestId': {'type': 'string', 'description': '请求 ID'},
          },
          'required': ['requestId'],
        },
      },
      {
        'name': 'get_api_catalog',
        'description': '生成当前抓包的 API 资产目录，包含归一化路径、字段、鉴权信号、分页信号和调用统计。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'limit': {'type': 'integer', 'description': '最多返回多少个接口，默认 100'},
          },
        },
      },
      {
        'name': 'preview_data_export',
        'description': '从已抓取的分页响应中自动定位记录数组、合并去重、展平字段并返回脱敏预览，不向远端发请求。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'endpointKey': {'type': 'string', 'description': 'get_api_catalog 返回的接口 key'},
            'sampleSize': {'type': 'integer', 'description': '预览记录数量，默认 3，最大 20'},
          },
          'required': ['endpointKey'],
        },
      },
      {
        'name': 'list_capture_projects',
        'description': '列出抓包项目及其状态、请求数、域名数和写盘进度。',
        'inputSchema': {'type': 'object', 'properties': {}},
      },
      {
        'name': 'start_capture_project',
        'description': '开始新的本地抓包项目；如果已有活动项目，会先结束并保存旧项目。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'name': {'type': 'string', 'description': '项目名称'}
          },
          'required': ['name'],
        },
      },
      {
        'name': 'stop_capture_project',
        'description': '结束当前抓包项目，强制完成写盘并保存在历史记录中。',
        'inputSchema': {'type': 'object', 'properties': {}},
      },
      {
        'name': 'list_mock_scenarios',
        'description': '列出 Mock 场景合集、启用状态、规则数量、命中次数和重复规则冲突。',
        'inputSchema': {'type': 'object', 'properties': {}},
      },
      {
        'name': 'activate_mock_scenario',
        'description': '独占启用一个 Mock 场景，同时关闭其他场景合集，避免不同业务状态互相覆盖。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'name': {'type': 'string', 'description': '场景合集名称'}
          },
          'required': ['name'],
        },
      },
      {
        'name': 'run_connection_doctor',
        'description': '诊断代理服务、端口、局域网地址、HTTPS、证书和最近流量链路。',
        'inputSchema': {'type': 'object', 'properties': {}},
      },
    ];
  }

  /// 调用工具
  static Future<Map<String, dynamic>> callTool(
      String toolName, Map<String, dynamic> arguments, ListenableList<HttpRequest>? container) async {
    if (container == null) {
      return _toolError('抓包数据容器未初始化，请先打开抓包页面');
    }

    switch (toolName) {
      // 原有工具
      case 'get_request_list':
        return _getRequestList(arguments, container);
      case 'get_request_detail':
        return _getRequestDetail(arguments, container);
      case 'get_request_stats':
        return _getRequestStats(arguments, container);
      case 'search_requests':
        return _searchRequests(arguments, container);
      case 'get_request_body':
        return _getRequestBody(arguments, container);
      case 'analyze_encrypted_content':
        return _analyzeEncryptedContent(arguments, container);
      case 'get_domain_summary':
        return _getDomainSummary(arguments, container);
      case 'get_cookie_info':
        return _getCookieInfo(arguments, container);
      case 'compare_requests':
        return _compareRequests(arguments, container);
      // A. 重放与代码生成
      case 'replay_request':
        return _replayRequest(arguments, container);
      case 'generate_code':
        return _generateCode(arguments, container);
      // B. 断点拦截
      case 'add_breakpoint':
        return _addBreakpoint(arguments);
      case 'list_breakpoints':
        return _listBreakpoints();
      case 'remove_breakpoint':
        return _removeBreakpoint(arguments);
      case 'get_pending_intercepts':
        return _getPendingIntercepts();
      case 'release_intercept':
        return _releaseIntercept(arguments);
      // C. 重写规则
      case 'list_rewrite_rules':
        return _listRewriteRules();
      case 'add_rewrite_rule':
        return _addRewriteRule(arguments);
      case 'remove_rewrite_rule':
        return _removeRewriteRule(arguments);
      // D. 脚本管理
      case 'list_scripts':
        return _listScripts();
      case 'get_script_content':
        return _getScriptContent(arguments);
      case 'create_or_update_script':
        return _createOrUpdateScript(arguments);
      // E. 安全分析
      case 'find_sensitive_data':
        return _findSensitiveData(arguments, container);
      case 'analyze_auth':
        return _analyzeAuth(arguments, container);
      case 'extract_api_endpoints':
        return _extractApiEndpoints(arguments, container);
      // F. 抓包控制
      case 'start_capture':
        return _startCapture();
      case 'stop_capture':
        return _stopCapture();
      case 'clear_requests':
        return _clearRequests(container);
      case 'diagnose_mock':
        return _diagnoseMock(arguments, container);
      case 'get_api_catalog':
        return _getApiCatalog(arguments, container);
      case 'preview_data_export':
        return _previewDataExport(arguments, container);
      case 'list_capture_projects':
        return _listCaptureProjects(container);
      case 'start_capture_project':
        return _startCaptureProject(arguments, container);
      case 'stop_capture_project':
        return _stopCaptureProject(container);
      case 'list_mock_scenarios':
        return _listMockScenarios();
      case 'activate_mock_scenario':
        return _activateMockScenario(arguments);
      case 'run_connection_doctor':
        return _runConnectionDoctor(container);
      default:
        return _toolError('未知工具: $toolName');
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 原有工具实现（保持不变）
  // ══════════════════════════════════════════════════════════════════════════

  static Map<String, dynamic> _getRequestList(Map<String, dynamic> args, ListenableList<HttpRequest> container) {
    final domain = args['domain'] as String?;
    final method = args['method'] as String?;
    final statusCode = args['statusCode'] as int?;
    final keyword = args['keyword'] as String?;
    final offset = (args['offset'] as int?) ?? 0;
    var limit = (args['limit'] as int?) ?? 50;
    if (limit > 200) limit = 200;

    var requests = container.source.toList();

    if (domain != null && domain.isNotEmpty) {
      requests = requests.where((r) {
        final host = r.remoteDomain() ?? '';
        return host.toLowerCase().contains(domain.toLowerCase());
      }).toList();
    }
    if (method != null && method.isNotEmpty) {
      requests = requests.where((r) => r.method.name == method.toUpperCase()).toList();
    }
    if (statusCode != null) {
      requests = requests.where((r) => r.response?.status.code == statusCode).toList();
    }
    if (keyword != null && keyword.isNotEmpty) {
      requests = requests.where((r) {
        return r.requestUrl.toLowerCase().contains(keyword.toLowerCase());
      }).toList();
    }

    final total = requests.length;
    final paged = requests.skip(offset).take(limit).toList();

    return _toolResult({
      'total': total,
      'offset': offset,
      'limit': limit,
      'requests': paged.map((r) => _requestSummary(r)).toList(),
    });
  }

  static Map<String, dynamic> _getRequestDetail(Map<String, dynamic> args, ListenableList<HttpRequest> container) {
    final requestId = args['requestId'] as String?;
    if (requestId == null || requestId.isEmpty) return _toolError('requestId 参数不能为空');
    final includeBody = (args['includeBody'] as bool?) ?? true;
    final maxBodySize = (args['maxBodySize'] as int?) ?? 10000;
    final request = _findRequest(requestId, container);
    if (request == null) return _toolError('未找到 requestId=$requestId 的请求');
    return _toolResult(_requestDetail(request, includeBody: includeBody, maxBodySize: maxBodySize));
  }

  static Map<String, dynamic> _getRequestStats(Map<String, dynamic> args, ListenableList<HttpRequest> container) {
    final domain = args['domain'] as String?;
    var requests = container.source.toList();
    if (domain != null && domain.isNotEmpty) {
      requests = requests.where((r) {
        final host = r.remoteDomain() ?? '';
        return host.toLowerCase().contains(domain.toLowerCase());
      }).toList();
    }

    final domainMap = <String, int>{};
    final statusMap = <int, int>{};
    final methodMap = <String, int>{};
    final costTimes = <int>[];

    for (var r in requests) {
      final host = r.remoteDomain() ?? 'unknown';
      domainMap[host] = (domainMap[host] ?? 0) + 1;
      methodMap[r.method.name] = (methodMap[r.method.name] ?? 0) + 1;
      if (r.response != null) {
        final code = r.response!.status.code;
        statusMap[code] = (statusMap[code] ?? 0) + 1;
        final cost = r.response!.responseTime.difference(r.requestTime).inMilliseconds;
        costTimes.add(cost);
      }
    }

    final sortedDomains = domainMap.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

    double avgCost = 0;
    int maxCost = 0;
    int minCost = 0;
    if (costTimes.isNotEmpty) {
      avgCost = costTimes.reduce((a, b) => a + b) / costTimes.length;
      maxCost = costTimes.reduce((a, b) => a > b ? a : b);
      minCost = costTimes.reduce((a, b) => a < b ? a : b);
    }

    return _toolResult({
      'totalRequests': requests.length,
      'withResponse': requests.where((r) => r.response != null).length,
      'withoutResponse': requests.where((r) => r.response == null).length,
      'domainDistribution': Map.fromEntries(sortedDomains.take(20).map((e) => MapEntry(e.key, e.value))),
      'statusCodeDistribution': statusMap.map((k, v) => MapEntry(k.toString(), v)),
      'methodDistribution': methodMap,
      'costTimeStats': {
        'avgMs': avgCost.round(),
        'maxMs': maxCost,
        'minMs': minCost,
        'sampleCount': costTimes.length,
      },
    });
  }

  static Map<String, dynamic> _searchRequests(Map<String, dynamic> args, ListenableList<HttpRequest> container) {
    final urlKeyword = args['urlKeyword'] as String?;
    final bodyKeyword = args['bodyKeyword'] as String?;
    final headerKeyword = args['headerKeyword'] as String?;
    final startTime = args['startTime'] as int?;
    final endTime = args['endTime'] as int?;
    var limit = (args['limit'] as int?) ?? 50;
    if (limit > 200) limit = 200;

    var requests = container.source.toList();

    if (urlKeyword != null && urlKeyword.isNotEmpty) {
      requests = requests.where((r) => r.requestUrl.toLowerCase().contains(urlKeyword.toLowerCase())).toList();
    }
    if (startTime != null) {
      final start = DateTime.fromMillisecondsSinceEpoch(startTime);
      requests = requests.where((r) => r.requestTime.isAfter(start)).toList();
    }
    if (endTime != null) {
      final end = DateTime.fromMillisecondsSinceEpoch(endTime);
      requests = requests.where((r) => r.requestTime.isBefore(end)).toList();
    }
    if (headerKeyword != null && headerKeyword.isNotEmpty) {
      final kw = headerKeyword.toLowerCase();
      requests = requests.where((r) {
        final reqH = r.headers.toRawHeaders().toLowerCase();
        final resH = r.response?.headers.toRawHeaders().toLowerCase() ?? '';
        return reqH.contains(kw) || resH.contains(kw);
      }).toList();
    }
    if (bodyKeyword != null && bodyKeyword.isNotEmpty) {
      final kw = bodyKeyword.toLowerCase();
      requests = requests.where((r) {
        final reqB = r.bodyAsString.toLowerCase();
        final resB = r.response?.bodyAsString.toLowerCase() ?? '';
        return reqB.contains(kw) || resB.contains(kw);
      }).toList();
    }

    final results = requests.take(limit).toList();
    return _toolResult({
      'total': requests.length,
      'returned': results.length,
      'requests': results.map((r) => _requestSummary(r)).toList(),
    });
  }

  static Map<String, dynamic> _getRequestBody(Map<String, dynamic> args, ListenableList<HttpRequest> container) {
    final requestId = args['requestId'] as String?;
    if (requestId == null || requestId.isEmpty) return _toolError('requestId 参数不能为空');
    final type = (args['type'] as String?) ?? 'response';
    final maxSize = (args['maxSize'] as int?) ?? 50000;

    final request = _findRequest(requestId, container);
    if (request == null) return _toolError('未找到 requestId=$requestId 的请求');

    String body;
    String contentType;

    if (type == 'request') {
      body = request.bodyAsString;
      contentType = request.headers.contentType;
    } else {
      if (request.response == null) return _toolError('该请求暂无响应');
      body = request.response!.bodyAsString;
      contentType = request.response!.headers.contentType;
    }

    final truncated = body.length > maxSize;
    if (truncated) body = body.substring(0, maxSize);

    return _toolResult({
      'requestId': requestId,
      'type': type,
      'contentType': contentType,
      'bodyLength': body.length,
      'truncated': truncated,
      'body': body,
    });
  }

  static Map<String, dynamic> _analyzeEncryptedContent(
      Map<String, dynamic> args, ListenableList<HttpRequest> container) {
    final requestId = args['requestId'] as String?;
    final type = (args['type'] as String?) ?? 'both';
    final rawContent = args['rawContent'] as String?;
    final results = <String, dynamic>{};

    if (rawContent != null && rawContent.isNotEmpty) {
      results['rawContentAnalysis'] = _analyzeContent(rawContent);
    } else if (requestId != null && requestId.isNotEmpty) {
      final request = _findRequest(requestId, container);
      if (request == null) return _toolError('未找到 requestId=$requestId 的请求');

      if (type == 'request' || type == 'both') {
        final reqBody = request.bodyAsString;
        results['requestBodyAnalysis'] = reqBody.isNotEmpty ? _analyzeContent(reqBody) : '请求体为空';
      }
      if (type == 'response' || type == 'both') {
        final respBody = request.response?.bodyAsString ?? '';
        results['responseBodyAnalysis'] = respBody.isNotEmpty ? _analyzeContent(respBody) : '响应体为空';
      }
      results['requestInfo'] = {
        'url': request.requestUrl,
        'method': request.method.name,
        'requestContentType': request.headers.contentType,
        'responseContentType': request.response?.headers.contentType ?? '',
      };
    } else {
      return _toolError('请提供 requestId 或 rawContent 参数');
    }

    return _toolResult(results);
  }

  static Map<String, dynamic> _getDomainSummary(Map<String, dynamic> args, ListenableList<HttpRequest> container) {
    final filterDomain = args['domain'] as String?;
    var topN = (args['topN'] as int?) ?? 20;
    if (topN > 100) topN = 100;

    var requests = container.source.toList();
    if (filterDomain != null && filterDomain.isNotEmpty) {
      requests = requests.where((r) {
        final host = r.remoteDomain() ?? '';
        return host.toLowerCase().contains(filterDomain.toLowerCase());
      }).toList();
    }

    final domainData = <String, Map<String, dynamic>>{};
    for (var r in requests) {
      final host = r.remoteDomain() ?? 'unknown';
      domainData.putIfAbsent(
          host,
          () => {
                'count': 0,
                'paths': <String>{},
                'methods': <String, int>{},
                'contentTypes': <String, int>{},
                'costTimes': <int>[],
                'statusCodes': <int, int>{},
              });
      final d = domainData[host]!;
      d['count'] = (d['count'] as int) + 1;
      (d['paths'] as Set<String>).add(r.path);
      final methods = d['methods'] as Map<String, int>;
      methods[r.method.name] = (methods[r.method.name] ?? 0) + 1;
      final respCt = r.response?.headers.contentType ?? '';
      if (respCt.isNotEmpty) {
        final contentTypes = d['contentTypes'] as Map<String, int>;
        contentTypes[respCt] = (contentTypes[respCt] ?? 0) + 1;
      }
      if (r.response != null) {
        final cost = r.response!.responseTime.difference(r.requestTime).inMilliseconds;
        (d['costTimes'] as List<int>).add(cost);
        final code = r.response!.status.code;
        final sc = d['statusCodes'] as Map<int, int>;
        sc[code] = (sc[code] ?? 0) + 1;
      }
    }

    final sorted = domainData.entries.toList()
      ..sort((a, b) => (b.value['count'] as int).compareTo(a.value['count'] as int));

    final result = <String, dynamic>{};
    for (var entry in sorted.take(topN)) {
      final d = entry.value;
      final costTimes = d['costTimes'] as List<int>;
      final avgCost = costTimes.isEmpty ? 0 : (costTimes.reduce((a, b) => a + b) / costTimes.length).round();
      final paths = (d['paths'] as Set<String>).toList()..sort();
      result[entry.key] = {
        'requestCount': d['count'],
        'uniquePaths': paths.length,
        'paths': paths.take(50).toList(),
        'methods': d['methods'],
        'contentTypes': d['contentTypes'],
        'statusCodes': (d['statusCodes'] as Map<int, int>).map((k, v) => MapEntry(k.toString(), v)),
        'avgCostMs': avgCost,
      };
    }

    return _toolResult({
      'totalDomains': domainData.length,
      'totalRequests': requests.length,
      'domains': result,
    });
  }

  static Map<String, dynamic> _getCookieInfo(Map<String, dynamic> args, ListenableList<HttpRequest> container) {
    final domain = args['domain'] as String?;
    if (domain == null || domain.isEmpty) return _toolError('domain 参数不能为空');

    final requests = container.source.where((r) {
      final host = r.remoteDomain() ?? '';
      return host.toLowerCase().contains(domain.toLowerCase());
    }).toList();

    if (requests.isEmpty) return _toolError('未找到域名包含 "$domain" 的请求');

    final requestCookies = <String, String>{};
    final setCookies = <Map<String, dynamic>>[];

    for (var r in requests) {
      final cookieHeader = r.headers.get('Cookie') ?? r.headers.get('cookie');
      if (cookieHeader != null) {
        for (var pair in cookieHeader.split(';')) {
          pair = pair.trim();
          final eqIdx = pair.indexOf('=');
          if (eqIdx > 0) {
            requestCookies[pair.substring(0, eqIdx).trim()] = pair.substring(eqIdx + 1).trim();
          }
        }
      }

      final sc = r.response?.headers.get('Set-Cookie') ?? r.response?.headers.get('set-cookie');
      if (sc != null) {
        final parts = sc.split(';');
        final nameValue = parts.first.trim();
        final eqIdx = nameValue.indexOf('=');
        if (eqIdx > 0) {
          final cookie = <String, dynamic>{
            'name': nameValue.substring(0, eqIdx).trim(),
            'value': nameValue.substring(eqIdx + 1).trim(),
          };
          for (var i = 1; i < parts.length; i++) {
            final attr = parts[i].trim().toLowerCase();
            if (attr.startsWith('path='))
              cookie['path'] = parts[i].trim().substring(5);
            else if (attr.startsWith('domain='))
              cookie['domain'] = parts[i].trim().substring(7);
            else if (attr.startsWith('expires='))
              cookie['expires'] = parts[i].trim().substring(8);
            else if (attr.startsWith('max-age='))
              cookie['maxAge'] = parts[i].trim().substring(8);
            else if (attr == 'httponly')
              cookie['httpOnly'] = true;
            else if (attr == 'secure')
              cookie['secure'] = true;
            else if (attr.startsWith('samesite=')) cookie['sameSite'] = parts[i].trim().substring(9);
          }
          setCookies.add(cookie);
        }
      }
    }

    return _toolResult({
      'domain': domain,
      'matchedRequests': requests.length,
      'requestCookies': requestCookies,
      'setCookies': setCookies,
      'uniqueCookieNames': {...requestCookies.keys, ...setCookies.map((c) => c['name'] as String)}.toList(),
    });
  }

  static Map<String, dynamic> _compareRequests(Map<String, dynamic> args, ListenableList<HttpRequest> container) {
    final id1 = args['requestId1'] as String?;
    final id2 = args['requestId2'] as String?;
    if (id1 == null || id2 == null) return _toolError('requestId1 和 requestId2 参数不能为空');

    final r1 = _findRequest(id1, container);
    final r2 = _findRequest(id2, container);
    if (r1 == null) return _toolError('未找到 requestId=$id1 的请求');
    if (r2 == null) return _toolError('未找到 requestId=$id2 的请求');

    final diffs = <String, dynamic>{};

    if (r1.requestUrl != r2.requestUrl) diffs['url'] = {'request1': r1.requestUrl, 'request2': r2.requestUrl};
    if (r1.method.name != r2.method.name) diffs['method'] = {'request1': r1.method.name, 'request2': r2.method.name};
    if (r1.response?.status.code != r2.response?.status.code) {
      diffs['statusCode'] = {'request1': r1.response?.status.code, 'request2': r2.response?.status.code};
    }

    final h1 = r1.headers.toMap();
    final h2 = r2.headers.toMap();
    final headerDiffs = <String, dynamic>{};
    final allKeys = {...h1.keys, ...h2.keys};
    for (var key in allKeys) {
      if (h1[key] != h2[key]) headerDiffs[key] = {'request1': h1[key], 'request2': h2[key]};
    }
    if (headerDiffs.isNotEmpty) diffs['requestHeaders'] = headerDiffs;

    final q1 = r1.queries;
    final q2 = r2.queries;
    if (q1.toString() != q2.toString()) diffs['queryParams'] = {'request1': q1, 'request2': q2};

    final b1 = r1.bodyAsString;
    final b2 = r2.bodyAsString;
    if (b1 != b2) {
      diffs['requestBody'] = {
        'request1Length': b1.length,
        'request2Length': b2.length,
        'request1Preview': b1.length > 500 ? '${b1.substring(0, 500)}...' : b1,
        'request2Preview': b2.length > 500 ? '${b2.substring(0, 500)}...' : b2,
      };
    }

    final rb1 = r1.response?.bodyAsString ?? '';
    final rb2 = r2.response?.bodyAsString ?? '';
    if (rb1 != rb2) {
      diffs['responseBody'] = {
        'request1Length': rb1.length,
        'request2Length': rb2.length,
        'request1Preview': rb1.length > 500 ? '${rb1.substring(0, 500)}...' : rb1,
        'request2Preview': rb2.length > 500 ? '${rb2.substring(0, 500)}...' : rb2,
      };
    }

    return _toolResult({
      'request1': _requestSummary(r1),
      'request2': _requestSummary(r2),
      'hasDifferences': diffs.isNotEmpty,
      'differenceCount': diffs.length,
      'differences': diffs,
    });
  }

  // ══════════════════════════════════════════════════════════════════════════
  // A. 请求重放与代码生成
  // ══════════════════════════════════════════════════════════════════════════

  static Future<Map<String, dynamic>> _replayRequest(
      Map<String, dynamic> args, ListenableList<HttpRequest> container) async {
    final requestId = args['requestId'] as String?;
    if (requestId == null) return _toolError('requestId 不能为空');

    final request = _findRequest(requestId, container);
    if (request == null) return _toolError('未找到请求 $requestId');

    final overrideHeaders = args['headers'] as Map<String, dynamic>?;
    final overrideBody = args['body'] as String?;
    final timeoutSecs = (args['timeoutSeconds'] as int?) ?? 30;

    final client = io.HttpClient()
      ..connectionTimeout = Duration(seconds: timeoutSecs)
      ..badCertificateCallback = (_, __, ___) => true;

    try {
      final uri = Uri.parse(request.requestUrl);
      final ioRequest = await client.openUrl(request.method.name, uri);

      // 复制请求头，跳过会干扰重放的 hop-by-hop 头
      final skipHeaders = {'content-length', 'transfer-encoding', 'host', 'connection'};
      request.headers.toMap().forEach((key, value) {
        if (!skipHeaders.contains(key.toLowerCase())) {
          ioRequest.headers.set(key, value);
        }
      });
      overrideHeaders?.forEach((k, v) => ioRequest.headers.set(k, v.toString()));

      final body = overrideBody ?? request.bodyAsString;
      if (body.isNotEmpty) {
        final bodyBytes = utf8.encode(body);
        ioRequest.contentLength = bodyBytes.length;
        ioRequest.add(bodyBytes);
      }

      final ioResponse = await ioRequest.close();
      final responseBody = await utf8.decoder.bind(ioResponse).join();
      final truncated = responseBody.length > 10000;

      return _toolResult({
        'statusCode': ioResponse.statusCode,
        'reasonPhrase': ioResponse.reasonPhrase,
        'headers': () {
          final hdrs = <String, String>{};
          ioResponse.headers.forEach((name, values) => hdrs[name] = values.join(', '));
          return hdrs;
        }(),
        'bodyLength': responseBody.length,
        'truncated': truncated,
        'body': truncated ? '${responseBody.substring(0, 10000)}...' : responseBody,
      });
    } catch (e) {
      return _toolError('重放请求失败: $e');
    } finally {
      client.close();
    }
  }

  static Map<String, dynamic> _generateCode(Map<String, dynamic> args, ListenableList<HttpRequest> container) {
    final requestId = args['requestId'] as String?;
    if (requestId == null) return _toolError('requestId 不能为空');

    final language = (args['language'] as String?) ?? 'python';
    final request = _findRequest(requestId, container);
    if (request == null) return _toolError('未找到请求 $requestId');

    final String code;
    switch (language.toLowerCase()) {
      case 'python':
        code = _genPython(request);
        break;
      case 'javascript':
        code = _genJavaScript(request);
        break;
      case 'curl':
        code = _genCurl(request);
        break;
      case 'go':
        code = _genGo(request);
        break;
      default:
        return _toolError('不支持的语言: $language，可选: python, javascript, curl, go');
    }

    return _toolResult({'language': language, 'code': code});
  }

  static String _genPython(HttpRequest request) {
    final headers = request.headers.toMap();
    final body = request.bodyAsString;
    final headersStr = headers.entries
        .map((e) => '    "${e.key}": "${e.value.replaceAll('"', '\\"').replaceAll('\n', '\\n')}"')
        .join(',\n');

    final sb = StringBuffer()
      ..writeln('import requests')
      ..writeln()
      ..writeln('url = "${request.requestUrl}"')
      ..writeln()
      ..writeln('headers = {')
      ..writeln(headersStr)
      ..writeln('}')
      ..writeln();

    if (body.isNotEmpty) {
      sb.writeln('body = """${body.replaceAll('"""', "'''")}"""');
      sb.writeln();
      sb.writeln('response = requests.${request.method.name.toLowerCase()}(url, headers=headers, data=body)');
    } else {
      sb.writeln('response = requests.${request.method.name.toLowerCase()}(url, headers=headers)');
    }

    sb.writeln('print(response.status_code)');
    sb.writeln('print(response.text)');
    return sb.toString();
  }

  static String _genJavaScript(HttpRequest request) {
    final headers = jsonEncode(request.headers.toMap());
    final body = request.bodyAsString;

    final sb = StringBuffer()
      ..writeln('const response = await fetch("${request.requestUrl}", {')
      ..writeln('  method: "${request.method.name}",')
      ..writeln('  headers: $headers,');

    if (body.isNotEmpty) {
      sb.writeln('  body: `${body.replaceAll('`', '\\`')}`,');
    }
    sb.writeln('});');
    sb.writeln('const data = await response.text();');
    sb.writeln('console.log(response.status, data);');
    return sb.toString();
  }

  static String _genCurl(HttpRequest request) {
    final sb = StringBuffer();
    sb.write('curl -X ${request.method.name}');
    sb.write(' \\\n  "${request.requestUrl}"');

    request.headers.toMap().forEach((k, v) {
      sb.write(' \\\n  -H "${k}: ${v.replaceAll('"', '\\"')}"');
    });

    final body = request.bodyAsString;
    if (body.isNotEmpty) {
      sb.write(" \\\n  --data-raw '${body.replaceAll("'", "'\\''")}'");
    }
    return sb.toString();
  }

  static String _genGo(HttpRequest request) {
    final headers = request.headers.toMap();
    final body = request.bodyAsString;

    final sb = StringBuffer()
      ..writeln('package main')
      ..writeln()
      ..writeln('import (')
      ..writeln('\t"fmt"')
      ..writeln('\t"io"')
      ..writeln('\t"net/http"')
      ..writeln('\t"strings"')
      ..writeln(')')
      ..writeln()
      ..writeln('func main() {');

    if (body.isNotEmpty) {
      sb.writeln('\tbody := strings.NewReader(`${body.replaceAll('`', '` + "`" + `')}`)');
      sb.writeln('\treq, _ := http.NewRequest("${request.method.name}", "${request.requestUrl}", body)');
    } else {
      sb.writeln('\treq, _ := http.NewRequest("${request.method.name}", "${request.requestUrl}", nil)');
    }

    headers.forEach((k, v) {
      sb.writeln('\treq.Header.Set("$k", "${v.replaceAll('"', '\\"')}")');
    });

    sb
      ..writeln('\tclient := &http.Client{}')
      ..writeln('\tresp, err := client.Do(req)')
      ..writeln('\tif err != nil { panic(err) }')
      ..writeln('\tdefer resp.Body.Close()')
      ..writeln('\tbody2, _ := io.ReadAll(resp.Body)')
      ..writeln('\tfmt.Println(resp.StatusCode, string(body2))')
      ..writeln('}');
    return sb.toString();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // B. 断点拦截（Fiddler 风格）
  // ══════════════════════════════════════════════════════════════════════════

  static Future<Map<String, dynamic>> _addBreakpoint(Map<String, dynamic> args) async {
    final url = args['url'] as String?;
    if (url == null || url.isEmpty) return _toolError('url 参数不能为空');

    final interceptRequest = (args['interceptRequest'] as bool?) ?? true;
    final interceptResponse = (args['interceptResponse'] as bool?) ?? false;
    final methodStr = args['method'] as String?;

    HttpMethod? method;
    if (methodStr != null && methodStr.isNotEmpty) {
      try {
        method = HttpMethod.valueOf(methodStr.toUpperCase());
      } catch (_) {
        return _toolError('无效的 HTTP 方法: $methodStr');
      }
    }

    final rule = RequestBreakpointRule(
      url: url,
      name: (args['name'] as String?) ?? 'MCP-${DateTime.now().millisecondsSinceEpoch}',
      interceptRequest: interceptRequest,
      interceptResponse: interceptResponse,
      method: method,
    );

    final manager = await RequestBreakpointManager.instance;
    manager.enabled = true;
    manager.add(rule);

    return _toolResult({
      'message': '断点规则已添加，ProxyPin 断点功能已启用',
      'rule': rule.toJson(),
      'totalRules': manager.list.length,
      'hint': '触发请求后请调用 get_pending_intercepts 查看拦截队列',
    });
  }

  static Future<Map<String, dynamic>> _listBreakpoints() async {
    final manager = await RequestBreakpointManager.instance;
    return _toolResult({
      'enabled': manager.enabled,
      'totalRules': manager.list.length,
      'rules': manager.list.asMap().entries.map((e) => {'index': e.key, ...e.value.toJson()}).toList(),
    });
  }

  static Future<Map<String, dynamic>> _removeBreakpoint(Map<String, dynamic> args) async {
    final index = args['index'] as int?;
    if (index == null) return _toolError('index 参数不能为空');

    final manager = await RequestBreakpointManager.instance;
    if (index < 0 || index >= manager.list.length) {
      return _toolError('无效的索引 $index，当前共有 ${manager.list.length} 条规则');
    }

    final rule = manager.list[index];
    manager.remove(rule);

    return _toolResult({
      'message': '断点规则已删除',
      'deletedRule': rule.toJson(),
      'remaining': manager.list.length,
    });
  }

  static Map<String, dynamic> _getPendingIntercepts() {
    final pending = McpInterceptQueue.instance.getPendingList();
    return _toolResult({
      'count': pending.length,
      'pending': pending,
      'hint': pending.isEmpty
          ? '当前没有被拦截的请求。请先通过 add_breakpoint 添加规则，再触发对应请求'
          : '使用 release_intercept 放行（可携带修改后的 headers/body）',
    });
  }

  static Map<String, dynamic> _releaseIntercept(Map<String, dynamic> args) {
    final requestId = args['requestId'] as String?;
    if (requestId == null) return _toolError('requestId 不能为空');

    if (!McpInterceptQueue.instance.hasPending(requestId)) {
      return _toolError('requestId=$requestId 不在拦截队列中，可能已超时（10分钟）或不存在');
    }

    final abort = (args['abort'] as bool?) ?? false;
    final modifiedHeaders = args['headers'] as Map<String, dynamic>?;
    final modifiedBody = args['body'] as String?;
    final modifiedStatusCode = args['statusCode'] as int?;
    final type = McpInterceptQueue.instance.getPendingType(requestId)!;

    if (type == 'request') {
      if (abort) {
        RequestBreakpointInterceptor.instance.resumeRequest(requestId, null);
        McpInterceptQueue.instance.remove(requestId);
        return _toolResult({'message': '请求已中止（服务器不会收到此请求）', 'requestId': requestId});
      }

      final rawJson = McpInterceptQueue.instance.getRawRequestJson(requestId)!;
      final modifiedReq = HttpRequest.fromJson(rawJson);
      if (modifiedHeaders != null) {
        modifiedHeaders.forEach((k, v) => modifiedReq.headers.set(k, v.toString()));
      }
      if (modifiedBody != null) {
        modifiedReq.body = utf8.encode(modifiedBody);
      }

      RequestBreakpointInterceptor.instance.resumeRequest(requestId, modifiedReq);
      McpInterceptQueue.instance.remove(requestId);

      return _toolResult({
        'message': '请求已放行',
        'requestId': requestId,
        'modified': modifiedHeaders != null || modifiedBody != null,
      });
    } else {
      // response
      if (abort) {
        RequestBreakpointInterceptor.instance.resumeResponse(requestId, null);
        McpInterceptQueue.instance.remove(requestId);
        return _toolResult({'message': '响应已中止（客户端将收到连接错误）', 'requestId': requestId});
      }

      final rawJson = McpInterceptQueue.instance.getRawResponseJson(requestId)!;
      final modifiedResp = HttpResponse.fromJson(rawJson);

      if (modifiedStatusCode != null) {
        modifiedResp.status = HttpStatus(modifiedStatusCode, modifiedResp.status.reasonPhrase);
      }
      if (modifiedHeaders != null) {
        modifiedHeaders.forEach((k, v) => modifiedResp.headers.set(k, v.toString()));
      }
      if (modifiedBody != null) {
        modifiedResp.body = utf8.encode(modifiedBody);
      }

      RequestBreakpointInterceptor.instance.resumeResponse(requestId, modifiedResp);
      McpInterceptQueue.instance.remove(requestId);

      return _toolResult({
        'message': '响应已放行',
        'requestId': requestId,
        'modified': modifiedStatusCode != null || modifiedHeaders != null || modifiedBody != null,
      });
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // C. 重写规则管理
  // ══════════════════════════════════════════════════════════════════════════

  static Future<Map<String, dynamic>> _listRewriteRules() async {
    final manager = await RequestRewriteManager.instance;
    return _toolResult({
      'enabled': manager.enabled,
      'groups': manager.groups,
      'totalRules': manager.rules.length,
      'rules': manager.rules.asMap().entries.map((e) => {'index': e.key, ...e.value.toJson()}).toList(),
    });
  }

  static Future<Map<String, dynamic>> _addRewriteRule(Map<String, dynamic> args) async {
    final url = args['url'] as String?;
    final ruleTypeStr = args['ruleType'] as String?;
    if (url == null || ruleTypeStr == null) return _toolError('url 和 ruleType 不能为空');

    RuleType type;
    try {
      type = RuleType.fromName(ruleTypeStr);
    } catch (_) {
      return _toolError('无效的 ruleType: $ruleTypeStr，可选: ${RuleType.values.map((e) => e.name).join(", ")}');
    }

    final rule = RequestRewriteRule(
      url: url,
      type: type,
      name: args['name'] as String?,
      group: args['group'] as String?,
    );
    final items = <RewriteItem>[];

    final body = args['body'] as String?;
    final statusCode = args['statusCode'] as int?;
    final redirectUrl = args['redirectUrl'] as String?;
    final rawHeaders = args['headers'] as Map<String, dynamic>?;
    final headers = rawHeaders?.map((k, v) => MapEntry(k, v.toString()));

    switch (type) {
      case RuleType.responseReplace:
        if (statusCode != null)
          items.add(RewriteItem(RewriteType.replaceResponseStatus, true)..statusCode = statusCode);
        if (headers != null) items.add(RewriteItem(RewriteType.replaceResponseHeader, true)..headers = headers);
        if (body != null) items.add(RewriteItem(RewriteType.replaceResponseBody, true)..body = body);
        break;
      case RuleType.requestReplace:
        if (headers != null) items.add(RewriteItem(RewriteType.replaceRequestHeader, true)..headers = headers);
        if (body != null) items.add(RewriteItem(RewriteType.replaceRequestBody, true)..body = body);
        break;
      case RuleType.redirect:
        if (redirectUrl == null) return _toolError('redirect 类型必须提供 redirectUrl');
        items.add(RewriteItem(RewriteType.redirect, true)..redirectUrl = redirectUrl);
        break;
      case RuleType.requestUpdate:
        if (body != null) items.add(RewriteItem(RewriteType.updateBody, true)..body = body);
        if (headers != null) {
          headers.forEach((k, v) => items.add(RewriteItem(RewriteType.updateHeader, true)
            ..key = k
            ..value = v));
        }
        break;
      case RuleType.responseUpdate:
        if (body != null) items.add(RewriteItem(RewriteType.updateBody, true)..body = body);
        if (headers != null) {
          headers.forEach((k, v) => items.add(RewriteItem(RewriteType.updateHeader, true)
            ..key = k
            ..value = v));
        }
        break;
    }

    if (items.isEmpty) {
      return _toolError('请至少提供 body、statusCode、redirectUrl 或 headers 之一');
    }

    final manager = await RequestRewriteManager.instance;
    manager.enabled = true;
    await manager.addRule(rule, items);
    await manager.flushRequestRewriteConfig();

    return _toolResult({
      'message': '重写规则已添加',
      'rule': rule.toJson(),
      'itemCount': items.length,
      'totalRules': manager.rules.length,
    });
  }

  static Future<Map<String, dynamic>> _removeRewriteRule(Map<String, dynamic> args) async {
    final index = args['index'] as int?;
    if (index == null) return _toolError('index 不能为空');

    final manager = await RequestRewriteManager.instance;
    if (index < 0 || index >= manager.rules.length) {
      return _toolError('无效索引 $index，当前共有 ${manager.rules.length} 条规则');
    }

    final rule = manager.rules[index];
    await manager.removeIndex([index]);
    await manager.flushRequestRewriteConfig();

    return _toolResult({'message': '重写规则已删除', 'deletedRule': rule.toJson()});
  }

  // ══════════════════════════════════════════════════════════════════════════
  // D. JS 脚本管理
  // ══════════════════════════════════════════════════════════════════════════

  static Future<Map<String, dynamic>> _listScripts() async {
    final manager = await ScriptManager.instance;
    return _toolResult({
      'enabled': manager.enabled,
      'totalScripts': manager.list.length,
      'scripts': manager.list
          .asMap()
          .entries
          .map((e) => {
                'index': e.key,
                'name': e.value.name,
                'enabled': e.value.enabled,
                'urls': e.value.urls,
                'hasRemote': e.value.remoteUrl != null,
              })
          .toList(),
    });
  }

  static Future<Map<String, dynamic>> _getScriptContent(Map<String, dynamic> args) async {
    final index = args['index'] as int?;
    if (index == null) return _toolError('index 不能为空');

    final manager = await ScriptManager.instance;
    if (index < 0 || index >= manager.list.length) return _toolError('无效索引 $index');

    final item = manager.list[index];
    final content = await manager.getScript(item);

    return _toolResult({
      'index': index,
      'name': item.name,
      'urls': item.urls,
      'enabled': item.enabled,
      'script': content ?? '（脚本文件为空）',
    });
  }

  static Future<Map<String, dynamic>> _createOrUpdateScript(Map<String, dynamic> args) async {
    final name = args['name'] as String?;
    final url = args['url'] as String?;
    final script = args['script'] as String?;
    final index = args['index'] as int?;

    if (name == null || url == null || script == null) {
      return _toolError('name、url、script 参数均不能为空');
    }

    final manager = await ScriptManager.instance;

    if (index != null) {
      // 更新已有脚本
      if (index < 0 || index >= manager.list.length) return _toolError('无效索引 $index');
      final item = manager.list[index];
      item.name = name;
      item.urls = [url];
      item.urlRegs = null; // 重置正则缓存
      await manager.updateScript(item, script);
      await manager.flushConfig();

      return _toolResult({'message': '脚本已更新', 'index': index, 'name': name, 'url': url});
    } else {
      // 创建新脚本
      final item = ScriptItem(true, name, url);
      await manager.addScript(item, script);
      await manager.flushConfig();

      return _toolResult({
        'message': '脚本已创建',
        'index': manager.list.length - 1,
        'name': name,
        'url': url,
        'hint': '脚本将在下次匹配到 "$url" 的请求时自动执行',
      });
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // E. 安全分析
  // ══════════════════════════════════════════════════════════════════════════

  static Map<String, dynamic> _findSensitiveData(Map<String, dynamic> args, ListenableList<HttpRequest> container) {
    final domain = args['domain'] as String?;
    final requestId = args['requestId'] as String?;

    List<HttpRequest> requests;
    if (requestId != null) {
      final r = _findRequest(requestId, container);
      if (r == null) return _toolError('未找到请求 $requestId');
      requests = [r];
    } else {
      requests = container.source.toList();
      if (domain != null && domain.isNotEmpty) {
        requests =
            requests.where((r) => (r.remoteDomain() ?? '').toLowerCase().contains(domain.toLowerCase())).toList();
      }
    }

    final patterns = <String, RegExp>{
      '手机号': RegExp(r'1[3-9]\d{9}'),
      '身份证号': RegExp(r'\d{17}[\dXx]'),
      '邮箱地址': RegExp(r'[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}'),
      'JWT Token': RegExp(r'eyJ[A-Za-z0-9+/=_-]+\.eyJ[A-Za-z0-9+/=_-]+\.[A-Za-z0-9+/=_-]+'),
      'Bearer Token': RegExp(r'[Bb]earer\s+[A-Za-z0-9+/=_\-\.]{20,}'),
      'API Key 字段':
          RegExp(r'"(api[_-]?key|apikey|access[_-]?token|secret[_-]?key)"\s*:\s*"([^"]{8,})"', caseSensitive: false),
      '密码字段': RegExp(r'"(password|passwd|pwd|pass|secret)"\s*:\s*"([^"]{4,})"', caseSensitive: false),
      '内网 IP': RegExp(
          r'\b(10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})\b'),
    };

    final grouped = <String, List<Map<String, dynamic>>>{};
    int totalFindings = 0;

    for (var request in requests) {
      final texts = <String, String>{
        'requestBody': request.bodyAsString,
        'responseBody': request.response?.bodyAsString ?? '',
      };

      for (var textEntry in texts.entries) {
        if (textEntry.value.isEmpty) continue;
        for (var patEntry in patterns.entries) {
          final matches = patEntry.value.allMatches(textEntry.value);
          for (var match in matches.take(5)) {
            final found = match.group(0)!;
            if (found.length > 300) continue;
            grouped.putIfAbsent(patEntry.key, () => []).add({
              'requestId': request.requestId,
              'url': request.requestUrl,
              'location': textEntry.key,
              'value': found.length > 120 ? '${found.substring(0, 120)}...' : found,
            });
            totalFindings++;
          }
        }
      }
    }

    return _toolResult({
      'scannedRequests': requests.length,
      'totalFindings': totalFindings,
      'findingsByType': grouped,
      'summary': grouped.map((k, v) => MapEntry(k, '${v.length} 处')),
    });
  }

  static Map<String, dynamic> _analyzeAuth(Map<String, dynamic> args, ListenableList<HttpRequest> container) {
    final domain = args['domain'] as String?;

    var requests = container.source.toList();
    if (domain != null && domain.isNotEmpty) {
      requests = requests.where((r) => (r.remoteDomain() ?? '').toLowerCase().contains(domain.toLowerCase())).toList();
    }

    final authByDomain = <String, Set<String>>{};
    final apiKeyHeaders = <Map<String, String>>[];
    final sessionTokens = <String, String>{};

    const apiKeyHeaderNames = ['X-Api-Key', 'Api-Key', 'X-Auth-Token', 'X-Access-Token', 'Token', 'X-Token', 'App-Key'];

    for (var request in requests) {
      final headers = request.headers.toMap();
      final host = request.remoteDomain() ?? 'unknown';

      // Authorization 头
      final auth = headers['Authorization'] ?? headers['authorization'];
      if (auth != null) {
        authByDomain.putIfAbsent(host, () => {}).add(auth);
      }

      // 常见 API Key 头
      for (var headerName in apiKeyHeaderNames) {
        final val = headers[headerName] ?? headers[headerName.toLowerCase()];
        if (val != null && apiKeyHeaders.length < 30) {
          apiKeyHeaders.add({'header': headerName, 'value': val, 'url': request.requestUrl});
        }
      }

      // Cookie 中的 session/token
      final cookie = headers['Cookie'] ?? headers['cookie'];
      if (cookie != null) {
        for (var pair in cookie.split(';')) {
          pair = pair.trim();
          final eqIdx = pair.indexOf('=');
          if (eqIdx > 0) {
            final key = pair.substring(0, eqIdx).trim();
            final val = pair.substring(eqIdx + 1).trim();
            final lKey = key.toLowerCase();
            if (lKey.contains('session') || lKey.contains('token') || lKey.contains('auth') || lKey.contains('sid')) {
              sessionTokens[key] = val.length > 60 ? '${val.substring(0, 60)}...' : val;
            }
          }
        }
      }
    }

    // 解析 JWT
    final jwtAnalysis = <Map<String, dynamic>>[];
    for (var entry in authByDomain.entries) {
      for (var auth in entry.value) {
        if (auth.startsWith('Bearer ') || auth.startsWith('bearer ')) {
          final token = auth.substring(7).trim();
          final parts = token.split('.');
          if (parts.length == 3) {
            try {
              var payload = parts[1].replaceAll('-', '+').replaceAll('_', '/');
              while (payload.length % 4 != 0) payload += '=';
              final decoded = utf8.decode(base64Decode(payload));
              jwtAnalysis.add({
                'domain': entry.key,
                'tokenPreview': '${token.substring(0, min(20, token.length))}...',
                'payload': jsonDecode(decoded),
              });
            } catch (_) {}
          }
        }
      }
    }

    return _toolResult({
      'scannedRequests': requests.length,
      'authorizationHeaders': authByDomain.map((domain, values) => MapEntry(domain, values.toList())),
      'apiKeyHeaders': apiKeyHeaders,
      'sessionTokensInCookie': sessionTokens,
      'jwtPayloads': jwtAnalysis,
    });
  }

  static Map<String, dynamic> _extractApiEndpoints(Map<String, dynamic> args, ListenableList<HttpRequest> container) {
    final domain = args['domain'] as String?;

    var requests = container.source.toList();
    if (domain != null && domain.isNotEmpty) {
      requests = requests.where((r) => (r.remoteDomain() ?? '').toLowerCase().contains(domain.toLowerCase())).toList();
    }

    final endpoints = <String, Map<String, dynamic>>{};

    for (var request in requests) {
      final host = request.remoteDomain() ?? 'unknown';
      final method = request.method.name;
      final normalizedPath = _normalizePath(request.path);
      final key = '$method $host$normalizedPath';

      if (!endpoints.containsKey(key)) {
        endpoints[key] = {
          'method': method,
          'host': host,
          'path': normalizedPath,
          'sampleUrl': request.requestUrl,
          'count': 0,
          'statusCodes': <int, int>{},
          'contentTypes': <String>{},
          'hasBody': false,
        };
      }

      endpoints[key]!['count'] = (endpoints[key]!['count'] as int) + 1;
      if (request.bodyAsString.isNotEmpty) endpoints[key]!['hasBody'] = true;

      final status = request.response?.status.code;
      if (status != null) {
        final sc = endpoints[key]!['statusCodes'] as Map<int, int>;
        sc[status] = (sc[status] ?? 0) + 1;
      }
      final ct = request.response?.headers.contentType;
      if (ct != null && ct.isNotEmpty) {
        (endpoints[key]!['contentTypes'] as Set<String>).add(ct.split(';').first.trim());
      }
    }

    final sorted = endpoints.values.toList()..sort((a, b) => (b['count'] as int).compareTo(a['count'] as int));

    final result = sorted
        .map((e) => {
              ...e,
              'statusCodes': (e['statusCodes'] as Map<int, int>).map((k, v) => MapEntry(k.toString(), v)),
              'contentTypes': (e['contentTypes'] as Set<String>).toList(),
            })
        .toList();

    return _toolResult({
      'totalEndpoints': result.length,
      'scannedRequests': requests.length,
      'endpoints': result,
    });
  }

  /// 规范化路径：将纯数字 ID、UUID 替换为占位符
  static String _normalizePath(String path) {
    return path
        .replaceAll(
            RegExp(r'/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', caseSensitive: false), '/{uuid}')
        .replaceAll(RegExp(r'/\d{5,}'), '/{id}')
        .replaceAll(RegExp(r'/\d{1,4}(?=/|$)'), '/{n}');
  }

  // ══════════════════════════════════════════════════════════════════════════
  // F. 抓包控制
  // ══════════════════════════════════════════════════════════════════════════

  /// 启动抓包
  static Future<Map<String, dynamic>> _startCapture() async {
    final proxyServer = ProxyServer.current;
    if (proxyServer == null) {
      return _toolError('ProxyServer 未初始化，请先在 ProxyPin 桌面端打开抓包页面');
    }
    if (proxyServer.isRunning) {
      return _toolResult({
        'message': '抓包服务已在运行中',
        'status': _buildProxyStatus(proxyServer, null),
      });
    }
    try {
      await proxyServer.start();
      return _toolResult({
        'message': '抓包服务已启动',
        'status': _buildProxyStatus(proxyServer, null),
      });
    } catch (e) {
      return _toolResult({
        'message': '启动抓包失败',
        'error': '$e',
        'status': _buildProxyStatus(proxyServer, null),
      });
    }
  }

  /// 停止抓包
  static Future<Map<String, dynamic>> _stopCapture() async {
    final proxyServer = ProxyServer.current;
    if (proxyServer == null) {
      return _toolError('ProxyServer 未初始化，请先在 ProxyPin 桌面端打开抓包页面');
    }
    if (!proxyServer.isRunning) {
      return _toolResult({
        'message': '抓包服务未在运行',
        'status': _buildProxyStatus(proxyServer, null),
      });
    }
    try {
      await proxyServer.stop();
      return _toolResult({
        'message': '抓包服务已停止',
        'status': _buildProxyStatus(proxyServer, null),
      });
    } catch (e) {
      return _toolResult({
        'message': '停止抓包失败',
        'error': '$e',
        'status': _buildProxyStatus(proxyServer, null),
      });
    }
  }

  /// 清空抓包列表
  static Map<String, dynamic> _clearRequests(ListenableList<HttpRequest> container) {
    final proxyServer = ProxyServer.current;
    final cleared = container.length;
    container.clear();
    return _toolResult({
      'message': '已清空抓包列表',
      'clearedCount': cleared,
      'status': _buildProxyStatus(proxyServer, container),
    });
  }

  static Future<Map<String, dynamic>> _diagnoseMock(
      Map<String, dynamic> args, ListenableList<HttpRequest> container) async {
    final requestId = args['requestId']?.toString();
    if (requestId == null || requestId.isEmpty) return _toolError('requestId 不能为空');
    final request = _findRequest(requestId, container);
    if (request == null) return _toolError('未找到 requestId=$requestId');
    final manager = await RequestRewriteManager.instance;
    final diagnostics = manager.diagnose(request);
    return _toolResult({
      'requestId': requestId,
      'method': request.method.name.toUpperCase(),
      'url': _redactUrl(request.requestUrl),
      'managerEnabled': diagnostics.managerEnabled,
      'winnerIndex': diagnostics.winner?.index,
      'rules': diagnostics.evaluations
          .map((evaluation) => {
                'index': evaluation.index,
                'name': evaluation.rule.name,
                'group': manager.groupNameFor(evaluation.rule),
                'type': evaluation.rule.type.name,
                'selected': evaluation.selected,
                'reason': evaluation.reason,
                'checks': {
                  'manager': evaluation.managerEnabled,
                  'group': evaluation.groupEnabled,
                  'rule': evaluation.rule.enabled,
                  'type': evaluation.typeMatches,
                  'method': evaluation.methodMatches,
                  'url': evaluation.urlMatches,
                },
                'hitCount': evaluation.stats.hitCount,
                'lastHitAt': evaluation.stats.lastHitAt?.toIso8601String(),
              })
          .toList(),
    });
  }

  static Future<Map<String, dynamic>> _getApiCatalog(
      Map<String, dynamic> args, ListenableList<HttpRequest> container) async {
    final limit = ((args['limit'] as int?) ?? 100).clamp(1, 500);
    final assets = await const ApiCatalogService().analyze(container.source);
    return _toolResult({
      'totalEndpoints': assets.length,
      'scannedRequests': container.length,
      'endpoints': assets
          .take(limit)
          .map((asset) => {
                'key': asset.key,
                'method': asset.method,
                'host': asset.host,
                'path': asset.normalizedPath,
                'requestCount': asset.requestCount,
                'statusCounts': asset.statusCounts.map((key, value) => MapEntry('$key', value)),
                'queryFields': asset.queryFields.toList(),
                'requestFields': asset.requestFields.toList(),
                'responseFields': asset.responseFields.toList(),
                'authSignals': asset.authSignals.toList(),
                'paginationSignals': asset.paginationSignals.toList(),
                'averageDurationMs': asset.averageDurationMs,
              })
          .toList(),
    });
  }

  static Future<Map<String, dynamic>> _previewDataExport(
      Map<String, dynamic> args, ListenableList<HttpRequest> container) async {
    final endpointKey = args['endpointKey']?.toString();
    if (endpointKey == null || endpointKey.isEmpty) return _toolError('endpointKey 不能为空');
    final sampleSize = ((args['sampleSize'] as int?) ?? 3).clamp(0, 20);
    final assets = await const ApiCatalogService().analyze(container.source);
    final matches = assets.where((asset) => asset.key == endpointKey);
    if (matches.isEmpty) return _toolError('未找到接口 $endpointKey，请先调用 get_api_catalog');
    final dataset = await const DataExportService().prepare(matches.first, container.source);
    return _toolResult({
      'endpointKey': endpointKey,
      'matchedRequests': dataset.matchedRequests,
      'recordPath': dataset.detectedRecordPath,
      'rawRecordCount': dataset.rawRecordCount,
      'recordCount': dataset.records.length,
      'duplicateCount': dataset.duplicateCount,
      'fields': dataset.fields,
      'paginationSignals': dataset.paginationSignals.toList(),
      'sample': dataset.records.take(sampleSize).toList(),
      'credentialsRedacted': true,
    });
  }

  static Future<Map<String, dynamic>> _listCaptureProjects(ListenableList<HttpRequest> container) async {
    final controller = CaptureProjectController.instance;
    await controller.initialize(container);
    return _toolResult({
      'projects': controller.projects
          .map((project) => {
                'id': project.id,
                'name': project.name,
                'status': project.status.name,
                'createdAt': project.createdAt.toIso8601String(),
                'endedAt': project.endedAt?.toIso8601String(),
                'requestCount': project.requestCount,
                'persistedCount': project.persistedCount,
                'domainCount': project.domains.length,
              })
          .toList(),
    });
  }

  static Future<Map<String, dynamic>> _startCaptureProject(
      Map<String, dynamic> args, ListenableList<HttpRequest> container) async {
    final name = args['name']?.toString().trim();
    if (name == null || name.isEmpty) return _toolError('name 不能为空');
    final controller = CaptureProjectController.instance;
    await controller.initialize(container);
    final project = await controller.start(name);
    return _toolResult({'message': '抓包项目已开始', 'project': project.toJson()});
  }

  static Future<Map<String, dynamic>> _stopCaptureProject(ListenableList<HttpRequest> container) async {
    final controller = CaptureProjectController.instance;
    await controller.initialize(container);
    final active = controller.activeProject;
    if (active == null) return _toolResult({'message': '当前没有活动项目'});
    await controller.stop();
    return _toolResult({'message': '抓包项目已结束并写盘', 'project': active.toJson()});
  }

  static Future<Map<String, dynamic>> _listMockScenarios() async {
    final manager = await RequestRewriteManager.instance;
    final groups = manager.groups.keys.where((name) => name != RequestRewriteManager.ungroupedName);
    return _toolResult({
      'managerEnabled': manager.enabled,
      'scenarios': groups.map((group) {
        final rules = manager.rules.where((rule) => manager.groupNameFor(rule) == group).toList();
        return {
          'name': group,
          'enabled': manager.groups[group] ?? true,
          'ruleCount': rules.length,
          'hitCount': rules.fold<int>(0, (sum, rule) => sum + manager.statsFor(rule).hitCount),
          'conflictCount': manager.conflictsForGroup(group).length,
        };
      }).toList(),
    });
  }

  static Future<Map<String, dynamic>> _activateMockScenario(Map<String, dynamic> args) async {
    final name = args['name']?.toString().trim();
    if (name == null || name.isEmpty) return _toolError('name 不能为空');
    final manager = await RequestRewriteManager.instance;
    if (!manager.groups.containsKey(name)) return _toolError('Mock 场景“$name”不存在');
    manager
      ..enabled = true
      ..activateExclusiveGroup(name);
    await manager.flushRequestRewriteConfig();
    return _toolResult({'message': '已独占启用 Mock 场景“$name”', 'groups': manager.groups});
  }

  static Future<Map<String, dynamic>> _runConnectionDoctor(ListenableList<HttpRequest> container) async {
    final proxyServer = ProxyServer.current;
    if (proxyServer == null) return _toolError('ProxyServer 未初始化');
    final checks = await const ConnectionDoctorService().run(proxyServer, container.source);
    return _toolResult({
      'checks': checks
          .map((check) => {
                'id': check.id,
                'title': check.title,
                'level': check.level.name,
                'detail': check.detail,
                'action': check.action,
              })
          .toList(),
    });
  }

  static String _redactUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasQuery) return value;
    final sensitive = RegExp(r'token|auth|key|secret|password|session|cookie', caseSensitive: false);
    final query = <String, String>{};
    for (final entry in uri.queryParameters.entries) {
      query[entry.key] = sensitive.hasMatch(entry.key) ? '[REDACTED]' : entry.value;
    }
    return uri.replace(queryParameters: query).toString();
  }

  /// 构造 ProxyPin 实际状态（统一返回，便于 Python 等客户端解析）
  static Map<String, dynamic> _buildProxyStatus(ProxyServer? proxyServer, ListenableList<HttpRequest>? container) {
    final status = <String, dynamic>{
      'running': proxyServer?.isRunning ?? false,
      'requestCount': container?.length ?? 0,
    };

    if (proxyServer != null) {
      final config = proxyServer.configuration;
      status['port'] = proxyServer.port;
      status['sslEnabled'] = proxyServer.enableSsl;
      status['systemProxyEnabled'] = config.enableSystemProxy;
      status['socks5Enabled'] = config.enableSocks5;
      status['http2Enabled'] = config.enabledHttp2;
      status['proxyPassDomains'] = config.proxyPassDomains;
      if (config.externalProxy != null) {
        status['externalProxy'] = {
          'enabled': config.externalProxy!.enabled,
          'host': config.externalProxy!.host,
          'port': config.externalProxy!.port,
        };
      }
    } else {
      status['port'] = null;
      status['sslEnabled'] = null;
      status['systemProxyEnabled'] = null;
      status['socks5Enabled'] = null;
      status['http2Enabled'] = null;
      status['proxyPassDomains'] = null;
    }
    return status;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 工具辅助方法
  // ══════════════════════════════════════════════════════════════════════════

  static HttpRequest? _findRequest(String requestId, ListenableList<HttpRequest> container) {
    try {
      return container.source.firstWhere((r) => r.requestId == requestId);
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic> _requestSummary(HttpRequest request) {
    final response = request.response;
    return {
      'requestId': request.requestId,
      'method': request.method.name,
      'url': request.requestUrl,
      'domain': request.remoteDomain() ?? '',
      'path': request.path,
      'statusCode': response?.status.code,
      'statusMessage': response?.status.reasonPhrase,
      'costTime': response?.costTime() ?? '',
      'requestTime': request.requestTime.toIso8601String(),
      'responseTime': response?.responseTime.toIso8601String(),
      'requestContentType': request.headers.contentType,
      'responseContentType': response?.headers.contentType ?? '',
      'requestSize': request.packageSize ?? request.body?.length ?? 0,
      'responseSize': response?.packageSize ?? response?.body?.length ?? 0,
    };
  }

  static Map<String, dynamic> _requestDetail(HttpRequest request, {bool includeBody = true, int maxBodySize = 10000}) {
    final response = request.response;
    final detail = <String, dynamic>{
      'requestId': request.requestId,
      'method': request.method.name,
      'url': request.requestUrl,
      'domain': request.remoteDomain() ?? '',
      'path': request.path,
      'protocolVersion': request.protocolVersion,
      'requestTime': request.requestTime.toIso8601String(),
      'requestHeaders': request.headers.toMap(),
      'requestContentType': request.headers.contentType,
      'queries': request.queries,
    };

    if (includeBody) {
      var reqBody = request.bodyAsString;
      detail['requestBody'] = reqBody.length > maxBodySize ? reqBody.substring(0, maxBodySize) : reqBody;
      detail['requestBodyTruncated'] = reqBody.length > maxBodySize;
    }

    if (response != null) {
      detail['statusCode'] = response.status.code;
      detail['statusMessage'] = response.status.reasonPhrase;
      detail['costTime'] = response.costTime();
      detail['responseTime'] = response.responseTime.toIso8601String();
      detail['responseHeaders'] = response.headers.toMap();
      detail['responseContentType'] = response.headers.contentType;
      if (includeBody) {
        var respBody = response.bodyAsString;
        detail['responseBody'] = respBody.length > maxBodySize ? respBody.substring(0, maxBodySize) : respBody;
        detail['responseBodyTruncated'] = respBody.length > maxBodySize;
      }
    } else {
      detail['statusCode'] = null;
      detail['costTime'] = null;
      detail['responseHeaders'] = null;
      detail['responseBody'] = null;
    }

    return detail;
  }

  static Map<String, dynamic> _analyzeContent(String content) {
    final result = <String, dynamic>{};
    final trimmed = content.trim();
    result['length'] = trimmed.length;
    result['preview'] = trimmed.length > 500 ? '${trimmed.substring(0, 500)}...' : trimmed;

    final encodings = <String>[];
    final decodedResults = <String, String>{};

    final base64Regex = RegExp(r'^[A-Za-z0-9+/]+=*$');
    final cleanContent = trimmed.replaceAll(RegExp(r'\s+'), '');

    if (cleanContent.length >= 4 && base64Regex.hasMatch(cleanContent) && cleanContent.length % 4 == 0) {
      encodings.add('Base64');
      try {
        final decoded = utf8.decode(base64Decode(cleanContent));
        if (_isPrintable(decoded)) {
          decodedResults['Base64'] = decoded.length > 1000 ? '${decoded.substring(0, 1000)}...' : decoded;
        }
      } catch (_) {}
    }

    final hexRegex = RegExp(r'^[0-9a-fA-F]+$');
    if (cleanContent.length >= 4 && cleanContent.length % 2 == 0 && hexRegex.hasMatch(cleanContent)) {
      encodings.add('Hex');
      try {
        final bytes = <int>[];
        for (var i = 0; i < cleanContent.length; i += 2) {
          bytes.add(int.parse(cleanContent.substring(i, i + 2), radix: 16));
        }
        final decoded = utf8.decode(bytes, allowMalformed: true);
        if (_isPrintable(decoded)) {
          decodedResults['Hex'] = decoded.length > 1000 ? '${decoded.substring(0, 1000)}...' : decoded;
        }
      } catch (_) {}
    }

    if (trimmed.contains('%')) {
      encodings.add('URL编码');
      try {
        final decoded = Uri.decodeFull(trimmed);
        if (decoded != trimmed) {
          decodedResults['URL解码'] = decoded.length > 1000 ? '${decoded.substring(0, 1000)}...' : decoded;
        }
      } catch (_) {}
    }

    if ((trimmed.startsWith('{') && trimmed.endsWith('}')) || (trimmed.startsWith('[') && trimmed.endsWith(']'))) {
      try {
        jsonDecode(trimmed);
        encodings.add('JSON');
      } catch (_) {}
    }

    final jwtParts = trimmed.split('.');
    if (jwtParts.length == 3 && base64Regex.hasMatch(jwtParts[0].replaceAll('-', '+').replaceAll('_', '/'))) {
      encodings.add('JWT');
      try {
        var payload = jwtParts[1].replaceAll('-', '+').replaceAll('_', '/');
        while (payload.length % 4 != 0) payload += '=';
        final decoded = utf8.decode(base64Decode(payload));
        decodedResults['JWT Payload'] = decoded;
      } catch (_) {}
    }

    final entropy = _calculateEntropy(trimmed);
    result['entropy'] = double.parse(entropy.toStringAsFixed(3));

    int upperCount = 0, lowerCount = 0, digitCount = 0, specialCount = 0, whitespaceCount = 0;
    for (var c in trimmed.runes) {
      if (c >= 65 && c <= 90)
        upperCount++;
      else if (c >= 97 && c <= 122)
        lowerCount++;
      else if (c >= 48 && c <= 57)
        digitCount++;
      else if (c == 32 || c == 10 || c == 13 || c == 9)
        whitespaceCount++;
      else
        specialCount++;
    }
    result['charDistribution'] = {
      'uppercase': upperCount,
      'lowercase': lowerCount,
      'digits': digitCount,
      'special': specialCount,
      'whitespace': whitespaceCount,
    };

    result['detectedEncodings'] = encodings.isEmpty ? ['未检测到明确编码'] : encodings;
    if (decodedResults.isNotEmpty) result['decodedResults'] = decodedResults;

    final hints = <String>[];
    if (entropy > 4.5 && encodings.isEmpty) hints.add('高熵值(${entropy.toStringAsFixed(2)})，可能为加密数据');
    if (entropy > 3.5 && entropy <= 4.5 && encodings.contains('Base64')) hints.add('中等熵值 + Base64，可能为加密后 Base64 编码');
    if (cleanContent.length == 32 || cleanContent.length == 64 || cleanContent.length == 128) {
      hints.add('长度 ${cleanContent.length}，可能为哈希值（MD5/SHA256/SHA512）');
    }
    if (trimmed.startsWith('ey') && encodings.contains('JWT')) hints.add('JWT Token，可直接解析 Payload');
    if (hints.isNotEmpty) result['analysisHints'] = hints;

    return result;
  }

  static double _calculateEntropy(String text) {
    if (text.isEmpty) return 0;
    final freq = <int, int>{};
    for (var c in text.runes) freq[c] = (freq[c] ?? 0) + 1;
    double entropy = 0;
    final len = text.length;
    for (var count in freq.values) {
      final p = count / len;
      if (p > 0) entropy -= p * (log(p) / ln2);
    }
    return entropy;
  }

  static bool _isPrintable(String text) {
    if (text.isEmpty) return false;
    int nonPrintable = 0;
    for (var c in text.runes) {
      if (c < 32 && c != 10 && c != 13 && c != 9) nonPrintable++;
    }
    return nonPrintable < text.length * 0.1;
  }

  static Map<String, dynamic> _toolResult(Map<String, dynamic> data) {
    return {
      'content': [
        {'type': 'text', 'text': const JsonEncoder.withIndent('  ').convert(data)}
      ],
    };
  }

  static Map<String, dynamic> _toolError(String message) {
    return {
      'content': [
        {'type': 'text', 'text': message}
      ],
      'isError': true,
    };
  }
}
