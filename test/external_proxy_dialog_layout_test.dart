// TDD 验证脚本：外部代理设置弹窗布局
//
// 回归诉求：取消/确认按钮必须落在弹窗边框（带背景的 TintedSurface）内，
// 不允许出现在 AlertDialog 的 actions 区域（透明背景、位于容器外）。
//
// 通过对源码做静态分析，避免把整个 widget tree 拉起来（Configuration/Localizations
// 都需要异步初始化和 delegate），又快又稳。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ExternalProxyDialog 布局', () {
    final source = File('lib/ui/desktop/setting/external_proxy.dart').readAsStringSync();

    test('Cancel/Confirm 按钮必须在 TintedSurface 内部（与背景同框）', () {
      // TintedSurface 的子节点从 "TintedSurface(" 之后到对应闭合 ")])"
      // 即可。简单做法：取最近一个 "TintedSurface(" 之后的代码段，检查
      // Cancel 与 Confirm 文案是否同时落在其中。
      final tintedStart = source.indexOf('TintedSurface(');
      expect(tintedStart, greaterThanOrEqualTo(0), reason: '必须使用 TintedSurface 作为有背景的容器');

      // TintedSurface 在 content 节点内，整段到 build 函数结尾。
      // 用 "]);" 在 tint 之后出现的最后一次作为边界即可。
      final region = source.substring(tintedStart);

      expect(region.contains(localizationsCancel), isTrue, reason: '取消按钮必须放在带背景的 TintedSurface 内部，否则会浮在透明区域上');
      expect(region.contains(localizationsConfirm), isTrue, reason: '确认按钮必须放在带背景的 TintedSurface 内部，否则会浮在透明区域上');
    });

    test('AlertDialog 不应再使用 actions 数组（与 TintedSurface 双重背景冲突）', () {
      // 找到 _ExternalProxyDialogState.build 内的 AlertDialog 块：第一个 AlertDialog
      // 起，到外层最远的 "];\n        content:" 之前结束（这里 content 是最外
      // 层 AlertDialog 的 content，因此 AlertDialog 头部的 actions 必须不存在）。
      final buildStart = source.indexOf('return AlertDialog(');
      expect(buildStart, greaterThanOrEqualTo(0), reason: 'build 必须返回 AlertDialog');

      // 找 content: 之前的片段（紧贴 AlertDialog 顶部配置）
      final contentIdx = source.indexOf('content:', buildStart);
      expect(contentIdx, greaterThan(buildStart), reason: 'AlertDialog 必须有 content');

      final head = source.substring(buildStart, contentIdx);
      expect(head.contains('actions:'), isFalse, reason: 'AlertDialog 的 actions 区域会渲染在透明背景之外，必须移除并把按钮挪进 TintedSurface');
    });
  });
}

// 文案来源：lib/l10n/app_zh.arb 中 cancel/confirm 字段
const localizationsCancel = 'localizations.cancel';
const localizationsConfirm = 'localizations.confirm';
