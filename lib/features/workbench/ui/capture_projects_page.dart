import 'package:flutter/material.dart';
import 'package:proxypin/features/workbench/domain/capture_project.dart';
import 'package:proxypin/features/workbench/logic/capture_project_controller.dart';

class CaptureProjectsPage extends StatefulWidget {
  final VoidCallback onOpenHistory;

  const CaptureProjectsPage({super.key, required this.onOpenHistory});

  @override
  State<CaptureProjectsPage> createState() => _CaptureProjectsPageState();
}

class _CaptureProjectsPageState extends State<CaptureProjectsPage> {
  final CaptureProjectController controller = CaptureProjectController.instance;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final active = controller.activeProject;
        return Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 16, 12),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('抓包项目', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text('按任务隔离、持续保存并随时恢复请求', style: Theme.of(context).textTheme.bodySmall),
                ]),
              ),
              if (active == null)
                FilledButton.icon(
                  onPressed: _createProject,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('新建项目'),
                )
              else
                FilledButton.tonalIcon(
                  onPressed: _stopProject,
                  icon: const Icon(Icons.stop_circle_outlined, size: 18),
                  label: const Text('结束当前项目'),
                ),
            ]),
          ),
          const Divider(height: 1),
          Expanded(
            child: controller.projects.isEmpty
                ? _EmptyProjects(onCreate: _createProject)
                : CustomScrollView(slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.all(20),
                      sliver: SliverList.list(children: [
                        if (active != null) ...[
                          _ActiveProjectBanner(project: active, onStop: _stopProject),
                          const SizedBox(height: 18),
                        ],
                        Text('全部项目',
                            style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 10),
                        ...controller.projects.map((project) => Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: _ProjectCard(
                                project: project,
                                onOpen: widget.onOpenHistory,
                                onRename: () => _renameProject(project),
                              ),
                            )),
                      ]),
                    ),
                  ]),
          ),
        ]);
      },
    );
  }

  Future<void> _createProject() async {
    final name = await _showNameDialog('新建抓包项目');
    if (name == null || !mounted) return;
    await controller.start(name);
  }

  Future<void> _renameProject(CaptureProject project) async {
    final name = await _showNameDialog('重命名项目', initialValue: project.name);
    if (name == null) return;
    await controller.rename(project, name);
  }

  Future<void> _stopProject() async {
    try {
      await controller.stop();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('项目保存失败，仍保持记录状态：$error')),
      );
    }
  }

  Future<String?> _showNameDialog(String title, {String? initialValue}) async {
    final textController = TextEditingController(text: initialValue);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: textController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '项目名称',
            hintText: '例如：示例育儿应用 · 日常记录',
            prefixIcon: Icon(Icons.folder_outlined),
          ),
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, textController.text.trim()), child: const Text('开始')),
        ],
      ),
    );
    textController.dispose();
    return result;
  }
}

class _ActiveProjectBanner extends StatelessWidget {
  final CaptureProject project;
  final VoidCallback onStop;

  const _ActiveProjectBanner({required this.project, required this.onStop});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [
          theme.colorScheme.primary.withValues(alpha: 0.16),
          theme.colorScheme.tertiary.withValues(alpha: 0.08),
        ]),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.25)),
      ),
      child: Row(children: [
        Stack(alignment: Alignment.center, children: [
          Container(
              width: 46,
              height: 46,
              decoration:
                  BoxDecoration(color: theme.colorScheme.primary.withValues(alpha: 0.12), shape: BoxShape.circle)),
          Icon(Icons.radio_button_checked, color: theme.colorScheme.primary),
        ]),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('正在记录 · ${project.name}', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 5),
            Text(
                '${project.requestCount} 条请求 · ${project.domains.length} 个域名 · ${project.persistedCount} 条已安全写盘'
                '${project.usesPlan ? ' · ${project.ignoredRequestCount} 条无关请求已过滤' : ''}',
                style: theme.textTheme.bodySmall),
          ]),
        ),
        OutlinedButton.icon(
            onPressed: onStop, icon: const Icon(Icons.stop_rounded, size: 17), label: const Text('结束并保存')),
      ]),
    );
  }
}

class _ProjectCard extends StatelessWidget {
  final CaptureProject project;
  final VoidCallback onOpen;
  final VoidCallback onRename;

  const _ProjectCard({required this.project, required this.onOpen, required this.onRename});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isActive = project.status == CaptureProjectStatus.active;
    final color = switch (project.status) {
      CaptureProjectStatus.active => Colors.green,
      CaptureProjectStatus.completed => theme.colorScheme.primary,
      CaptureProjectStatus.interrupted => Colors.orange,
    };
    final status = switch (project.status) {
      CaptureProjectStatus.active => '记录中',
      CaptureProjectStatus.completed => '已完成',
      CaptureProjectStatus.interrupted => '上次异常中断',
    };

    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: isActive ? null : onOpen,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
              child: Icon(Icons.folder_copy_outlined, color: color, size: 21),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(
                      child: Text(project.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600))),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration:
                        BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
                    child: Text(status, style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600)),
                  ),
                ]),
                const SizedBox(height: 5),
                Text('${_formatDate(project.createdAt)} · ${project.requestCount} 条请求 · ${project.domains.length} 个域名',
                    style: theme.textTheme.bodySmall),
                if (project.usesPlan) ...[
                  const SizedBox(height: 3),
                  Text('采集方案：${project.planName ?? project.planId}', style: theme.textTheme.labelSmall),
                ],
              ]),
            ),
            IconButton(onPressed: onRename, tooltip: '重命名', icon: const Icon(Icons.edit_outlined, size: 18)),
            if (!isActive) const Icon(Icons.chevron_right_rounded, size: 20),
          ]),
        ),
      ),
    );
  }

  static String _formatDate(DateTime value) =>
      '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')} '
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
}

class _EmptyProjects extends StatelessWidget {
  final VoidCallback onCreate;

  const _EmptyProjects({required this.onCreate});

  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.create_new_folder_outlined,
              size: 54, color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.6)),
          const SizedBox(height: 14),
          const Text('为每个抓包任务创建独立项目', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text('请求会在后台分批写盘，清空实时列表也不会丢失项目记录', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 18),
          FilledButton.icon(onPressed: onCreate, icon: const Icon(Icons.add), label: const Text('创建第一个项目')),
        ]),
      );
}
