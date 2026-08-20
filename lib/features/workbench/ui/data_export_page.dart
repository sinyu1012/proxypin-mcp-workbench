import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_toastr/flutter_toastr.dart';
import 'package:proxypin/features/workbench/data/api_catalog_service.dart';
import 'package:proxypin/features/workbench/data/data_export_service.dart';
import 'package:proxypin/features/workbench/domain/api_endpoint_asset.dart';
import 'package:proxypin/features/workbench/domain/capture_project.dart';
import 'package:proxypin/features/workbench/domain/export_dataset.dart';
import 'package:proxypin/features/workbench/logic/capture_project_controller.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/http/http.dart';

class DataExportPage extends StatefulWidget {
  final Iterable<HttpRequest> Function() requestsProvider;
  final ProxyServer proxyServer;

  const DataExportPage({super.key, required this.requestsProvider, required this.proxyServer});

  @override
  State<DataExportPage> createState() => _DataExportPageState();
}

class _DataExportPageState extends State<DataExportPage> {
  static const String _liveSource = '__live__';

  final ApiCatalogService catalogService = const ApiCatalogService();
  final DataExportService exportService = const DataExportService();
  final CaptureProjectController projectController = CaptureProjectController.instance;
  List<ApiEndpointAsset> endpoints = [];
  ApiEndpointAsset? selected;
  ExportDataset? dataset;
  bool loading = false;
  bool redactCredentials = true;
  final List<HttpRequest> fetchedRequests = [];
  int paginationPage = 0;
  int paginationRecords = 0;
  String? paginationResult;
  String? sourceProjectId;
  List<HttpRequest> archivedRequests = [];
  int _generation = 0;
  int _endpointRevision = 0;

  @override
  void initState() {
    super.initState();
    projectController.addListener(_onProjectsChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadEndpoints());
  }

  @override
  void dispose() {
    projectController.removeListener(_onProjectsChanged);
    super.dispose();
  }

  Iterable<HttpRequest> get _sourceRequests => sourceProjectId == null ? widget.requestsProvider() : archivedRequests;

  List<CaptureProject> get _archivedProjects => projectController.projects
      .where((project) => project.status != CaptureProjectStatus.active && project.historyPath?.isNotEmpty == true)
      .toList(growable: false);

  void _onProjectsChanged() {
    if (mounted) setState(() {});
  }

  bool _isCurrent(int generation) => mounted && generation == _generation;

