// TDD 验证脚本：手机连接弹窗布局
//
// 回归诉求：弹窗底部不能再被 RenderFlex 溢出的黄黑警告条覆盖 "配置Wi-Fi代理..."
// 文字。根因是 SizedBox 固定高度 300，但 Column 实际内容（标题 + QR 码 200
// + IP下拉 + 提示文字）总高超过 300，导致 RenderFlex overflowed 警告条覆盖
// 底部的提示文字。修复后必须取消硬性高度约束，让 Column 自适应内容。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PhoneConnect 弹窗布局', () {
    final source = File('lib/ui/desktop/toolbar/phone_connect.dart').readAsStringSync();

    test('SizedBox 不应硬性限定 height=300（会与 Column 自适应内容产生 RenderFlex 溢出）', () {
      // SizedBox 必须存在但不能含 height: 300。
      expect(source.contains('SizedBox('), isTrue, reason: 'PhoneConnect 应当继续用 SizedBox 控制宽度');
      // 修复前应当命中 height: 300；修复后必须不再出现。
      expect(source.contains('height: 300'), isFalse,
          reason: '固定 height: 300 会与 Column 子项总高冲突，导致 RenderFlex overflowed 黄黑警告条覆盖底部文字');
    });

    test('QrImageView 必须保留 backgroundColor: Colors.white', () {
      // QR 码在彩色背景上需要白色底以保证可读性；不要因为改布局而误删。
      expect(source.contains('backgroundColor: Colors.white'), isTrue, reason: 'QR 码必须有白色背景保证扫描可读性');
    });

    test('mobileScan 提示文字（"配置Wi-Fi代理..."）必须在 Column 末尾', () {
      // 简单结构检查：mobileScan 应在 build 方法 Column 的 children 中、且位于 QrImageView 之后。
      final qrIdx = source.indexOf('QrImageView');
      final mobileScanIdx = source.indexOf('localizations.mobileScan');
      expect(qrIdx, greaterThanOrEqualTo(0), reason: 'build 里必须有 QrImageView');
      expect(mobileScanIdx, greaterThanOrEqualTo(0), reason: 'build 里必须有 mobileScan 文字');
      expect(mobileScanIdx, greaterThan(qrIdx), reason: 'mobileScan 提示文字应该在 QR 码下方，避免被溢出条遮挡');
    });
  });
}
