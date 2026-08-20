import 'package:flutter/material.dart';
import 'package:proxypin/features/workbench/data/api_catalog_service.dart';
import 'package:proxypin/features/workbench/domain/api_endpoint_asset.dart';
import 'package:proxypin/network/http/http.dart';

class ApiAssetsPage extends StatefulWidget {
  final Iterable<HttpRequest> Function() requestsProvider;

  const ApiAssetsPage({super.key, required this.requestsProvider});

  @override
  State<ApiAssetsPage> createState() => _ApiAssetsPageState();
}

class _ApiAssetsPageState extends State<ApiAssetsPage> {
  final ApiCatalogService service = const ApiCatalogService();
  final TextEditingController searchController = TextEditingController();
  List<ApiEndpointAsset> assets = [];
  ApiEndpointAsset? selected;
  bool loading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (loading) return;
    setState(() => loading = true);
    final result = await service.analyze(widget.requestsProvider());
    if (!mounted) return;
    setState(() {
      assets = result;
      selected = result.isEmpty ? null : result.first;
      loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final filtered = assets.where((asset) => asset.matches(searchController.text)).toList();
    return Column(children: [
      _toolbar(context, filtered.length),
      const Divider(height: 1),
      Expanded(
        child: loading
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : assets.isEmpty
                ? const _EmptyAssets()
                : LayoutBuilder(builder: (context, constraints) {
                    final detailWidth = constraints.maxWidth >= 1000 ? 390.0 : 320.0;
                    return Row(children: [
                      Expanded(child: _endpointList(filtered)),
                      const VerticalDivider(width: 1),
                      SizedBox(width: detailWidth, child: _EndpointDetail(asset: selected)),
                    ]);
                  }),
      ),
    ]);
  }

  Widget _toolbar(BuildContext context, int count) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: searchController,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 19),
                hintText: '搜索域名、路径或字段',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text('$count 个接口', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(width: 10),
          FilledButton.tonalIcon(
              onPressed: _refresh, icon: const Icon(Icons.refresh, size: 17), label: const Text('重新分析')),
        ]),
      );

  Widget _endpointList(List<ApiEndpointAsset> filtered) => ListView.separated(
        padding: const EdgeInsets.all(12),
        itemCount: filtered.length,
        separatorBuilder: (_, __) => const SizedBox(height: 6),
        itemBuilder: (context, index) {
          final asset = filtered[index];
          final active = identical(asset, selected);
          final color = _methodColor(asset.method);
          return Material(
            color: active ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.09) : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            child: ListTile(
              selected: active,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
              onTap: () => setState(() => selected = asset),
              leading: Container(
                width: 52,
                padding: const EdgeInsets.symmetric(vertical: 5),
                decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
                child: Text(asset.method,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w700)),
              ),
              title: Text(asset.normalizedPath,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
              subtitle: Text(asset.host, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: Text('${asset.requestCount}×', style: Theme.of(context).textTheme.labelSmall),
            ),
          );
        },
      );

  static Color _methodColor(String method) => switch (method) {
        'GET' => Colors.green,
        'POST' => Colors.blue,
        'PUT' || 'PATCH' => Colors.orange,
        'DELETE' => Colors.red,
        _ => Colors.grey,
      };
}

class _EndpointDetail extends StatelessWidget {
  final ApiEndpointAsset? asset;

  const _EndpointDetail({required this.asset});

  @override
  Widget build(BuildContext context) {
    final current = asset;
    if (current == null) return const SizedBox();
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        Text(current.normalizedPath,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        SelectableText(current.exampleUrl, style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
        const SizedBox(height: 18),
        _MetricGrid(asset: current),
        const SizedBox(height: 18),
        _FieldSection(title: '鉴权信号', values: current.authSignals),
        _FieldSection(title: '分页信号', values: current.paginationSignals),
        _FieldSection(title: 'Query 字段', values: current.queryFields),
        _FieldSection(title: '请求字段', values: current.requestFields),
        _FieldSection(title: '响应字段', values: current.responseFields),
      ],
    );
  }
}

class _MetricGrid extends StatelessWidget {
  final ApiEndpointAsset asset;

  const _MetricGrid({required this.asset});

  @override
  Widget build(BuildContext context) => Wrap(spacing: 8, runSpacing: 8, children: [
        _metric(context, '请求', '${asset.requestCount}'),
        _metric(context, '平均耗时', '${asset.averageDurationMs}ms'),
        _metric(context, '状态码', asset.statusCounts.keys.join(' / ')),
      ]);

  Widget _metric(BuildContext context, String label, String value) => Container(
        width: 100,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(9)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 3),
          Text(value.isEmpty ? '-' : value,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
        ]),
      );
}

class _FieldSection extends StatelessWidget {
  final String title;
  final Set<String> values;

  const _FieldSection({required this.title, required this.values});

  @override
  Widget build(BuildContext context) {
    if (values.isEmpty) return const SizedBox();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: Theme.of(context).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 7),
        Wrap(
            spacing: 5,
            runSpacing: 5,
            children: values
                .take(40)
                .map((value) => Chip(
                    label: Text(value, style: const TextStyle(fontSize: 10)), visualDensity: VisualDensity.compact))
                .toList()),
      ]),
    );
  }
}

class _EmptyAssets extends StatelessWidget {
  const _EmptyAssets();

  @override
  Widget build(BuildContext context) => const Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.account_tree_outlined, size: 48, color: Colors.grey),
        SizedBox(height: 12),
        Text('抓到请求后，这里会自动生成 API 资产目录'),
      ]));
}
