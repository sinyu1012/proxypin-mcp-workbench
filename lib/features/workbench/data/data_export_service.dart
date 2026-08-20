import 'dart:convert';
import 'dart:isolate';

import 'package:proxypin/features/workbench/data/api_catalog_service.dart';
import 'package:proxypin/features/workbench/domain/api_endpoint_asset.dart';
import 'package:proxypin/features/workbench/domain/export_dataset.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/channel/host_port.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/http/http_client.dart';

class DataExportService {
  const DataExportService();

  Future<ExportDataset> prepare(
    ApiEndpointAsset endpoint,
    Iterable<HttpRequest> requests, {
    bool redactCredentials = true,
  }) async {
    final snapshots = <Map<String, dynamic>>[];
    for (final request in requests) {
      final uri = request.requestUri;
      if (uri == null || request.method.name.toUpperCase() != endpoint.method || uri.host != endpoint.host) continue;
      if (ApiCatalogService.normalizePath(uri.path) != endpoint.normalizedPath) continue;
      final response = request.response;
      if (response?.body == null || response!.body!.length > 8 * 1024 * 1024) continue;
      snapshots.add({
        'body': response.getBodyString(),
        'queryFields': uri.queryParametersAll.keys.toList(),
      });
    }

    final result = await Isolate.run(
      () => _prepareRaw(endpoint.key, snapshots, endpoint.paginationSignals.toList(), redactCredentials),
    );
    return ExportDataset(
      endpointKey: endpoint.key,
      records: List<Map<String, dynamic>>.from(result['records'] as List),
      fields: List<String>.from(result['fields'] as List),
      matchedRequests: result['matchedRequests'] as int,
      rawRecordCount: result['rawRecordCount'] as int,
      duplicateCount: result['duplicateCount'] as int,
      detectedRecordPath: result['detectedRecordPath'] as String?,
      paginationSignals: Set<String>.from(result['paginationSignals'] as List),
    );
  }

  String toJson(ExportDataset dataset) => const JsonEncoder.withIndent('  ').convert({
        'metadata': {
          'endpoint': dataset.endpointKey,
          'matchedRequests': dataset.matchedRequests,
          'recordCount': dataset.records.length,
          'rawRecordCount': dataset.rawRecordCount,
          'duplicateCount': dataset.duplicateCount,
          'recordPath': dataset.detectedRecordPath,
          'exportedAt': DateTime.now().toIso8601String(),
        },
        'records': dataset.records,
      });

  String toCsv(ExportDataset dataset) {
    final buffer = StringBuffer();
    buffer.writeln(dataset.fields.map(_csvCell).join(','));
    for (final record in dataset.records) {
      buffer.writeln(dataset.fields.map((field) => _csvCell(record[field])).join(','));
    }
    return buffer.toString();
  }

  /// 对只读 GET 列表接口执行有界自动分页。
  Future<PaginationRunResult> fetchAllPages(
    ApiEndpointAsset endpoint,
    Iterable<HttpRequest> captured,
    ProxyServer proxyServer, {
    int maxPages = 100,
    void Function(int page, int records)? onProgress,
  }) async {
    if (endpoint.method != 'GET') {
      return const PaginationRunResult(requests: [], pagesFetched: 0, stopReason: '仅允许自动重放 GET 接口');
    }
    final templates = captured.where((request) {
      final uri = request.requestUri;
      return uri != null &&
          request.method == HttpMethod.get &&
          uri.host == endpoint.host &&
          ApiCatalogService.normalizePath(uri.path) == endpoint.normalizedPath;
    }).toList();
    if (templates.isEmpty) {
      return const PaginationRunResult(requests: [], pagesFetched: 0, stopReason: '没有可复用的已抓取请求');
    }

    final strategy = _detectPaginationStrategy(templates);
    if (strategy == null) {
      return const PaginationRunResult(requests: [], pagesFetched: 0, stopReason: '没有识别到 page、offset 或 cursor 参数');
    }
    var template = strategy.template;
    var nextValue = strategy.startValue;
    final fetched = <HttpRequest>[];
    final seenRecords = <String>{};
    var emptyRounds = 0;
    var stopReason = '达到最大页数 $maxPages';

    for (var index = 0; index < maxPages; index++) {
      final uri = template.requestUri!;
      final query = Map<String, String>.from(uri.queryParameters);
      query[strategy.parameter] = nextValue;
      final nextUri = uri.replace(queryParameters: query);
      final request = template.copy(uri: nextUri.toString())..hostAndPort = HostAndPort.of(nextUri.toString());
      final proxyInfo = proxyServer.isRunning ? ProxyInfo.of('127.0.0.1', proxyServer.port) : null;

      try {
        final response = await HttpClients.proxyRequest(
          request,
          proxyInfo: proxyInfo,
          timeout: const Duration(seconds: 20),
        );
        request.response = response;
        response.request = request;
        fetched.add(request);

        final pageRecords = _recordsFromBody(response.getBodyString());
        var added = 0;
        for (final record in pageRecords) {
          if (seenRecords.add(jsonEncode(record))) added++;
        }
        onProgress?.call(index + 1, seenRecords.length);
        emptyRounds = added == 0 ? emptyRounds + 1 : 0;

        final decoded = _tryDecode(response.getBodyString());
        final hasMore = _findBool(decoded, const {'hasmore', 'hasnext', 'more'});
        if (hasMore == false) {
          stopReason = '服务端返回 hasMore=false';
          break;
        }
        if (pageRecords.isEmpty) {
          stopReason = '下一页没有记录';
          break;
        }
        if (emptyRounds >= 2) {
          stopReason = '连续两页没有新增记录';
          break;
        }

        if (strategy.kind == _PaginationKind.cursor) {
          final cursor = _findValue(decoded, const {'nextcursor', 'next_cursor', 'cursor'});
          if (cursor == null || cursor.toString().isEmpty || cursor.toString() == nextValue) {
            stopReason = '响应中没有新的 cursor';
            break;
          }
          nextValue = cursor.toString();
        } else if (strategy.kind == _PaginationKind.offset) {
          nextValue = (int.parse(nextValue) + strategy.step).toString();
        } else {
          nextValue = (int.parse(nextValue) + 1).toString();
        }
        template = request;
      } catch (error) {
        stopReason = '第 ${index + 1} 页请求失败：$error';
        break;
      }
    }
    return PaginationRunResult(requests: fetched, pagesFetched: fetched.length, stopReason: stopReason);
  }

