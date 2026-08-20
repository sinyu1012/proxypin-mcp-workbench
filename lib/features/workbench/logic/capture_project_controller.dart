import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:proxypin/features/workbench/data/capture_plan_repository.dart';
import 'package:proxypin/features/workbench/data/capture_project_repository.dart';
import 'package:proxypin/features/workbench/domain/capture_plan.dart';
import 'package:proxypin/features/workbench/domain/capture_project.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/storage/histories.dart';
import 'package:proxypin/utils/har.dart';
import 'package:proxypin/utils/listenable_list.dart';

class CaptureProjectController extends ChangeNotifier {
  CaptureProjectController._();

  static final CaptureProjectController instance = CaptureProjectController._();

  final CaptureProjectRepository _repository = CaptureProjectRepository();
  final CapturePlanRepository _planRepository = CapturePlanRepository();
  final List<CaptureProject> _projects = [];
  final List<CapturePlan> _plans = [];
  final Map<String, HttpRequest> _pendingRequests = {};
  ListenableList<HttpRequest>? _container;
  _CaptureProjectListListener? _listener;
  RandomAccessFile? _output;
  HistoryItem? _history;
  Timer? _flushTimer;
  Timer? _saveDebounce;
  bool _initialized = false;
  Future<void>? _initializing;
  Future<void>? _flushInFlight;
  // Start/stop 共用同一 FIFO，避免异步文件初始化期间产生两个活动项目。
  Future<void> _lifecycleQueue = Future.value();

  List<CaptureProject> get projects => List.unmodifiable(_projects);
  List<CapturePlan> get plans => List.unmodifiable(_plans);
  CaptureProject? get activeProject {
    for (final project in _projects) {
      if (project.status == CaptureProjectStatus.active) return project;
    }
    return null;
  }

  CapturePlan? get activePlan {
    final planId = activeProject?.planId;
    if (planId == null) return null;
    for (final plan in _plans) {
      if (plan.id == planId) return plan;
    }
    return null;
  }

  bool get initialized => _initialized;

  Future<void> initialize(ListenableList<HttpRequest> container) async {
    if (_initialized) {
      _bind(container);
      return;
    }
    final inProgress = _initializing;
    if (inProgress != null) {
      await inProgress;
      _bind(container);
      return;
    }
    final future = _initialize(container);
    _initializing = future;
    try {
      await future;
    } finally {
      if (identical(_initializing, future)) _initializing = null;
    }
  }

  Future<void> _initialize(ListenableList<HttpRequest> container) async {
    _projects.addAll(await _repository.load());
    _plans.addAll(_mergePlans(await _planRepository.load()));
    for (final project in _projects.where((item) => item.status == CaptureProjectStatus.active)) {
      project
        ..status = CaptureProjectStatus.interrupted
        ..endedAt = DateTime.now();
    }
    _initialized = true;
    _bind(container);
    await _repository.save(_projects);
    await _planRepository.save(_plans);
    notifyListeners();
  }

  List<CapturePlan> _mergePlans(List<CapturePlan> stored) {
    final merged = <CapturePlan>[];
    for (final builtIn in BuiltInCapturePlans.values) {
      CapturePlan? saved;
      for (final plan in stored) {
        if (plan.id == builtIn.id || BuiltInCapturePlans.isLegacyDailyRecordsPlan(plan)) {
          saved = plan;
          break;
        }
      }
      merged.add(saved == null ? builtIn : builtIn.copyWith(enabled: saved.enabled));
    }
    merged.addAll(stored.where((plan) =>
        !BuiltInCapturePlans.values.any((builtIn) => builtIn.id == plan.id) &&
        !BuiltInCapturePlans.isLegacyDailyRecordsPlan(plan)));
    return merged;
  }

  void _bind(ListenableList<HttpRequest> container) {
    if (identical(_container, container)) return;
    if (_container != null && _listener != null) _container!.removeListener(_listener!);
    _container = container;
    _listener = _CaptureProjectListListener(_onRequestsAdded);
    container.addListener(_listener!);
  }

  Future<CaptureProject> start(String name) => _enqueueLifecycle(() async {
        await _waitUntilInitialized();
        if (activeProject != null) await _stopCurrent();
        return _start(name);
      });

