enum CaptureProjectStatus { active, completed, interrupted }

class CaptureProject {
  final String id;
  String name;
  final DateTime createdAt;
  DateTime? endedAt;
  CaptureProjectStatus status;
  int requestCount;
  int persistedCount;
  int ignoredRequestCount;
  final Set<String> domains;
  final String? planId;
  final String? planName;
  final List<String> includeDomains;
  final List<String> excludeDomains;
  String? historyPath;

  CaptureProject({
    required this.id,
    required this.name,
    required this.createdAt,
    this.endedAt,
    this.status = CaptureProjectStatus.active,
    this.requestCount = 0,
    this.persistedCount = 0,
    this.ignoredRequestCount = 0,
    Set<String>? domains,
    this.planId,
    this.planName,
    List<String>? includeDomains,
    List<String>? excludeDomains,
    this.historyPath,
  })  : domains = domains ?? <String>{},
        includeDomains = includeDomains ?? const [],
        excludeDomains = excludeDomains ?? const [];

  factory CaptureProject.fromJson(Map<String, dynamic> json) => CaptureProject(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '未命名项目',
        createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ?? DateTime.now(),
        endedAt: DateTime.tryParse(json['endedAt']?.toString() ?? ''),
        status: CaptureProjectStatus.values.firstWhere(
          (value) => value.name == json['status'],
          orElse: () => CaptureProjectStatus.interrupted,
        ),
        requestCount: json['requestCount'] as int? ?? 0,
        persistedCount: json['persistedCount'] as int? ?? 0,
        ignoredRequestCount: json['ignoredRequestCount'] as int? ?? 0,
        domains: (json['domains'] as List?)?.map((value) => value.toString()).toSet(),
        planId: json['planId']?.toString(),
        planName: json['planName']?.toString(),
        includeDomains: (json['includeDomains'] as List?)?.map((value) => value.toString()).toList(),
        excludeDomains: (json['excludeDomains'] as List?)?.map((value) => value.toString()).toList(),
        historyPath: json['historyPath']?.toString(),
      );

  bool get usesPlan => planId?.isNotEmpty == true;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'createdAt': createdAt.toIso8601String(),
        'endedAt': endedAt?.toIso8601String(),
        'status': status.name,
        'requestCount': requestCount,
        'persistedCount': persistedCount,
        'ignoredRequestCount': ignoredRequestCount,
        'domains': domains.toList()..sort(),
        'planId': planId,
        'planName': planName,
        'includeDomains': [...includeDomains]..sort(),
        'excludeDomains': [...excludeDomains]..sort(),
        'historyPath': historyPath,
      };
}
