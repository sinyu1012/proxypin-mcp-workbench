class ExportDataset {
  final String endpointKey;
  final List<Map<String, dynamic>> records;
  final List<String> fields;
  final int matchedRequests;
  final int rawRecordCount;
  final int duplicateCount;
  final String? detectedRecordPath;
  final Set<String> paginationSignals;

  const ExportDataset({
    required this.endpointKey,
    required this.records,
    required this.fields,
    required this.matchedRequests,
    required this.rawRecordCount,
    required this.duplicateCount,
    required this.detectedRecordPath,
    required this.paginationSignals,
  });
}
