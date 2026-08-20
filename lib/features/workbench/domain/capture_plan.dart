class CapturePlanStep {
  final String id;
  final String title;
  final String description;

  const CapturePlanStep({required this.id, required this.title, required this.description});

  factory CapturePlanStep.fromJson(Map<String, dynamic> json) => CapturePlanStep(
        id: json['id']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        description: json['description']?.toString() ?? '',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'description': description,
      };
}

class CapturePlan {
  static const int currentSchemaVersion = 1;

  final int schemaVersion;
  final String id;
  final String name;
  final String appName;
  final String description;
  final bool enabled;
  final bool builtIn;
  final List<String> includeDomains;
  final List<String> excludeDomains;
  final List<CapturePlanStep> steps;

  const CapturePlan({
    this.schemaVersion = currentSchemaVersion,
    required this.id,
    required this.name,
    required this.appName,
    required this.description,
    this.enabled = true,
    this.builtIn = false,
    required this.includeDomains,
    this.excludeDomains = const [],
    this.steps = const [],
  });

  factory CapturePlan.fromJson(Map<String, dynamic> json) => CapturePlan(
        schemaVersion: json['schemaVersion'] as int? ?? currentSchemaVersion,
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '未命名方案',
        appName: json['appName']?.toString() ?? '',
        description: json['description']?.toString() ?? '',
        enabled: json['enabled'] != false,
        builtIn: json['builtIn'] == true,
        includeDomains: _domainList(json['includeDomains']),
        excludeDomains: _domainList(json['excludeDomains']),
        steps: (json['steps'] as List? ?? const [])
            .whereType<Map>()
            .map((item) => CapturePlanStep.fromJson(Map<String, dynamic>.from(item)))
            .toList(growable: false),
      );

  CapturePlan copyWith({
    String? name,
    String? appName,
    String? description,
    bool? enabled,
    List<String>? includeDomains,
    List<String>? excludeDomains,
    List<CapturePlanStep>? steps,
  }) =>
      CapturePlan(
        schemaVersion: schemaVersion,
        id: id,
        name: name ?? this.name,
        appName: appName ?? this.appName,
        description: description ?? this.description,
        enabled: enabled ?? this.enabled,
        builtIn: builtIn,
        includeDomains: includeDomains ?? this.includeDomains,
        excludeDomains: excludeDomains ?? this.excludeDomains,
        steps: steps ?? this.steps,
      );

  bool matchesHost(String host) => CaptureDomainMatcher.matches(
        host,
        includeDomains: includeDomains,
        excludeDomains: excludeDomains,
      );

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'id': id,
        'name': name,
        'appName': appName,
        'description': description,
        'enabled': enabled,
        'builtIn': builtIn,
        'includeDomains': [...includeDomains]..sort(),
        'excludeDomains': [...excludeDomains]..sort(),
        'steps': steps.map((step) => step.toJson()).toList(growable: false),
      };

  static List<String> _domainList(dynamic value) => (value as List? ?? const [])
      .map((item) => CaptureDomainMatcher.normalizePattern(item.toString()))
      .where((item) => item.isNotEmpty)
      .toSet()
      .toList()
    ..sort();
}

class CaptureDomainMatcher {
  const CaptureDomainMatcher._();

  static String normalizePattern(String value) {
    var normalized = value.trim().toLowerCase();
    while (normalized.endsWith('.')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  static bool isValidPattern(String value) {
    final normalized = normalizePattern(value);
    if (normalized.isEmpty || normalized.contains(RegExp(r'[/\\\s:?#\[\]]'))) return false;
    final host = normalized.startsWith('*.') ? normalized.substring(2) : normalized;
    if (host.isEmpty || host.startsWith('.') || host.endsWith('.') || host.contains('..')) return false;
    return RegExp(r'^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$').hasMatch(host);
  }

  static bool matches(
    String host, {
    required Iterable<String> includeDomains,
    Iterable<String> excludeDomains = const [],
  }) {
    final normalizedHost = normalizePattern(host);
    if (normalizedHost.isEmpty) return false;
    final includes = includeDomains.map(normalizePattern).where(isValidPattern).toList(growable: false);
    if (includes.isEmpty || !includes.any((pattern) => _matchesPattern(normalizedHost, pattern))) return false;
    final excludes = excludeDomains.map(normalizePattern).where(isValidPattern);
    return !excludes.any((pattern) => _matchesPattern(normalizedHost, pattern));
  }

  static bool _matchesPattern(String host, String pattern) {
    if (!pattern.startsWith('*.')) return host == pattern;
    final suffix = pattern.substring(2);
    return host == suffix || host.endsWith('.$suffix');
  }
}

class BuiltInCapturePlans {
  const BuiltInCapturePlans._();

  static const babyCareExample = CapturePlan(
    id: 'builtin.example-baby-care.daily-records',
    name: '示例育儿应用 · 日常记录归档',
    appName: '示例育儿应用',
    description: '手动打开喂奶和换尿布记录页，将相关请求保存到独立项目；不会自动操作 App、重放接口或修改线上数据。',
    builtIn: true,
    includeDomains: ['*.baby-care.example'],
    steps: [
      CapturePlanStep(
        id: 'connection',
        title: '确认手机已连接',
        description: '先确认手机流量能进入 ProxyPin，HTTPS 正文可见，再关闭其他 App 的后台活动。',
      ),
      CapturePlanStep(
        id: 'feeding',
        title: '采集喂奶记录',
        description: '在示例育儿应用中打开喂奶记录列表，按需要切换日期并滚动到目标时间范围。',
      ),
      CapturePlanStep(
        id: 'diaper',
        title: '采集换尿布记录',
        description: '打开换尿布记录列表，同样覆盖需要导出的日期范围。',
      ),
      CapturePlanStep(
        id: 'archive',
        title: '结束并核对归档',
        description: '结束采集后，到抓包项目查看请求数量，再从数据导出页选择该归档。',
      ),
    ],
  );

  static const values = [babyCareExample];

  /// 兼容早期版本持久化过的同类内置方案，同时避免继续展示旧业务名称和域名。
  static bool isLegacyDailyRecordsPlan(CapturePlan plan) {
    if (!plan.builtIn || plan.id == babyCareExample.id) return false;
    final stepIds = plan.steps.map((step) => step.id).toSet();
    return stepIds.containsAll(const {'connection', 'feeding', 'diaper', 'archive'});
  }
}
