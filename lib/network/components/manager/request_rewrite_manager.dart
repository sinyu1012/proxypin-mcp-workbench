/*
 * Copyright 2023 Hongen Wang All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import 'dart:convert';
import 'dart:io';

import 'package:proxypin/network/components/manager/rewrite_rule.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/util/file_read.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/network/util/random.dart';

/// @author wanghongen
/// 2023/7/26
/// 请求重写
class RequestRewriteManager {
  static const String ungroupedName = '未分组';
  static String separator = Platform.pathSeparator;

  //重写规则
  final Map<RequestRewriteRule, List<RewriteItem>> rewriteItemsCache = {};

  //单例
  static RequestRewriteManager? _instance;

  RequestRewriteManager._();

  /// 仅用于隔离测试或预览，不读取和写入用户配置。
  RequestRewriteManager.inMemory();

  static Future<RequestRewriteManager> get instance async {
    if (_instance == null) {
      var config = await _loadRequestRewriteConfig();
      _instance = RequestRewriteManager._();
      await _instance!.reload(config);
    }
    return _instance!;
  }

  bool enabled = true;
  List<RequestRewriteRule> rules = [];
  final Map<String, bool> groups = {ungroupedName: true};
  final Map<RequestRewriteRule, RewriteRuleRuntimeStats> _runtimeStats = {};

  //重新加载配置
  Future<void> reload(Map<String, dynamic>? map) async {
    rewriteItemsCache.clear();
    if (map == null) {
      return;
    }

    enabled = map['enabled'] == true;
    _loadGroups(map['groups']);
    List list = map['rules'] ?? [];
    rules.clear();
    for (var element in list) {
      try {
        rules.add(RequestRewriteRule.formJson(element));
      } catch (e) {
        logger.e('加载请求重写配置失败 $element', error: e);
      }
    }
  }

  ///重新加载请求重写
  Future<void> reloadRequestRewrite() async {
    var config = await _loadRequestRewriteConfig();
    reload(config);
  }

  ///同步配置
  Future<void> syncConfig(Map<String, dynamic>? config) async {
    if (config == null) {
      return;
    }

    rewriteItemsCache.clear();
    enabled = config['enabled'] == true;
    _loadGroups(config['groups']);
    List list = config['rules'] ?? [];
    rules.clear();
    for (var element in list) {
      try {
        var rule = RequestRewriteRule.formJson(element);
        List list = element['items'] as List;
        List<RewriteItem> items = list.map((e) => RewriteItem.fromJson(e)).toList();
        await addRule(rule, items);
      } catch (e) {
        logger.e('加载请求重写配置失败 $element', error: e);
      }
    }
    flushRequestRewriteConfig();
  }

  /// 加载请求重写配置文件
  static Future<Map<String, dynamic>?> _loadRequestRewriteConfig() async {
    var home = await FileRead.homeDir();
    var file = File('${home.path}${Platform.pathSeparator}request_rewrite.json');
    var exits = await file.exists();
    if (!exits) {
      return null;
    }

    Map<String, dynamic> config = jsonDecode(await file.readAsString());
    logger.i('加载请求重写配置文件 [$file]');
    return config;
  }

  /// 保存请求重写配置文件
  Future<void> flushRequestRewriteConfig() async {
    var home = await FileRead.homeDir();
    var file = File('${home.path}${Platform.pathSeparator}request_rewrite.json');
    bool exists = await file.exists();
    if (!exists) {
      await file.create(recursive: true);
    }
    var json = jsonEncode(toJson());
    logger.i('刷新请求重写配置文件 ${file.path}');
    await file.writeAsString(json);
  }

  ///添加规则
  Future<void> addRule(RequestRewriteRule rule, List<RewriteItem> items) async {
    final home = await FileRead.homeDir();

    String rewritePath = "${separator}rewrite$separator${RandomUtil.randomString(16)}.json";
    var file = File(home.path + rewritePath);
    await file.create(recursive: true);
    file.writeAsString(jsonEncode(items.map((e) => e.toJson()).toList()));
    rule.rewritePath = rewritePath;
    groups.putIfAbsent(groupNameFor(rule), () => true);

    rules.add(rule);
    rewriteItemsCache[rule] = items;
  }

  ///更新规则
  Future<void> updateRule(int index, RequestRewriteRule rule, List<RewriteItem>? items) async {
    rewriteItemsCache.remove(rules[index]);
    final home = await FileRead.homeDir();
    rule.updatePathReg();
    groups.putIfAbsent(groupNameFor(rule), () => true);
    rules[index] = rule;

    if (items == null) {
      return;
    }
    bool isExist = rule.rewritePath != null;
    if (rule.rewritePath == null) {
      String rewritePath = "${separator}rewrite$separator${RandomUtil.randomString(16)}.json";
      rule.rewritePath = rewritePath;
    }

    File file = File(home.path + rule.rewritePath!);
    if (!isExist) {
      await file.create(recursive: true);
    }

    await file.writeAsString(jsonEncode(items.map((e) => e.toJson()).toList()));
    rewriteItemsCache[rule] = items;
  }

  Future<void> removeIndex(List<int> indexes) async {
    for (var i in indexes) {
      var rule = rules.removeAt(i);
      rewriteItemsCache.remove(rule); //删除缓存
      if (rule.rewritePath != null) {
        File home = await FileRead.homeDir();
        try {
          await File(home.path + rule.rewritePath!).delete();
        } catch (e) {
          logger.e('删除请求重写配置文件失败 ${home.path + rule.rewritePath!}', error: e);
        }
        rule.rewritePath = null;
      }
    }
  }

  RequestRewriteRule getRequestRewriteRule(HttpRequest request, RuleType type) {
    var url = request.domainPath;
    for (var rule in rules) {
      if (rule.match(url, type: type, method: request.method) && rule.type == type) {
        return rule;
      }
    }

    return RequestRewriteRule(type: type, url: url);
  }

  RequestRewriteRule? getRewriteRule(String? url, List<RuleType> types, {HttpMethod? method, String? requestId}) {
    if (url == null || !enabled) {
      return null;
    }
    for (var rule in rules) {
      if (!isGroupEnabled(rule)) continue;
      if (rule.match(url, method: method) && types.contains(rule.type)) {
        _recordHit(rule, requestId);
        return rule;
      }
    }
    return null;
  }

  /// 解释一条请求为何命中或未命中 Mock/重写规则。
  ///
  /// 规则顺序与 [getRewriteRule] 完全一致，第一个全部通过的规则即真实赢家。
  RewriteMatchDiagnostics diagnose(HttpRequest request, {List<RuleType> types = RuleType.values}) {
    final url = request.requestUrl;
    var winnerFound = false;
    final evaluations = <RewriteRuleEvaluation>[];

    for (var index = 0; index < rules.length; index++) {
      final rule = rules[index];
      final typeMatches = types.contains(rule.type);
      final groupEnabled = isGroupEnabled(rule);
      final methodMatches = rule.matchesMethod(request.method);
      final urlMatches = rule.matchesUrl(url);
      final matched = enabled && rule.enabled && groupEnabled && typeMatches && methodMatches && urlMatches;
      final selected = matched && !winnerFound;
      if (selected) winnerFound = true;

      evaluations.add(RewriteRuleEvaluation(
        index: index,
        rule: rule,
        managerEnabled: enabled,
        groupEnabled: groupEnabled,
        typeMatches: typeMatches,
        methodMatches: methodMatches,
        urlMatches: urlMatches,
        selected: selected,
        stats: _runtimeStats[rule] ?? const RewriteRuleRuntimeStats(),
      ));
    }

    return RewriteMatchDiagnostics(
      requestId: request.requestId,
      url: url,
      method: request.method,
      managerEnabled: enabled,
      evaluations: evaluations,
    );
  }

  RewriteRuleRuntimeStats statsFor(RequestRewriteRule rule) => _runtimeStats[rule] ?? const RewriteRuleRuntimeStats();

  void _recordHit(RequestRewriteRule rule, String? requestId) {
    final previous = _runtimeStats[rule] ?? const RewriteRuleRuntimeStats();
    if (requestId != null && previous.lastRequestId == requestId) return;
    _runtimeStats[rule] = RewriteRuleRuntimeStats(
      hitCount: previous.hitCount + 1,
      lastHitAt: DateTime.now(),
      lastRequestId: requestId,
    );
  }

  /// 获取重写规则
  Future<List<RewriteItem>?> getRewriteItems(RequestRewriteRule rule) async {
    if (rewriteItemsCache.containsKey(rule)) {
      return rewriteItemsCache[rule]!;
    }
    if (rule.rewritePath == null) {
      return null;
    }

    final home = await FileRead.homeDir();
    List<RewriteItem> items = [];
    try {
      var json = await File(home.path + rule.rewritePath!).readAsString();
      List? list = jsonDecode(json);
      list?.forEach((element) => items.add(RewriteItem.fromJson(element)));
      rewriteItemsCache[rule] = items;
    } catch (e) {
      logger.e('加载请求重写配置文件失败 ${home.path + rule.rewritePath!}', error: e);
    }
    return items;
  }

  Map<String, Object> toJson() {
    return {
      'enabled': enabled,
      'groups': groups,
      'rules': rules.map((e) => e.toJson()).toList(),
    };
  }

  Future<Map<String, dynamic>> toFullJson() async {
    var rulesJson = [];
    for (var rule in rules) {
      var json = rule.toJson();
      json['items'] = await getRewriteItems(rule);
      rulesJson.add(json);
    }

    return {
      'enabled': enabled,
      'groups': groups,
      'rules': rulesJson,
    };
  }

  String groupNameFor(RequestRewriteRule rule) {
    final name = rule.group?.trim();
    return name == null || name.isEmpty ? ungroupedName : name;
  }

  bool isGroupEnabled(RequestRewriteRule rule) => groups[groupNameFor(rule)] ?? true;

  void addGroup(String name) {
    final normalized = name.trim();
    if (normalized.isEmpty) return;
    groups.putIfAbsent(normalized, () => true);
  }

  void setGroupEnabled(String name, bool enabled) {
    addGroup(name);
    groups[name.trim()] = enabled;
  }

  /// 以互斥场景方式启用一个合集，避免多个业务状态同时生效。
  void activateExclusiveGroup(String name) {
    final normalized = name.trim();
    if (normalized.isEmpty) return;
    addGroup(normalized);
    for (final group in groups.keys.toList()) {
      if (group == ungroupedName) continue;
      groups[group] = group == normalized;
    }
  }

  void disableAllGroups() {
    for (final group in groups.keys.toList()) {
      if (group != ungroupedName) groups[group] = false;
    }
  }

  List<RewriteRuleConflict> conflictsForGroup(String group) {
    final groupedRules = rules.asMap().entries.where((entry) => groupNameFor(entry.value) == group).toList();
    final conflicts = <RewriteRuleConflict>[];
    for (var left = 0; left < groupedRules.length; left++) {
      for (var right = left + 1; right < groupedRules.length; right++) {
        final first = groupedRules[left];
        final second = groupedRules[right];
        if (first.value.type == second.value.type &&
            first.value.method == second.value.method &&
            first.value.url == second.value.url) {
          conflicts.add(RewriteRuleConflict(first.key, second.key, first.value.url));
        }
      }
    }
    return conflicts;
  }

  void renameGroup(String oldName, String newName) {
    final normalized = newName.trim();
    if (oldName == ungroupedName || normalized.isEmpty || oldName == normalized) return;
    final enabled = groups.remove(oldName) ?? true;
    groups[normalized] = enabled;
    for (final rule in rules.where((rule) => rule.group == oldName)) {
      rule.group = normalized;
    }
  }

  void removeGroup(String name) {
    if (name == ungroupedName) return;
    groups.remove(name);
    for (final rule in rules.where((rule) => rule.group == name)) {
      rule.group = null;
    }
    groups.putIfAbsent(ungroupedName, () => true);
  }

  void _loadGroups(dynamic value) {
    groups
      ..clear()
      ..[ungroupedName] = true;
    if (value is Map) {
      for (final entry in value.entries) {
        final name = entry.key.toString().trim();
        if (name.isNotEmpty) groups[name] = entry.value != false;
      }
    }
  }
}

class RewriteMatchDiagnostics {
  final String requestId;
  final String url;
  final HttpMethod method;
  final bool managerEnabled;
  final List<RewriteRuleEvaluation> evaluations;

  const RewriteMatchDiagnostics({
    required this.requestId,
    required this.url,
    required this.method,
    required this.managerEnabled,
    required this.evaluations,
  });

  RewriteRuleEvaluation? get winner {
    for (final evaluation in evaluations) {
      if (evaluation.selected) return evaluation;
    }
    return null;
  }
}

class RewriteRuleEvaluation {
  final int index;
  final RequestRewriteRule rule;
  final bool managerEnabled;
  final bool groupEnabled;
  final bool typeMatches;
  final bool methodMatches;
  final bool urlMatches;
  final bool selected;
  final RewriteRuleRuntimeStats stats;

  const RewriteRuleEvaluation({
    required this.index,
    required this.rule,
    required this.managerEnabled,
    required this.groupEnabled,
    required this.typeMatches,
    required this.methodMatches,
    required this.urlMatches,
    required this.selected,
    required this.stats,
  });

  bool get matched => managerEnabled && rule.enabled && groupEnabled && typeMatches && methodMatches && urlMatches;

  String get reason {
    if (!managerEnabled) return 'Mock 总开关已关闭';
    if (!rule.enabled) return '规则未启用';
    if (!groupEnabled) return '所属合集未启用';
    if (!typeMatches) return '规则类型不适用于当前阶段';
    if (!methodMatches) return 'HTTP Method 不匹配';
    if (!urlMatches) return 'URL 不匹配';
    if (!selected) return '已匹配，但被更高优先级规则覆盖';
    return '已命中并执行';
  }
}

class RewriteRuleRuntimeStats {
  final int hitCount;
  final DateTime? lastHitAt;
  final String? lastRequestId;

  const RewriteRuleRuntimeStats({this.hitCount = 0, this.lastHitAt, this.lastRequestId});
}

class RewriteRuleConflict {
  final int firstIndex;
  final int secondIndex;
  final String url;

  const RewriteRuleConflict(this.firstIndex, this.secondIndex, this.url);
}
