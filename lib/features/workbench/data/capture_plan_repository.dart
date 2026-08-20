import 'dart:convert';

import 'package:proxypin/features/workbench/domain/capture_plan.dart';
import 'package:proxypin/storage/path.dart';

class CapturePlanRepository {
  static const _fileName = 'capture_plans.json';

  Future<List<CapturePlan>> load() async {
    final file = await Paths.getPath(_fileName);
    final content = await file.readAsString();
    if (content.trim().isEmpty) return [];
    final decoded = jsonDecode(content);
    if (decoded is! List) return [];
    return decoded
        .whereType<Map>()
        .map((item) => CapturePlan.fromJson(Map<String, dynamic>.from(item)))
        .where((plan) => plan.id.isNotEmpty)
        .toList(growable: false);
  }

  Future<void> save(List<CapturePlan> plans) async {
    final file = await Paths.getPath(_fileName);
    final temporary = await Paths.getPath('$_fileName.tmp');
    await temporary.writeAsString(jsonEncode(plans.map((plan) => plan.toJson()).toList(growable: false)));
    await temporary.rename(file.path);
  }
}
