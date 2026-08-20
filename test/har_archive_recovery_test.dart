import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/utils/har.dart';

void main() {
  test('中断归档忽略损坏尾行并保留完整请求', () async {
    final directory = await Directory.systemTemp.createTemp('proxypin-archive-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/capture.txt');
    final request = HttpRequest(HttpMethod.get, 'https://api.example.com/records');

    await file.writeAsString(
      '${jsonEncode(Har.toHar(request))},\n'
      '{"startedDateTime":"2026-08-20T00:00:00Z",',
    );

    final restored = await Har.readFile(file);

    expect(restored, hasLength(1));
    expect(restored.single.requestUrl, request.requestUrl);
  });

  test('完整但没有尾随逗号的归档行仍可读取', () async {
    final directory = await Directory.systemTemp.createTemp('proxypin-archive-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/capture.txt');
    final request = HttpRequest(HttpMethod.get, 'https://api.example.com/records');
    await file.writeAsString(jsonEncode(Har.toHar(request)));

    final restored = await Har.readFile(file);

    expect(restored.single.requestUrl, request.requestUrl);
  });
}
