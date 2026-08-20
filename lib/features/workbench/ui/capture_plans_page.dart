import 'package:flutter/material.dart';
import 'package:proxypin/features/workbench/domain/capture_plan.dart';
import 'package:proxypin/features/workbench/domain/capture_project.dart';
import 'package:proxypin/features/workbench/logic/capture_project_controller.dart';

class CapturePlansPage extends StatefulWidget {
  final VoidCallback onOpenHistory;
  final VoidCallback onOpenExport;

  const CapturePlansPage({
    super.key,
    required this.onOpenHistory,
    required this.onOpenExport,
  });

  @override
  State<CapturePlansPage> createState() => _CapturePlansPageState();
}

class _CapturePlansPageState extends State<CapturePlansPage> {
  final CaptureProjectController controller = CaptureProjectController.instance;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Column(children: [
        _header(),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              _privacyNotice(),
              const SizedBox(height: 14),
              ...controller.plans.map((plan) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _CapturePlanCard(
                      plan: plan,
                      activeProject: controller.activeProject,
                      onToggle: (enabled) => _togglePlan(plan, enabled),
                      onStart: () => _startPlan(plan),
                      onStop: _stopPlan,
                      onEdit: plan.builtIn ? null : () => _editPlan(plan),
                      onDelete: plan.builtIn ? null : () => _deletePlan(plan),
                      onOpenHistory: widget.onOpenHistory,
                      onOpenExport: widget.onOpenExport,
                    ),
                  )),
            ],
          ),
        ),
      ]),
    );
  }

  Widget _header() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 16, 12),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('采集方案', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text('把一组域名、手动步骤和独立归档复用为下次任务', style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
          FilledButton.icon(
            onPressed: () => _editPlan(null),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('新建方案'),
          ),
        ]),
      );

  Widget _privacyNotice() => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.shield_outlined, size: 20),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              '方案配置不保存 Cookie、Authorization、token 或响应正文；原始采集归档会写入本机，可能包含登录态和个人数据，请只在自己的设备上使用并妥善保管。',
            ),
          ),
        ]),
      );

  Future<void> _togglePlan(CapturePlan plan, bool enabled) async {
    try {
      await controller.setPlanEnabled(plan, enabled);
    } catch (error) {
      if (mounted) _showMessage('$error');
    }
  }

  Future<void> _startPlan(CapturePlan plan) async {
    try {
      await controller.startPlan(plan);
    } catch (error) {
      if (mounted) _showMessage('$error');
    }
  }

  Future<void> _stopPlan() async {
    try {
      await controller.stop();
      if (mounted) _showMessage('采集已结束，请到数据导出选择刚保存的项目');
    } catch (error) {
      if (mounted) _showMessage('归档失败：$error');
    }
  }

  Future<void> _editPlan(CapturePlan? plan) async {
    final value = await showDialog<_PlanFormValue>(
      context: context,
      builder: (_) => _CapturePlanDialog(plan: plan),
    );
    if (value == null) return;
    try {
      if (plan == null) {
        await controller.createPlan(
          name: value.name,
          appName: value.appName,
          description: value.description,
          includeDomains: value.includeDomains,
          excludeDomains: value.excludeDomains,
        );
      } else {
        await controller.updatePlan(
          plan,
          name: value.name,
          appName: value.appName,
          description: value.description,
          includeDomains: value.includeDomains,
          excludeDomains: value.excludeDomains,
        );
      }
    } catch (error) {
      if (mounted) _showMessage('$error');
    }
  }

  Future<void> _deletePlan(CapturePlan plan) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除采集方案'),
        content: Text('删除“${plan.name}”？已经生成的抓包项目和归档不会被删除。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('删除')),
        ],
      ),
    );
    if (confirmed == true) await controller.deletePlan(plan);
  }

  void _showMessage(String message) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

