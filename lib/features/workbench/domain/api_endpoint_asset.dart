class ApiEndpointAsset {
  final String key;
  final String method;
  final String host;
  final String normalizedPath;
  final String exampleUrl;
  final int requestCount;
  final Map<int, int> statusCounts;
  final Set<String> queryFields;
  final Set<String> requestFields;
  final Set<String> responseFields;
  final Set<String> authSignals;
  final Set<String> paginationSignals;
  final int averageDurationMs;

  const ApiEndpointAsset({
    required this.key,
    required this.method,
    required this.host,
    required this.normalizedPath,
    required this.exampleUrl,
    required this.requestCount,
    required this.statusCounts,
    required this.queryFields,
    required this.requestFields,
    required this.responseFields,
    required this.authSignals,
    required this.paginationSignals,
    required this.averageDurationMs,
  });

  bool matches(String keyword) {
    final value = keyword.trim().toLowerCase();
    if (value.isEmpty) return true;
    return '$method $host $normalizedPath ${queryFields.join(' ')} ${responseFields.join(' ')}'
        .toLowerCase()
        .contains(value);
  }
}
