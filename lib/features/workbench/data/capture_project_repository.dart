import 'dart:convert';

import 'package:proxypin/features/workbench/domain/capture_project.dart';
import 'package:proxypin/storage/path.dart';

class CaptureProjectRepository {
  static const _fileName = 'capture_projects.json';

  Future<List<CaptureProject>> load() async {
    final file = await Paths.getPath(_fileName);
    final content = await file.readAsString();
    if (content.trim().isEmpty) return [];
    final decoded = jsonDecode(content);
    if (decoded is! List) return [];
    return decoded.whereType<Map>().map((item) => CaptureProject.fromJson(Map<String, dynamic>.from(item))).toList();
  }

  Future<void> save(List<CaptureProject> projects) async {
    final file = await Paths.getPath(_fileName);
    final temporary = await Paths.getPath('$_fileName.tmp');
    await temporary.writeAsString(jsonEncode(projects.map((project) => project.toJson()).toList()));
    await temporary.rename(file.path);
  }
}
