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

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/ui/desktop/request/request_sequence.dart';

/// 滚动隐藏右侧图标的策略：
///   - 列表 <= 50 条：始终展示 trailing
///   - 列表 > 50 条：滚动中隐藏，停止后展示
///   - 滚动结束用 ~150ms 延迟以容忍惯性滚动
void main() {
  group('RequestSequenceState.shouldShowTrailing', () {
    test('shows trailing when list length is at or below the threshold (50), even while scrolling', () {
      // 边界值：正好 50
      expect(RequestSequenceState.shouldShowTrailing(50, true), isTrue);
      expect(RequestSequenceState.shouldShowTrailing(50, false), isTrue);
      // 远低于阈值
      expect(RequestSequenceState.shouldShowTrailing(0, true), isTrue);
      expect(RequestSequenceState.shouldShowTrailing(1, true), isTrue);
      expect(RequestSequenceState.shouldShowTrailing(49, true), isTrue);
    });

    test('hides trailing when list exceeds threshold AND user is scrolling', () {
      expect(RequestSequenceState.shouldShowTrailing(51, true), isFalse);
      expect(RequestSequenceState.shouldShowTrailing(100, true), isFalse);
      expect(RequestSequenceState.shouldShowTrailing(1000, true), isFalse);
    });

    test('shows trailing when list exceeds threshold and scrolling has stopped', () {
      expect(RequestSequenceState.shouldShowTrailing(51, false), isTrue);
      expect(RequestSequenceState.shouldShowTrailing(100, false), isTrue);
      expect(RequestSequenceState.shouldShowTrailing(1000, false), isTrue);
    });
  });

  group('RequestSequence scroll behavior', () {
    testWidgets('hides trailing icons while scrolling a list with more than 50 items', (tester) async {
      // 视口放大，避免 ListView 懒构建造成越界行不可见
      tester.view.physicalSize = const Size(1080, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const _ScrollHarness(items: 60));
      await tester.pump();

      // 初始（未滚动）：所有可见行展示 trailing
      expect(find.byKey(const Key('trailing-0')), findsOneWidget);
      expect(find.byKey(const Key('trailing-30')), findsOneWidget);
      expect(find.byKey(const Key('trailing-59')), findsOneWidget);

      // 触发滚动：拖动 Scrollable 让 ScrollStart + ScrollUpdate 上报
      final scrollable = find.byType(Scrollable);
      await tester.drag(scrollable, const Offset(0, -300));
      await tester.pump();

      // 滚动中：可见行的 trailing 全部消失
      expect(find.byKey(const Key('trailing-0')), findsNothing);
      expect(find.byKey(const Key('trailing-30')), findsNothing);
      expect(find.byKey(const Key('trailing-59')), findsNothing);
    });

    testWidgets('keeps trailing icons visible while scrolling a list with 50 items or fewer', (tester) async {
      tester.view.physicalSize = const Size(1080, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const _ScrollHarness(items: 50));
      await tester.pump();

      expect(find.byKey(const Key('trailing-0')), findsOneWidget);
      expect(find.byKey(const Key('trailing-49')), findsOneWidget);

      final scrollable = find.byType(Scrollable);
      await tester.drag(scrollable, const Offset(0, -200));
      await tester.pump();

      // <=50 条：滚动中仍展示
      expect(find.byKey(const Key('trailing-0')), findsOneWidget);
      expect(find.byKey(const Key('trailing-49')), findsOneWidget);
    });
  });
}

/// 轻量测试 fixture：模拟 RequestSequence 的滚动隐藏行为。
/// 不实例化真正的 RequestSequence（避免拖入 ProxyServer / RequestWidget 等重型依赖），
/// 但保留与生产代码完全一致的事件流：
///   - 应在列表 `>50 行 && 滚动中` 时返回 null 作为 trailing
///   - ScrollStart/Update 设 _isScrolling=true 并清掉旧 timer
///   - ScrollEnd 启动 150ms 延迟 timer
///   - 应在列表 >50 行 && 滚动中 时返回 null 作为 trailing
class _ScrollHarness extends StatefulWidget {
  final int items;
  const _ScrollHarness({required this.items});

  @override
  State<_ScrollHarness> createState() => _ScrollHarnessState();
}

class _ScrollHarnessState extends State<_ScrollHarness> {
  bool _isScrolling = false;
  Timer? _scrollEndTimer;

  @override
  void dispose() {
    _scrollEndTimer?.cancel();
    super.dispose();
  }

  bool _handleScrollNotification(ScrollNotification n) {
    if (n is ScrollStartNotification || n is ScrollUpdateNotification) {
      if (!_isScrolling) {
        setState(() => _isScrolling = true);
      }
      _scrollEndTimer?.cancel();
    } else if (n is ScrollEndNotification) {
      _scrollEndTimer?.cancel();
      _scrollEndTimer = Timer(RequestSequenceState.scrollStopDelay, () {
        if (mounted) setState(() => _isScrolling = false);
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: NotificationListener<ScrollNotification>(
          onNotification: _handleScrollNotification,
          child: ListView.builder(
            itemCount: widget.items,
            itemBuilder: (context, index) {
              final showTrailing = RequestSequenceState.shouldShowTrailing(widget.items, _isScrolling);
              return ListTile(
                title: Text('row $index'),
                trailing: showTrailing ? SizedBox(key: Key('trailing-$index'), width: 10, height: 10) : null,
              );
            },
          ),
        ),
      ),
    );
  }
}
