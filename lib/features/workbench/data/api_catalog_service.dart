import 'dart:convert';
import 'dart:isolate';

import 'package:proxypin/features/workbench/domain/api_endpoint_asset.dart';
import 'package:proxypin/network/http/http.dart';

class ApiCatalogService {
  const ApiCatalogService();

  Future<List<ApiEndpointAsset>> analyze(Iterable<HttpRequest> requests) async {
    final snapshots = requests.map(_snapshot).toList(growable: false);
    final rawAssets = await Isolate.run(() => _buildCatalog(snapshots));
    return rawAssets.map(_assetFromMap).toList(growable: false);
  }

  static Map<String, dynamic> _snapshot(HttpRequest request) {
    final response = request.response;
    final requestBody = request.body != null && request.body!.length <= 256 * 1024 ? request.getBodyString() : null;
    final responseBody =
        response?.body != null && response!.body!.length <= 512 * 1024 ? response.getBodyString() : null;
    final requestTime = request.requestTime;
    final responseTime = response?.responseTime;
    return {
      'method': request.method.name.toUpperCase(),
      'url': request.requestUrl,
      'status': response?.status.code,
      'duration': responseTime == null ? 0 : responseTime.difference(requestTime).inMilliseconds,
      'queryFields': request.requestUri?.queryParametersAll.keys.toList() ?? const <String>[],
      'headerNames': request.headers.getHeaders().keys.map((value) => value.toLowerCase()).toList(),
      'requestBody': requestBody,
      'responseBody': responseBody,
    };
  }

  static List<Map<String, dynamic>> _buildCatalog(List<Map<String, dynamic>> snapshots) {
    final grouped = <String, _MutableEndpoint>{};
    for (final snapshot in snapshots) {
      final uri = Uri.tryParse(snapshot['url']?.toString() ?? '');
      if (uri == null || uri.host.isEmpty) continue;
      final method = snapshot['method']?.toString() ?? 'GET';
      final path = normalizePath(uri.path);
      final key = '$method ${uri.host}$path';
      final endpoint = grouped.putIfAbsent(
        key,
        () => _MutableEndpoint(key: key, method: method, host: uri.host, path: path, exampleUrl: uri.toString()),
      );
      endpoint.count++;
      final status = snapshot['status'];
      if (status is int) endpoint.statuses[status] = (endpoint.statuses[status] ?? 0) + 1;
      endpoint.durationTotal += snapshot['duration'] as int? ?? 0;
      endpoint.queryFields.addAll((snapshot['queryFields'] as List? ?? const []).map((value) => value.toString()));

      final headers = (snapshot['headerNames'] as List? ?? const []).map((value) => value.toString()).toSet();
      for (final signal in const ['authorization', 'cookie', 'x-api-key', 'token']) {
        if (headers.any((header) => header == signal || header.contains(signal))) endpoint.authSignals.add(signal);
      }

      endpoint.requestFields.addAll(_jsonFields(snapshot['requestBody']?.toString()));
      endpoint.responseFields.addAll(_jsonFields(snapshot['responseBody']?.toString()));
      endpoint.paginationSignals.addAll(_paginationSignals(
        endpoint.queryFields,
        endpoint.requestFields,
        endpoint.responseFields,
      ));
    }

    final assets = grouped.values.map((endpoint) => endpoint.toMap()).toList();
    assets.sort((a, b) => (b['requestCount'] as int).compareTo(a['requestCount'] as int));
    return assets;
  }

  static String normalizePath(String path) {
    if (path.isEmpty) return '/';
    final uuid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F-]{20,}$');
    final longToken = RegExp(r'^[A-Za-z0-9_-]{20,}$');
    return path.split('/').map((segment) {
      if (segment.isEmpty) return segment;
      if (int.tryParse(segment) != null || uuid.hasMatch(segment) || longToken.hasMatch(segment)) return '{id}';
      return segment;
    }).join('/');
  }

  static Set<String> _jsonFields(String? text) {
    if (text == null || text.trim().isEmpty) return {};
    try {
      final value = jsonDecode(text);
      final fields = <String>{};
      void visit(dynamic node, String prefix, int depth) {
        if (depth > 4 || fields.length >= 80) return;
        if (node is Map) {
          for (final entry in node.entries) {
            final key = entry.key.toString();
            final path = prefix.isEmpty ? key : '$prefix.$key';
            fields.add(path);
            visit(entry.value, path, depth + 1);
          }
        } else if (node is List && node.isNotEmpty) {
          visit(node.first, prefix, depth + 1);
        }
      }

      visit(value, '', 0);
      return fields;
    } catch (_) {
      return {};
    }
  }

  static Set<String> _paginationSignals(Set<String> query, Set<String> request, Set<String> response) {
    const candidates = ['page', 'pageno', 'pagesize', 'limit', 'offset', 'cursor', 'nextcursor', 'hasmore', 'total'];
    final all = {...query, ...request, ...response};
    return all.where((field) {
      final leaf = field.split('.').last.toLowerCase().replaceAll('_', '');
      return candidates.contains(leaf);
    }).toSet();
  }

  static ApiEndpointAsset _assetFromMap(Map<String, dynamic> map) => ApiEndpointAsset(
        key: map['key'] as String,
        method: map['method'] as String,
        host: map['host'] as String,
        normalizedPath: map['normalizedPath'] as String,
        exampleUrl: map['exampleUrl'] as String,
        requestCount: map['requestCount'] as int,
        statusCounts: Map<int, int>.from(map['statusCounts'] as Map),
        queryFields: Set<String>.from(map['queryFields'] as List),
        requestFields: Set<String>.from(map['requestFields'] as List),
        responseFields: Set<String>.from(map['responseFields'] as List),
        authSignals: Set<String>.from(map['authSignals'] as List),
        paginationSignals: Set<String>.from(map['paginationSignals'] as List),
        averageDurationMs: map['averageDurationMs'] as int,
      );
}

class _MutableEndpoint {
  final String key;
  final String method;
  final String host;
  final String path;
  final String exampleUrl;
  int count = 0;
  int durationTotal = 0;
  final Map<int, int> statuses = {};
  final Set<String> queryFields = {};
  final Set<String> requestFields = {};
  final Set<String> responseFields = {};
  final Set<String> authSignals = {};
  final Set<String> paginationSignals = {};

  _MutableEndpoint(
      {required this.key, required this.method, required this.host, required this.path, required this.exampleUrl});

  Map<String, dynamic> toMap() => {
        'key': key,
        'method': method,
        'host': host,
        'normalizedPath': path,
        'exampleUrl': exampleUrl,
        'requestCount': count,
        'statusCounts': statuses,
        'queryFields': queryFields.toList()..sort(),
        'requestFields': requestFields.toList()..sort(),
        'responseFields': responseFields.toList()..sort(),
        'authSignals': authSignals.toList()..sort(),
        'paginationSignals': paginationSignals.toList()..sort(),
        'averageDurationMs': count == 0 ? 0 : durationTotal ~/ count,
      };
}
