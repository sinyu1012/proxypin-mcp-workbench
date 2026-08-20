import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/ui/content/panel.dart';

void main() {
  test('split layout only activates on desktop at the breakpoint', () {
    expect(useSplitNetworkDetail(719.9, desktop: true), isFalse);
    expect(useSplitNetworkDetail(720, desktop: true), isTrue);
    expect(useSplitNetworkDetail(1400, desktop: false), isFalse);
  });

  testWidgets('wide layout shows request and response side by side', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final exchange = _exchange('/v1/items?q=1', 200, 'OK');
    exchange.request.headers.set('Content-Type', 'text/plain');
    exchange.response.headers.set('Content-Type', 'text/plain');
    exchange.request.body = utf8.encode('request-marker');
    exchange.response.body = utf8.encode('response-marker');
    final controller = NetworkTabController(
      httpRequest: exchange.request,
      httpResponse: exchange.response,
    );

    await tester.pumpWidget(_harness(controller, width: 1100));
    await tester.pumpAndSettle();

    final requestPane = find.byKey(const Key('request-pane'));
    final responsePane = find.byKey(const Key('response-pane'));
    expect(find.byKey(const Key('network-detail-wide')), findsOneWidget);
    expect(requestPane, findsOneWidget);
    expect(responsePane, findsOneWidget);
    expect(tester.getTopLeft(requestPane).dx, lessThan(tester.getTopLeft(responsePane).dx));
    expect(find.byKey(const Key('request-body')), findsOneWidget);
    expect(find.byKey(const Key('response-body')), findsOneWidget);
    expect(find.text('StatusCode'), findsOneWidget);
    expect(find.text('200  OK'), findsAtLeastNWidgets(1));
    expect(find.text('request-marker'), findsOneWidget);
    expect(find.text('response-marker'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide response pane refreshes when a delayed response arrives', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final request = HttpRequest(
      HttpMethod.get,
      'https://example.test/v1/delayed',
    );
    final controller = NetworkTabController(httpRequest: request);
    await tester.pumpWidget(_harness(controller, width: 1100));
    await tester.pumpAndSettle();

    expect(find.text('等待响应'), findsOneWidget);

    final response = HttpResponse(HttpStatus(201, 'Created'))..request = request;
    controller.updateResponses([response]);
    await tester.pumpAndSettle();

    expect(find.text('等待响应'), findsNothing);
    expect(find.text('201  Created'), findsAtLeastNWidgets(1));
    expect(find.byKey(const Key('response-body')), findsOneWidget);
  });

  testWidgets('wide layout keeps SSE visibility semantics on the request pane', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final exchange = _exchange('/v1/events', 200, 'OK');
    exchange.response.headers.set('Content-Type', 'text/event-stream');
    final controller = NetworkTabController(
      httpRequest: exchange.request,
      httpResponse: exchange.response,
    );
    await tester.pumpWidget(_harness(controller, width: 1100));
    await tester.pumpAndSettle();

    expect(controller.isSseTabVisible, isFalse);
    await tester.tap(find.text('SSE'));
    await tester.pumpAndSettle();
    expect(controller.isSseTabVisible, isTrue);

    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(controller.isSseTabVisible, isFalse);
    expect(find.byKey(const Key('response-pane')), findsOneWidget);
  });

  testWidgets('ordinary Cookies tab is not reported as a stream tab', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final exchange = _exchange('/v1/cookies', 200, 'OK');
    final controller = NetworkTabController(
      httpRequest: exchange.request,
      httpResponse: exchange.response,
    );
    await tester.pumpWidget(_harness(controller, width: 1100));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cookies'));
    await tester.pumpAndSettle();
    expect(controller.isSseTabVisible, isFalse);
    expect(find.byKey(const Key('response-pane')), findsOneWidget);
  });

  testWidgets('an unrelated stream message cannot replace the selected exchange', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final selected = _exchange('/v1/selected', 200, 'OK');
    final unrelated = _exchange('/v1/unrelated', 200, 'OK');
    unrelated.response.headers.set('Content-Type', 'text/event-stream');
    final controller = NetworkTabController(
      httpRequest: selected.request,
      httpResponse: selected.response,
    );
    await tester.pumpWidget(_harness(controller, width: 1100));
    await tester.pumpAndSettle();

    controller.updateForStreamMessage(unrelated.response);
    await tester.pump();

    expect(controller.request.get(), same(selected.request));
    expect(controller.response.get(), same(selected.response));
  });

  testWidgets('the same panel can cross the responsive breakpoint safely', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final exchange = _exchange('/v1/resize', 200, 'OK');
    final controller = NetworkTabController(
      httpRequest: exchange.request,
      httpResponse: exchange.response,
    );

    await tester.pumpWidget(_harness(controller, width: 1100));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('network-detail-wide')), findsOneWidget);

    await tester.pumpWidget(_harness(controller, width: 600));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('network-detail-compact')), findsOneWidget);

    await tester.pumpWidget(_harness(controller, width: 1100));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('response-pane')), findsOneWidget);
    expect(find.text('200  OK'), findsAtLeastNWidgets(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('very narrow compact layout keeps the WebSocket tab reachable', (tester) async {
    tester.view.physicalSize = const Size(500, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final exchange = _exchange('/v1/socket', 101, 'Switching Protocols');
    exchange.request.headers.set('Upgrade', 'websocket');
    final controller = NetworkTabController(
      httpRequest: exchange.request,
      httpResponse: exchange.response,
    );
    await tester.pumpWidget(_harness(controller, width: 320));
    await tester.pumpAndSettle();

    final webSocketTab = find.text('WebSocket');
    await tester.ensureVisible(webSocketTab);
    await tester.tap(webSocketTab);
    await tester.pumpAndSettle();

    expect(controller.isSseTabVisible, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact layout keeps the original tab navigation', (tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final exchange = _exchange('/v1/compact', 200, 'OK');
    final controller = NetworkTabController(
      httpRequest: exchange.request,
      httpResponse: exchange.response,
    );
    await tester.pumpWidget(_harness(controller, width: 600));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('network-detail-compact')), findsOneWidget);
    expect(find.byKey(const Key('network-detail-wide')), findsNothing);

    await tester.tap(find.text('Response'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('response-body')), findsOneWidget);
    expect(find.text('200  OK'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Widget _harness(NetworkTabController controller, {required double width}) {
  return MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: width, height: 800, child: controller),
      ),
    ),
  );
}

({HttpRequest request, HttpResponse response}) _exchange(
  String path,
  int status,
  String reason,
) {
  final request = HttpRequest(
    HttpMethod.post,
    'https://example.test$path',
  );
  request.headers.set('Content-Type', 'application/json');
  final response = HttpResponse(HttpStatus(status, reason))..request = request;
  response.headers.set('Content-Type', 'application/json');
  request.response = response;
  return (request: request, response: response);
}
