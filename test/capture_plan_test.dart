import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/features/workbench/domain/capture_plan.dart';
import 'package:proxypin/features/workbench/domain/capture_project.dart';

void main() {
  group('采集方案域名匹配', () {
    test('精确域名和通配子域按 host 边界匹配', () {
      expect(
        CaptureDomainMatcher.matches('API.EXAMPLE.COM.', includeDomains: const ['*.example.com']),
        isTrue,
      );
      expect(
        CaptureDomainMatcher.matches('example.com', includeDomains: const ['*.example.com']),
        isTrue,
      );
      expect(
        CaptureDomainMatcher.matches('evil-example.com', includeDomains: const ['*.example.com']),
        isFalse,
      );
      expect(
        CaptureDomainMatcher.matches('api.example.com', includeDomains: const ['example.com']),
        isFalse,
      );
    });

    test('排除规则优先且空白采集范围不会匹配全部', () {
      expect(
        CaptureDomainMatcher.matches(
          'log.example.com',
          includeDomains: const ['*.example.com'],
          excludeDomains: const ['log.example.com'],
        ),
        isFalse,
      );
      expect(CaptureDomainMatcher.matches('api.example.com', includeDomains: const []), isFalse);
      expect(CaptureDomainMatcher.isValidPattern('https://api.example.com/path'), isFalse);
    });
  });

  test('采集方案 JSON 往返保留开关、范围和步骤', () {
    const source = CapturePlan(
      id: 'custom.demo',
      name: 'Demo',
      appName: 'Example',
      description: '说明',
      enabled: false,
      includeDomains: ['b.example.com', '*.example.com'],
      excludeDomains: ['log.example.com'],
      steps: [CapturePlanStep(id: 'open', title: '打开页面', description: '滚动列表')],
    );

    final restored = CapturePlan.fromJson(source.toJson());

    expect(restored.id, source.id);
    expect(restored.enabled, isFalse);
    expect(restored.includeDomains, ['*.example.com', 'b.example.com']);
    expect(restored.excludeDomains, ['log.example.com']);
    expect(restored.steps.single.title, '打开页面');
  });

  test('抓包项目保存方案快照和过滤计数', () {
    final source = CaptureProject(
      id: 'project-1',
      name: '示例育儿应用归档',
      createdAt: DateTime.utc(2026, 8, 20),
      status: CaptureProjectStatus.completed,
      requestCount: 12,
      persistedCount: 12,
      ignoredRequestCount: 40,
      domains: {'api.baby-care.example'},
      planId: BuiltInCapturePlans.babyCareExample.id,
      planName: BuiltInCapturePlans.babyCareExample.name,
      includeDomains: const ['*.baby-care.example'],
    );

    final restored = CaptureProject.fromJson(source.toJson());

    expect(restored.usesPlan, isTrue);
    expect(restored.ignoredRequestCount, 40);
    expect(restored.includeDomains, ['*.baby-care.example']);
    expect(restored.domains, {'api.baby-care.example'});
  });

  test('示例育儿应用内置方案只匹配配置的域名边界', () {
    expect(BuiltInCapturePlans.babyCareExample.matchesHost('api.baby-care.example'), isTrue);
    expect(BuiltInCapturePlans.babyCareExample.matchesHost('evilbaby-care.example'), isFalse);
  });

  test('旧版内置日常记录方案可被识别并迁移为匿名示例', () {
    const legacy = CapturePlan(
      id: 'builtin.legacy.daily-records',
      name: '旧版方案',
      appName: '旧版应用',
      description: '旧版说明',
      builtIn: true,
      includeDomains: ['*.legacy.example'],
      steps: [
        CapturePlanStep(id: 'connection', title: '连接', description: ''),
        CapturePlanStep(id: 'feeding', title: '记录一', description: ''),
        CapturePlanStep(id: 'diaper', title: '记录二', description: ''),
        CapturePlanStep(id: 'archive', title: '归档', description: ''),
      ],
    );

    expect(BuiltInCapturePlans.isLegacyDailyRecordsPlan(legacy), isTrue);
    expect(BuiltInCapturePlans.isLegacyDailyRecordsPlan(BuiltInCapturePlans.babyCareExample), isFalse);
  });
}