class _CapturePlanCard extends StatelessWidget {
  final CapturePlan plan;
  final CaptureProject? activeProject;
  final ValueChanged<bool> onToggle;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback onOpenHistory;
  final VoidCallback onOpenExport;

  const _CapturePlanCard({
    required this.plan,
    required this.activeProject,
    required this.onToggle,
    required this.onStart,
    required this.onStop,
    required this.onEdit,
    required this.onDelete,
    required this.onOpenHistory,
    required this.onOpenExport,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isRunning = activeProject?.planId == plan.id;
    final anotherRunning = activeProject != null && !isRunning;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(Icons.inventory_2_outlined, color: theme.colorScheme.primary),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(
                    child: Text(plan.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                  ),
                  if (plan.builtIn) ...[
                    const SizedBox(width: 8),
                    const Chip(label: Text('内置', style: TextStyle(fontSize: 10)), visualDensity: VisualDensity.compact),
                  ],
                  if (isRunning) ...[
                    const SizedBox(width: 8),
                    const Chip(
                      avatar: Icon(Icons.circle, size: 9, color: Colors.green),
                      label: Text('采集中', style: TextStyle(fontSize: 10)),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ]),
                const SizedBox(height: 4),
                Text(plan.description, style: theme.textTheme.bodySmall),
              ]),
            ),
            Tooltip(
              message: isRunning ? '请先结束当前采集' : '方案可用',
              child: Switch(value: plan.enabled, onChanged: isRunning ? null : onToggle),
            ),
            if (onEdit != null || onDelete != null)
              PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'edit') onEdit?.call();
                  if (value == 'delete') onDelete?.call();
                },
                itemBuilder: (_) => [
                  if (onEdit != null) const PopupMenuItem(value: 'edit', child: Text('编辑方案')),
                  if (onDelete != null) const PopupMenuItem(value: 'delete', child: Text('删除方案')),
                ],
              ),
          ]),
          const SizedBox(height: 14),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              ...plan.includeDomains.map((domain) => Chip(
                    avatar: const Icon(Icons.check_circle_outline, size: 15),
                    label: Text(domain, style: const TextStyle(fontSize: 11)),
                    visualDensity: VisualDensity.compact,
                  )),
              ...plan.excludeDomains.map((domain) => Chip(
                    avatar: const Icon(Icons.block, size: 15),
                    label: Text('排除 $domain', style: const TextStyle(fontSize: 11)),
                    visualDensity: VisualDensity.compact,
                  )),
            ],
          ),
          if (plan.steps.isNotEmpty) ...[
            const SizedBox(height: 10),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 8),
              title:
                  Text('${plan.steps.length} 个手动步骤', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              children: plan.steps
                  .asMap()
                  .entries
                  .map((entry) => ListTile(
                        dense: true,
                        contentPadding: const EdgeInsets.only(left: 8, right: 8),
                        leading: CircleAvatar(
                            radius: 11, child: Text('${entry.key + 1}', style: const TextStyle(fontSize: 10))),
                        title:
                            Text(entry.value.title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                        subtitle: Text(entry.value.description, style: const TextStyle(fontSize: 11)),
                      ))
                  .toList(growable: false),
            ),
          ],
          if (isRunning) ...[
            const Divider(height: 22),
            Text(
              '${activeProject!.requestCount} 条匹配请求 · ${activeProject!.persistedCount} 条已写盘 · '
              '${activeProject!.ignoredRequestCount} 条无关请求已过滤',
              style: theme.textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 14),
          Row(children: [
            if (isRunning)
              FilledButton.tonalIcon(
                onPressed: onStop,
                icon: const Icon(Icons.stop_circle_outlined, size: 18),
                label: const Text('结束并归档'),
              )
            else
              FilledButton.icon(
                onPressed: plan.enabled && !anotherRunning ? onStart : null,
                icon: const Icon(Icons.play_arrow_rounded, size: 19),
                label: const Text('开始采集'),
              ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: onOpenHistory,
              icon: const Icon(Icons.folder_open_outlined, size: 17),
              label: const Text('打开归档'),
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: onOpenExport,
              icon: const Icon(Icons.file_download_outlined, size: 17),
              label: const Text('数据导出'),
            ),
            if (anotherRunning) ...[
              const SizedBox(width: 10),
              Text('已有其他项目正在记录', style: theme.textTheme.bodySmall),
            ],
          ]),
        ]),
      ),
    );
  }
}

