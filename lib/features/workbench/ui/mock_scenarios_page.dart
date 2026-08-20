import 'package:flutter/material.dart';
import 'package:flutter_toastr/flutter_toastr.dart';
import 'package:proxypin/network/components/manager/request_rewrite_manager.dart';
import 'package:proxypin/network/components/manager/rewrite_rule.dart';
import 'package:proxypin/ui/component/multi_window.dart';

class MockScenariosPage extends StatefulWidget {
  const MockScenariosPage({super.key});

  @override
  State<MockScenariosPage> createState() => _MockScenariosPageState();
}

class _MockScenariosPageState extends State<MockScenariosPage> {
  RequestRewriteManager? manager;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final value = await RequestRewriteManager.instance;
    if (mounted) setState(() => manager = value);
  }

  Future<void> _save() async {
    await manager?.flushRequestRewriteConfig();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final current = manager;
    if (current == null) return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    final groups = current.groups.keys.where((name) => name != RequestRewriteManager.ungroupedName).toList();
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(18),
        child: Row(children: [
          Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Mock 场景', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 3),
            Text('将同一业务状态的多条规则组合，并以互斥方式一键切换', style: Theme.of(context).textTheme.bodySmall),
          ])),
          OutlinedButton.icon(
            onPressed: () async {
              current.disableAllGroups();
              await _save();
            },
            icon: const Icon(Icons.power_settings_new, size: 17),
            label: const Text('全部关闭'),
          ),
          const SizedBox(width: 8),
          FilledButton.tonalIcon(
            onPressed: () => MultiWindow.openWindow('Mock 规则', 'RequestRewriteWidget', size: const Size(900, 760)),
            icon: const Icon(Icons.tune, size: 17),
            label: const Text('管理规则'),
          ),
        ]),
      ),
      const Divider(height: 1),
      Expanded(
        child: groups.isEmpty
            ? const _EmptyScenarios()
            : GridView.builder(
                padding: const EdgeInsets.all(18),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 420,
                  mainAxisExtent: 190,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                itemCount: groups.length,
                itemBuilder: (context, index) {
                  final group = groups[index];
                  final rules = current.rules.where((rule) => current.groupNameFor(rule) == group).toList();
                  final enabled = current.groups[group] ?? true;
                  return _ScenarioCard(
                    name: group,
                    enabled: enabled,
                    rules: rules,
                    hitCount: rules.fold(0, (sum, rule) => sum + current.statsFor(rule).hitCount),
                    conflictCount: current.conflictsForGroup(group).length,
                    onToggle: (value) async {
                      current.setGroupEnabled(group, value);
                      await _save();
                    },
                    onActivate: () async {
                      current.activateExclusiveGroup(group);
                      await _save();
                      if (context.mounted) FlutterToastr.show('已切换到“$group”场景', context);
                    },
                  );
                },
              ),
      ),
    ]);
  }
}

class _ScenarioCard extends StatelessWidget {
  final String name;
  final bool enabled;
  final List<RequestRewriteRule> rules;
  final int hitCount;
  final int conflictCount;
  final ValueChanged<bool> onToggle;
  final VoidCallback onActivate;

  const _ScenarioCard({
    required this.name,
    required this.enabled,
    required this.rules,
    required this.hitCount,
    required this.conflictCount,
    required this.onToggle,
    required this.onActivate,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = enabled ? theme.colorScheme.primary : theme.colorScheme.outline;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: enabled ? color.withValues(alpha: 0.07) : theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: color.withValues(alpha: enabled ? 0.35 : 0.15)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(9)),
            child: Icon(Icons.layers_outlined, color: color, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
              child: Text(name,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700))),
          Switch(value: enabled, onChanged: onToggle),
        ]),
        const SizedBox(height: 10),
        Wrap(spacing: 6, runSpacing: 6, children: [
          _badge(context, '${rules.length} 条规则'),
          _badge(context, '命中 $hitCount 次'),
          if (conflictCount > 0) _badge(context, '$conflictCount 个冲突', warning: true),
        ]),
        const Spacer(),
        SizedBox(
          width: double.infinity,
          child: FilledButton.tonalIcon(
            onPressed: onActivate,
            icon: const Icon(Icons.play_arrow_rounded, size: 18),
            label: const Text('独占启用此场景'),
          ),
        ),
      ]),
    );
  }

  Widget _badge(BuildContext context, String text, {bool warning = false}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
            color: (warning ? Colors.orange : Theme.of(context).colorScheme.primary).withValues(alpha: 0.09),
            borderRadius: BorderRadius.circular(20)),
        child: Text(text, style: TextStyle(fontSize: 11, color: warning ? Colors.orange : null)),
      );
}

class _EmptyScenarios extends StatelessWidget {
  const _EmptyScenarios();

  @override
  Widget build(BuildContext context) => const Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.layers_clear_outlined, size: 48, color: Colors.grey),
        SizedBox(height: 12),
        Text('还没有 Mock 场景'),
        SizedBox(height: 4),
        Text('在 Mock 规则中创建合集，即会成为可切换场景'),
      ]));
}