  Future<void> _loadEndpoints({int? generation}) async {
    final currentGeneration = generation ?? ++_generation;
    if (!_isCurrent(currentGeneration)) return;
    setState(() => loading = true);
    try {
      final assets = await catalogService.analyze(_sourceRequests);
      if (!_isCurrent(currentGeneration)) return;
      final rebuiltEndpoints = assets.where((asset) => asset.responseFields.isNotEmpty).toList();
      final nextSelected = rebuiltEndpoints.isEmpty ? null : rebuiltEndpoints.first;
      setState(() {
        endpoints = rebuiltEndpoints;
        selected = nextSelected;
        dataset = null;
        _endpointRevision++;
      });
      if (nextSelected != null) await _prepare(generation: currentGeneration);
    } catch (error) {
      if (!mounted || currentGeneration != _generation) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('分析请求失败：$error')));
    } finally {
      if (_isCurrent(currentGeneration)) setState(() => loading = false);
    }
  }

  Future<void> _prepare({int? generation}) async {
    final currentGeneration = generation ?? ++_generation;
    final endpoint = selected;
    if (endpoint == null || !_isCurrent(currentGeneration)) return;
    setState(() => loading = true);
    try {
      final result = await exportService.prepare(
        endpoint,
        [..._sourceRequests, ...fetchedRequests],
        redactCredentials: redactCredentials,
      );
      if (!_isCurrent(currentGeneration)) return;
      setState(() => dataset = result);
    } catch (error) {
      if (!mounted || currentGeneration != _generation) return;
      setState(() => dataset = null);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('整理导出数据失败：$error')));
    } finally {
      if (_isCurrent(currentGeneration)) setState(() => loading = false);
    }
  }

  Future<void> _export(String format) async {
    final current = dataset;
    if (current == null || current.records.isEmpty) return;
    final extension = format == 'csv' ? 'csv' : 'json';
    final path = await FilePicker.platform.saveFile(
      fileName: 'ProxyPin_export_${DateTime.now().millisecondsSinceEpoch}.$extension',
      allowedExtensions: [extension],
      type: FileType.custom,
    );
    if (path == null) return;
    final content = format == 'csv' ? exportService.toCsv(current) : exportService.toJson(current);
    await File(path).writeAsString(content);
    if (mounted) FlutterToastr.show('已导出 ${current.records.length} 条记录', context);
  }

  Future<void> _fetchAllPages() async {
    final endpoint = selected;
    if (endpoint == null || endpoint.method != 'GET' || loading) return;
    final generation = ++_generation;
    setState(() {
      loading = true;
      paginationPage = 0;
      paginationRecords = 0;
      paginationResult = null;
      fetchedRequests.clear();
    });
    try {
      final result = await exportService.fetchAllPages(
        endpoint,
        _sourceRequests,
        widget.proxyServer,
        onProgress: (page, records) {
          if (!_isCurrent(generation)) return;
          setState(() {
            paginationPage = page;
            paginationRecords = records;
          });
        },
      );
      if (!_isCurrent(generation)) return;
      setState(() {
        fetchedRequests.addAll(result.requests);
        paginationResult = result.stopReason;
      });
      await _prepare(generation: generation);
    } catch (error) {
      if (!mounted || generation != _generation) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('补全分页失败：$error')));
    } finally {
      if (_isCurrent(generation)) setState(() => loading = false);
    }
  }

  Future<void> _selectSource(String? value) async {
    if (value == null || value == _liveSource) {
      final generation = ++_generation;
      setState(() {
        sourceProjectId = null;
        archivedRequests = [];
        endpoints = [];
        selected = null;
        dataset = null;
        fetchedRequests.clear();
        paginationResult = null;
        loading = true;
        _endpointRevision++;
      });
      await _loadEndpoints(generation: generation);
      return;
    }
    CaptureProject? project;
    for (final candidate in projectController.projects) {
      if (candidate.id == value) {
        project = candidate;
        break;
      }
    }
    final selectedProject = project;
    if (selectedProject == null) return;
    final generation = ++_generation;
    setState(() {
      sourceProjectId = selectedProject.id;
      archivedRequests = [];
      endpoints = [];
      selected = null;
      dataset = null;
      fetchedRequests.clear();
      paginationResult = null;
      loading = true;
      _endpointRevision++;
    });
    try {
      final requests = await projectController.loadRequests(selectedProject);
      if (!mounted || generation != _generation) return;
      if (requests.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('这个归档没有可读取的请求')));
        return;
      }
      setState(() => archivedRequests = requests);
      await _loadEndpoints(generation: generation);
    } catch (error) {
      if (!mounted || generation != _generation) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('读取归档失败：$error')));
    } finally {
      if (_isCurrent(generation)) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      _buildToolbar(),
      const Divider(height: 1),
      Expanded(
        child: loading && dataset == null
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : endpoints.isEmpty
                ? const _EmptyExport()
                : _buildContent(),
      ),
    ]);
  }

  Widget _buildToolbar() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        child: Column(children: [
          Row(children: [
            SizedBox(
              width: 260,
              child: DropdownButtonFormField<String>(
                key: ValueKey(sourceProjectId),
                initialValue: sourceProjectId ?? _liveSource,
                isExpanded: true,
                decoration: InputDecoration(
                  isDense: true,
                  labelText: '数据来源',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
                items: [
                  const DropdownMenuItem(value: _liveSource, child: Text('当前实时请求')),
                  ..._archivedProjects.map((project) => DropdownMenuItem(
                        value: project.id,
                        child: Text(project.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      )),
                ],
                onChanged: _selectSource,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<ApiEndpointAsset>(
                key: ValueKey('endpoint-${sourceProjectId ?? _liveSource}-$_endpointRevision'),
                initialValue: selected,
                isExpanded: true,
                decoration: InputDecoration(
                  isDense: true,
                  labelText: '数据接口',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
                items: endpoints
                    .map((endpoint) => DropdownMenuItem(
                          value: endpoint,
                          child: Text('${endpoint.method} ${endpoint.host}${endpoint.normalizedPath}',
                              overflow: TextOverflow.ellipsis),
                        ))
                    .toList(),
                onChanged: (value) async {
                  final generation = ++_generation;
                  setState(() {
                    selected = value;
                    dataset = null;
                    fetchedRequests.clear();
                    paginationResult = null;
                  });
                  await _prepare(generation: generation);
                },
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Text(sourceProjectId == null ? '分析实时列表' : '已加载 ${archivedRequests.length} 条归档请求',
                style: Theme.of(context).textTheme.bodySmall),
            const Spacer(),
            FilterChip(
              selected: redactCredentials,
              avatar: const Icon(Icons.shield_outlined, size: 16),
              label: const Text('凭据脱敏'),
              onSelected: (value) async {
                final generation = ++_generation;
                setState(() => redactCredentials = value);
                await _prepare(generation: generation);
              },
            ),
            const SizedBox(width: 8),
            IconButton(onPressed: _loadEndpoints, tooltip: '刷新', icon: const Icon(Icons.refresh)),
          ]),
        ]),
      );

  Widget _buildContent() {
    final current = dataset;
    if (loading) return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    if (current == null || current.records.isEmpty) {
      return const Center(child: Text('这个接口的已抓取响应中没有识别到记录数组'));
    }
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
        child: Row(children: [
          _stat('请求页', '${current.matchedRequests}'),
          _stat('原始记录', '${current.rawRecordCount}'),
          _stat('去重后', '${current.records.length}'),
          _stat('重复', '${current.duplicateCount}'),
          _stat('字段', '${current.fields.length}'),
          const Spacer(),
          if (selected?.method == 'GET' && current.paginationSignals.isNotEmpty) ...[
            OutlinedButton.icon(
              onPressed: loading ? null : _fetchAllPages,
              icon: loading
                  ? const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.auto_mode, size: 17),
              label: Text(paginationPage > 0 ? '第 $paginationPage 页 · $paginationRecords 条' : '自动补全分页'),
            ),
            const SizedBox(width: 8),
          ],
          OutlinedButton.icon(
              onPressed: () => _export('json'),
              icon: const Icon(Icons.data_object, size: 17),
              label: const Text('JSON')),
          const SizedBox(width: 8),
          FilledButton.icon(
              onPressed: () => _export('csv'),
              icon: const Icon(Icons.table_view_outlined, size: 17),
              label: const Text('导出 CSV')),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Wrap(spacing: 8, runSpacing: 6, children: [
            Chip(label: Text('记录路径 ${current.detectedRecordPath ?? '-'}')),
            ...current.paginationSignals
                .take(8)
                .map((value) => Chip(avatar: const Icon(Icons.more_horiz, size: 14), label: Text(value))),
            if (paginationResult != null)
              Chip(avatar: const Icon(Icons.flag_outlined, size: 14), label: Text(paginationResult!)),
          ]),
        ),
      ),
      const SizedBox(height: 8),
      const Divider(height: 1),
      Expanded(child: _previewTable(current)),
    ]);
  }

  Widget _stat(String label, String value) => Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(8)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
        ]),
      );

  Widget _previewTable(ExportDataset current) {
    final fields = current.fields.take(12).toList();
    final records = current.records.take(200).toList();
    return Scrollbar(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: fields.length * 180.0 < 900 ? 900 : fields.length * 180.0,
          child: ListView.builder(
            itemCount: records.length + 1,
            itemBuilder: (context, index) {
              final header = index == 0;
              final record = header ? null : records[index - 1];
              return Container(
                height: 38,
                color: header ? Theme.of(context).colorScheme.surfaceContainerHigh : null,
                child: Row(
                    children: fields.map((field) {
                  final value = header ? field : '${record?[field] ?? ''}';
                  return Container(
                    width: 180,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                        border: Border(
                            right: BorderSide(color: Theme.of(context).dividerColor.withValues(alpha: 0.25)),
                            bottom: BorderSide(color: Theme.of(context).dividerColor.withValues(alpha: 0.2)))),
                    child: Text(value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, fontWeight: header ? FontWeight.w700 : FontWeight.normal)),
                  );
                }).toList()),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _EmptyExport extends StatelessWidget {
  const _EmptyExport();

  @override
  Widget build(BuildContext context) => const Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.file_download_outlined, size: 48, color: Colors.grey),
        SizedBox(height: 12),
        Text('暂未发现可导出的结构化响应'),
        SizedBox(height: 4),
        Text('在 App 中打开列表或记录页面后点击刷新'),
      ]));
}