  static String _csvCell(dynamic value) {
    final text = value == null
        ? ''
        : value is String
            ? value
            : jsonEncode(value);
    return '"${text.replaceAll('"', '""')}"';
  }

  static Map<String, dynamic> _prepareRaw(
    String endpointKey,
    List<Map<String, dynamic>> snapshots,
    List<String> knownPaginationSignals,
    bool redactCredentials,
  ) {
    final rawRecords = <Map<String, dynamic>>[];
    final pathFrequency = <String, int>{};
    final paginationSignals = <String>{...knownPaginationSignals};

    for (final snapshot in snapshots) {
      final body = snapshot['body']?.toString();
      if (body == null || body.trim().isEmpty) continue;
      try {
        final decoded = jsonDecode(body);
        final candidate = _findBestRecordList(decoded);
        if (candidate == null) continue;
        pathFrequency[candidate.path] = (pathFrequency[candidate.path] ?? 0) + 1;
        rawRecords.addAll(candidate.records);
        _findPaginationFields(decoded, '', paginationSignals, 0);
      } catch (_) {
        // 非 JSON 响应不进入结构化导出。
      }
    }

    final deduplicated = <String, Map<String, dynamic>>{};
    final idField = _detectIdField(rawRecords);
    for (final record in rawRecords) {
      final flat = <String, dynamic>{};
      _flatten(record, '', flat);
      if (redactCredentials) _redact(flat);
      final key = idField == null ? jsonEncode(flat) : '${flat[idField]}';
      deduplicated.putIfAbsent(key, () => flat);
    }

    final fields = <String>{};
    for (final record in deduplicated.values) {
      fields.addAll(record.keys);
    }
    final sortedFields = fields.toList()..sort();
    final recordPath = pathFrequency.entries.isEmpty
        ? null
        : (pathFrequency.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;

    return {
      'endpointKey': endpointKey,
      'records': deduplicated.values.toList(),
      'fields': sortedFields,
      'matchedRequests': snapshots.length,
      'rawRecordCount': rawRecords.length,
      'duplicateCount': rawRecords.length - deduplicated.length,
      'detectedRecordPath': recordPath,
      'paginationSignals': paginationSignals.toList()..sort(),
    };
  }

  static List<Map<String, dynamic>> _recordsFromBody(String body) {
    final decoded = _tryDecode(body);
    return _findBestRecordList(decoded)?.records ?? const [];
  }

  static dynamic _tryDecode(String body) {
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }

  static bool? _findBool(dynamic node, Set<String> keys, [int depth = 0]) {
    final value = _findValue(node, keys, depth);
    if (value is bool) return value;
    if (value == 0 || value == '0' || value == 'false') return false;
    if (value == 1 || value == '1' || value == 'true') return true;
    return null;
  }

  static dynamic _findValue(dynamic node, Set<String> keys, [int depth = 0]) {
    if (depth > 5) return null;
    if (node is Map) {
      for (final entry in node.entries) {
        if (keys.contains(entry.key.toString().toLowerCase())) return entry.value;
      }
      for (final value in node.values) {
        final found = _findValue(value, keys, depth + 1);
        if (found != null) return found;
      }
    }
    return null;
  }

  static _PaginationStrategy? _detectPaginationStrategy(List<HttpRequest> requests) {
    const pageNames = ['page', 'pageno', 'page_no', 'pageindex', 'page_index'];
    const offsetNames = ['offset', 'start'];
    const cursorNames = ['cursor', 'nextcursor', 'next_cursor'];
    for (final namesAndKind in [
      (pageNames, _PaginationKind.page),
      (offsetNames, _PaginationKind.offset),
      (cursorNames, _PaginationKind.cursor),
    ]) {
      for (final request in requests) {
        final query = request.requestUri?.queryParameters ?? const <String, String>{};
        for (final entry in query.entries) {
          if (!namesAndKind.$1.contains(entry.key.toLowerCase())) continue;
          if (namesAndKind.$2 == _PaginationKind.cursor) {
            final first = requests.firstWhere(
              (candidate) => candidate.requestUri?.queryParameters[entry.key]?.isEmpty == true,
              orElse: () => request,
            );
            return _PaginationStrategy(
              namesAndKind.$2,
              entry.key,
              first,
              first.requestUri?.queryParameters[entry.key] ?? entry.value,
              1,
            );
          }
          final values = requests
              .map((candidate) => int.tryParse(candidate.requestUri?.queryParameters[entry.key] ?? ''))
              .whereType<int>()
              .toList();
          final start = values.isEmpty ? int.tryParse(entry.value) ?? 0 : values.reduce((a, b) => a < b ? a : b);
          final limit = int.tryParse(query['limit'] ?? query['pageSize'] ?? query['pagesize'] ?? '') ?? 20;
          return _PaginationStrategy(namesAndKind.$2, entry.key, request, '$start', limit);
        }
      }
    }
    return null;
  }

  static _RecordListCandidate? _findBestRecordList(dynamic root) {
    final candidates = <_RecordListCandidate>[];
    void visit(dynamic node, String path, int depth) {
      if (depth > 6) return;
      if (node is List) {
        final records = node.whereType<Map>().map((item) => Map<String, dynamic>.from(item)).toList();
        if (records.isNotEmpty) candidates.add(_RecordListCandidate(path.isEmpty ? r'$' : path, records));
        if (node.isNotEmpty) visit(node.first, '$path[]', depth + 1);
      } else if (node is Map) {
        for (final entry in node.entries) {
          final childPath = path.isEmpty ? entry.key.toString() : '$path.${entry.key}';
          visit(entry.value, childPath, depth + 1);
        }
      }
    }

    visit(root, '', 0);
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) {
      final count = b.records.length.compareTo(a.records.length);
      if (count != 0) return count;
      return b.records.first.length.compareTo(a.records.first.length);
    });
    return candidates.first;
  }

  static String? _detectIdField(List<Map<String, dynamic>> records) {
    if (records.isEmpty) return null;
    const candidates = ['id', '_id', 'recordId', 'record_id', 'uuid', 'code'];
    for (final candidate in candidates) {
      if (records.every((record) => record[candidate] != null)) return candidate;
    }
    return null;
  }

  static void _flatten(Map record, String prefix, Map<String, dynamic> output) {
    for (final entry in record.entries) {
      final key = prefix.isEmpty ? entry.key.toString() : '$prefix.${entry.key}';
      final value = entry.value;
      if (value is Map) {
        _flatten(value, key, output);
      } else {
        output[key] = value;
      }
    }
  }

  static void _redact(Map<String, dynamic> record) {
    final sensitive =
        RegExp(r'(^|\.)(authorization|cookie|token|access_token|refresh_token|password|secret)$', caseSensitive: false);
    for (final key in record.keys.toList()) {
      if (sensitive.hasMatch(key)) record[key] = '[REDACTED]';
    }
  }

  static void _findPaginationFields(dynamic node, String path, Set<String> output, int depth) {
    if (depth > 4) return;
    const candidates = {'page', 'pageno', 'pagesize', 'limit', 'offset', 'cursor', 'nextcursor', 'hasmore', 'total'};
    if (node is Map) {
      for (final entry in node.entries) {
        final key = entry.key.toString();
        final normalized = key.toLowerCase().replaceAll('_', '');
        final childPath = path.isEmpty ? key : '$path.$key';
        if (candidates.contains(normalized)) output.add(childPath);
        _findPaginationFields(entry.value, childPath, output, depth + 1);
      }
    }
  }
}

class _RecordListCandidate {
  final String path;
  final List<Map<String, dynamic>> records;

  const _RecordListCandidate(this.path, this.records);
}

enum _PaginationKind { page, offset, cursor }

class _PaginationStrategy {
  final _PaginationKind kind;
  final String parameter;
  final HttpRequest template;
  final String startValue;
  final int step;

  const _PaginationStrategy(this.kind, this.parameter, this.template, this.startValue, this.step);
}

class PaginationRunResult {
  final List<HttpRequest> requests;
  final int pagesFetched;
  final String stopReason;

  const PaginationRunResult({required this.requests, required this.pagesFetched, required this.stopReason});
}
