import 'package:flutter/material.dart';
import 'package:proxypin/network/components/manager/request_rewrite_manager.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/ui/component/multi_window.dart';

class MockDiagnosticsPanel extends StatelessWidget {
  final HttpRequest? request;

  const MockDiagnosticsPanel({super.key, required this.request});

  @override
  Widget build(BuildContext context) {
    final current = request;
    if (current == null) {
      return const _EmptyState();
    }

    return FutureBuilder<RequestRewriteManager>(
      future: RequestRewriteManager.instance,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        final diagnostics = snapshot.data!.diagnose(current);
        return _DiagnosticsBody(diagnostics: diagnostics);
      },
    );
  }
}

class _DiagnosticsBody extends StatelessWidget {
  final RewriteMatchDiagnostics diagnostics;

  const _DiagnosticsBody({required this.diagnostics});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final winner = diagnostics.winner;

    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
          sliver: SliverList.list(children: [
            _SummaryCard(diagnostics: diagnostics),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '规则匹配链路',
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () => MultiWindow.openWindow(
                    'Mock 规则',
                    'RequestRewriteWidget',
                    size: const Size(900, 760),
                  ),
                  icon: const Icon(Icons.tune_rounded, size: 17),
                  label: const Text('管理规则'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (diagnostics.evaluations.isEmpty)
              const _NoRulesCard()
            else
              ...diagnostics.evaluations.map((evaluation) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _RuleCard(evaluation: evaluation),
                  )),
            if (winner == null && diagnostics.evaluations.isNotEmpty) const _HintCard(),
          ]),
        ),
      ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final RewriteMatchDiagnostics diagnostics;

  const _SummaryCard({required this.diagnostics});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final winner = diagnostics.winner;
    final success = winner != null;
    final color = success ? Colors.green : Colors.orange;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: color.withValues(alpha: 0.14), shape: BoxShape.circle),
              child: Icon(success ? Icons.check_rounded : Icons.search_off_rounded, color: color, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(success ? '已命中 Mock 规则' : '没有规则命中',
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text(
                  success
                      ? winner.rule.name?.trim().isNotEmpty == true
                          ? winner.rule.name!
                          : winner.rule.url
                      : '逐项查看下方失败原因',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ]),
            ),
            _StatusChip(label: diagnostics.managerEnabled ? '总开关已开' : '总开关关闭', ok: diagnostics.managerEnabled),
          ]),
          const SizedBox(height: 14),
          _MetaRow(label: 'Method', value: diagnostics.method.name.toUpperCase()),
          const SizedBox(height: 6),
          _MetaRow(label: 'URL', value: diagnostics.url),
          const SizedBox(height: 6),
          _MetaRow(label: 'Request ID', value: diagnostics.requestId),
        ],
      ),
    );
  }
}

class _RuleCard extends StatelessWidget {
  final RewriteRuleEvaluation evaluation;

  const _RuleCard({required this.evaluation});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = evaluation.selected;
    final matched = evaluation.matched;
    final color = selected
        ? Colors.green
        : matched
            ? Colors.blue
            : theme.colorScheme.outline;
    final rule = evaluation.rule;
    final title = rule.name?.trim().isNotEmpty == true ? rule.name! : rule.url;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: selected ? Colors.green.withValues(alpha: 0.055) : theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: selected ? 0.45 : 0.2)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('#${evaluation.index + 1}',
              style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
          ),
          _StatusChip(label: evaluation.reason, ok: selected),
        ]),
        const SizedBox(height: 8),
        Text(rule.url,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
        const SizedBox(height: 10),
        Wrap(spacing: 6, runSpacing: 6, children: [
          _CheckChip(label: '总开关', ok: evaluation.managerEnabled),
          _CheckChip(label: '合集', ok: evaluation.groupEnabled),
          _CheckChip(label: '规则', ok: rule.enabled),
          _CheckChip(label: '类型', ok: evaluation.typeMatches),
          _CheckChip(label: 'Method', ok: evaluation.methodMatches),
          _CheckChip(label: 'URL', ok: evaluation.urlMatches),
          _InfoChip(label: '命中 ${evaluation.stats.hitCount} 次'),
          if (evaluation.stats.lastHitAt != null) _InfoChip(label: '最近 ${_formatTime(evaluation.stats.lastHitAt!)}'),
        ]),
      ]),
    );
  }

  static String _formatTime(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}:${value.second.toString().padLeft(2, '0')}';
}

class _CheckChip extends StatelessWidget {
  final String label;
  final bool ok;

  const _CheckChip({required this.label, required this.ok});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: (ok ? Colors.green : Colors.red).withValues(alpha: 0.09),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(ok ? Icons.check_circle_outline : Icons.cancel_outlined,
              size: 13, color: ok ? Colors.green : Colors.red),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 11)),
        ]),
      );
}

class _StatusChip extends StatelessWidget {
  final String label;
  final bool ok;

  const _StatusChip({required this.label, required this.ok});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: (ok ? Colors.green : Colors.orange).withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: ok ? Colors.green : Colors.orange)),
      );
}

class _InfoChip extends StatelessWidget {
  final String label;

  const _InfoChip({required this.label});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label, style: const TextStyle(fontSize: 11)),
      );
}

class _MetaRow extends StatelessWidget {
  final String label;
  final String value;

  const _MetaRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 78, child: Text(label, style: Theme.of(context).textTheme.labelSmall)),
        Expanded(child: SelectableText(value, style: const TextStyle(fontSize: 12, fontFamily: 'monospace'))),
      ]);
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) => const Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.rule_folder_outlined, size: 42, color: Colors.grey),
          SizedBox(height: 12),
          Text('选择一条请求后查看 Mock 命中链路'),
        ]),
      );
}

class _NoRulesCard extends StatelessWidget {
  const _NoRulesCard();

  @override
  Widget build(BuildContext context) => const Card(
        elevation: 0,
        child: Padding(
          padding: EdgeInsets.all(18),
          child: Row(children: [
            Icon(Icons.info_outline, size: 19),
            SizedBox(width: 10),
            Expanded(child: Text('当前还没有 Mock/请求重写规则。')),
          ]),
        ),
      );
}

class _HintCard extends StatelessWidget {
  const _HintCard();

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.orange.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.lightbulb_outline, size: 18, color: Colors.orange),
          SizedBox(width: 8),
          Expanded(child: Text('建议先处理最靠前规则的失败项；规则按列表顺序匹配，第一条完全匹配的规则会生效。')),
        ]),
      );
}