class _CapturePlanDialog extends StatefulWidget {
  final CapturePlan? plan;

  const _CapturePlanDialog({this.plan});

  @override
  State<_CapturePlanDialog> createState() => _CapturePlanDialogState();
}

class _CapturePlanDialogState extends State<_CapturePlanDialog> {
  late final TextEditingController nameController;
  late final TextEditingController appController;
  late final TextEditingController descriptionController;
  late final TextEditingController includeController;
  late final TextEditingController excludeController;
  String? error;

  @override
  void initState() {
    super.initState();
    final plan = widget.plan;
    nameController = TextEditingController(text: plan?.name);
    appController = TextEditingController(text: plan?.appName);
    descriptionController = TextEditingController(text: plan?.description);
    includeController = TextEditingController(text: plan?.includeDomains.join('\n'));
    excludeController = TextEditingController(text: plan?.excludeDomains.join('\n'));
  }

  @override
  void dispose() {
    nameController.dispose();
    appController.dispose();
    descriptionController.dispose();
    includeController.dispose();
    excludeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.plan == null ? '新建采集方案' : '编辑采集方案'),
        content: SizedBox(
          width: 540,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  controller: nameController, autofocus: true, decoration: const InputDecoration(labelText: '方案名称')),
              const SizedBox(height: 10),
              TextField(controller: appController, decoration: const InputDecoration(labelText: 'App 名称（可选）')),
              const SizedBox(height: 10),
              TextField(
                controller: descriptionController,
                minLines: 2,
                maxLines: 3,
                decoration: const InputDecoration(labelText: '说明'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: includeController,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: '采集域名',
                  hintText: '每行一个，例如 api.example.com 或 *.example.com',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: excludeController,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(labelText: '排除域名（可选）'),
              ),
              if (error != null) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
              ],
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(onPressed: _submit, child: const Text('保存')),
        ],
      );

  void _submit() {
    final includes = _splitDomains(includeController.text);
    final invalid = includes.where((value) => !CaptureDomainMatcher.isValidPattern(value)).toList();
    if (nameController.text.trim().isEmpty || includes.isEmpty || invalid.isNotEmpty) {
      setState(() {
        error = invalid.isNotEmpty ? '无效域名：${invalid.join('、')}' : '请填写方案名称和至少一个采集域名';
      });
      return;
    }
    final excludes = _splitDomains(excludeController.text);
    final invalidExcludes = excludes.where((value) => !CaptureDomainMatcher.isValidPattern(value)).toList();
    if (invalidExcludes.isNotEmpty) {
      setState(() => error = '无效排除域名：${invalidExcludes.join('、')}');
      return;
    }
    Navigator.pop(
      context,
      _PlanFormValue(
        name: nameController.text.trim(),
        appName: appController.text.trim(),
        description: descriptionController.text.trim(),
        includeDomains: includes,
        excludeDomains: excludes,
      ),
    );
  }

  List<String> _splitDomains(String value) => value
      .split(RegExp(r'[,;\n]'))
      .map(CaptureDomainMatcher.normalizePattern)
      .where((item) => item.isNotEmpty)
      .toSet()
      .toList(growable: false);
}

class _PlanFormValue {
  final String name;
  final String appName;
  final String description;
  final List<String> includeDomains;
  final List<String> excludeDomains;

  const _PlanFormValue({
    required this.name,
    required this.appName,
    required this.description,
    required this.includeDomains,
    required this.excludeDomains,
  });
}