  Future<CaptureProject> _start(String name, {CapturePlan? plan}) async {
    final now = DateTime.now();
    final id = '${now.microsecondsSinceEpoch}';
    final project = CaptureProject(
      id: id,
      name: name.trim().isEmpty ? _defaultName(now) : name.trim(),
      createdAt: now,
      planId: plan?.id,
      planName: plan?.name,
      includeDomains: plan?.includeDomains,
      excludeDomains: plan?.excludeDomains,
    );

    _pendingRequests.clear();
    final file = await HistoryStorage.openFile('project_$id.txt');
    final storage = await HistoryStorage.instance;
    _history = await storage.addHistory('[项目] ${project.name}', file, 0);
    project.historyPath = file.path;
    _output = await file.open(mode: FileMode.append);
    _projects.insert(0, project);
    _flushTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_flush().catchError((Object error, StackTrace stackTrace) {
        logger.e('后台写入抓包项目失败', error: error, stackTrace: stackTrace);
      })),
    );
    await _repository.save(_projects);
    notifyListeners();
    return project;
  }

  Future<CaptureProject> startPlan(CapturePlan plan) => _enqueueLifecycle(() async {
        await _waitUntilInitialized();
        if (!plan.enabled) throw StateError('采集方案已停用');
        if (plan.includeDomains.isEmpty) throw StateError('采集方案没有配置域名范围');
        if (activeProject != null) throw StateError('请先结束当前抓包项目');

        final now = DateTime.now();
        final suffix = '${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
            '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
        return _start(
          '${plan.name} · $suffix',
          plan: plan,
        );
      });

  Future<void> setPlanEnabled(CapturePlan plan, bool enabled) async {
    if (!enabled && activeProject?.planId == plan.id) {
      throw StateError('请先结束正在运行的采集');
    }
    final index = _plans.indexWhere((item) => item.id == plan.id);
    if (index < 0) return;
    _plans[index] = plan.copyWith(enabled: enabled);
    await _planRepository.save(_plans);
    notifyListeners();
  }

  Future<CapturePlan> createPlan({
    required String name,
    required String appName,
    required String description,
    required List<String> includeDomains,
    List<String> excludeDomains = const [],
  }) async {
    final includes = _normalizedDomains(includeDomains);
    final excludes = _normalizedDomains(excludeDomains);
    if (includes.isEmpty) throw ArgumentError('至少配置一个有效域名');
    final plan = CapturePlan(
      id: 'custom.${DateTime.now().microsecondsSinceEpoch}',
      name: name.trim().isEmpty ? '未命名采集方案' : name.trim(),
      appName: appName.trim(),
      description: description.trim(),
      includeDomains: includes,
      excludeDomains: excludes,
    );
    _plans.add(plan);
    await _planRepository.save(_plans);
    notifyListeners();
    return plan;
  }

  Future<void> updatePlan(
    CapturePlan plan, {
    required String name,
    required String appName,
    required String description,
    required List<String> includeDomains,
    required List<String> excludeDomains,
  }) async {
    final index = _plans.indexWhere((item) => item.id == plan.id);
    if (index < 0) return;
    final includes = _normalizedDomains(includeDomains);
    if (includes.isEmpty) throw ArgumentError('至少配置一个有效域名');
    _plans[index] = plan.copyWith(
      name: name.trim().isEmpty ? plan.name : name.trim(),
      appName: appName.trim(),
      description: description.trim(),
      includeDomains: includes,
      excludeDomains: _normalizedDomains(excludeDomains),
    );
    await _planRepository.save(_plans);
    notifyListeners();
  }

  Future<void> deletePlan(CapturePlan plan) async {
    if (plan.builtIn || activeProject?.planId == plan.id) return;
    _plans.removeWhere((item) => item.id == plan.id);
    await _planRepository.save(_plans);
    notifyListeners();
  }

  Future<List<HttpRequest>> loadRequests(CaptureProject project) async {
    final path = project.historyPath;
    if (path == null || path.isEmpty) return [];
    final file = File(path);
    if (!await file.exists()) return [];
    return Har.readFile(file);
  }

  List<String> _normalizedDomains(Iterable<String> values) =>
      values.map(CaptureDomainMatcher.normalizePattern).where(CaptureDomainMatcher.isValidPattern).toSet().toList()
        ..sort();

  Future<void> stop() => _enqueueLifecycle(() async {
        await _waitUntilInitialized();
        await _stopCurrent();
      });

  Future<void> _stopCurrent() async {
    final project = activeProject;
    if (project == null) return;
    _flushTimer?.cancel();
    _flushTimer = null;
    await _flushInFlight;
    await _flush(force: true);
    await _output?.flush();
    await _output?.close();
    _output = null;
    project
      ..status = CaptureProjectStatus.completed
      ..endedAt = DateTime.now();
    await _repository.save(_projects);
    notifyListeners();
  }

  Future<T> _enqueueLifecycle<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _lifecycleQueue = _lifecycleQueue.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<void> _waitUntilInitialized() async {
    final initializing = _initializing;
    if (initializing != null) await initializing;
    if (!_initialized) throw StateError('抓包项目尚未初始化');
  }

  Future<void> rename(CaptureProject project, String name) async {
    final normalized = name.trim();
    if (normalized.isEmpty) return;
    project.name = normalized;
    if (_history?.path == project.historyPath) _history?.name = '[项目] $normalized';
    await _repository.save(_projects);
    if (_history != null) await (await HistoryStorage.instance).refresh();
    notifyListeners();
  }

  void _onRequestsAdded(List<HttpRequest> requests) {
    final project = activeProject;
    if (project == null || requests.isEmpty) return;
    for (final request in requests) {
      if (_pendingRequests.containsKey(request.requestId)) continue;
      final host = request.requestUri?.host ?? '';
      if (project.usesPlan &&
          !CaptureDomainMatcher.matches(
            host,
            includeDomains: project.includeDomains,
            excludeDomains: project.excludeDomains,
          )) {
        project.ignoredRequestCount++;
        continue;
      }
      _pendingRequests[request.requestId] = request;
      project.requestCount++;
      if (host.isNotEmpty) project.domains.add(host);
    }
    _scheduleMetadataSave();
    notifyListeners();
  }

  Future<void> _flush({bool force = false}) async {
    final inProgress = _flushInFlight;
    if (inProgress != null) {
      await inProgress;
      if (force && _pendingRequests.isNotEmpty) await _flush(force: true);
      return;
    }
    final future = _performFlush(force: force);
    _flushInFlight = future;
    try {
      await future;
    } finally {
      if (identical(_flushInFlight, future)) _flushInFlight = null;
    }
  }

  Future<void> _performFlush({required bool force}) async {
    final project = activeProject;
    final output = _output;
    if (project == null || output == null || _pendingRequests.isEmpty) return;
    try {
      final settled =
          _pendingRequests.values.where((request) => force || request.response != null).toList(growable: false);
      if (settled.isEmpty) return;

      final records = settled.map(Har.toHar).toList(growable: false);
      final payload = await Isolate.run(
        () => records.map((record) => '${jsonEncode(record)},\n').join(),
      );
      await output.writeString(payload);
      for (final request in settled) {
        _pendingRequests.remove(request.requestId);
      }
      project.persistedCount += settled.length;
      final history = _history;
      if (history != null) {
        history
          ..requestLength = project.persistedCount
          ..fileSize = await output.length()
          ..requests = null;
        final storage = await HistoryStorage.instance;
        final index = storage.getIndex(history);
        if (index >= 0) await storage.updateHistory(index, history);
      }
      await _repository.save(_projects);
      notifyListeners();
    } catch (error, stackTrace) {
      logger.e('写入抓包项目失败', error: error, stackTrace: stackTrace);
      rethrow;
    }
  }

  void _scheduleMetadataSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 500), () {
      unawaited(_repository.save(_projects));
    });
  }

  static String _defaultName(DateTime value) =>
      '抓包项目 ${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')} '
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
}

class _CaptureProjectListListener extends ListenerListEvent<HttpRequest> {
  final void Function(List<HttpRequest>) onAdded;

  _CaptureProjectListListener(this.onAdded);

  @override
  void onAdd(HttpRequest item) => onAdded([item]);

  @override
  void onBatchAdd(List<HttpRequest> items) => onAdded(items);

  @override
  void onRemove(HttpRequest item) {}

  @override
  void onBatchRemove(List<HttpRequest> items) {}

  @override
  void clear(List<HttpRequest> items) {}
}
