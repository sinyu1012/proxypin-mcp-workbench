import 'package:proxypin/network/util/process_info.dart';

String applicationSourceKey(ProcessInfo? processInfo) {
  if (processInfo == null) return '';
  return '${processInfo.id}\u{1f}${processInfo.path}';
}

String applicationSourceLabel(ProcessInfo? processInfo) {
  final name = processInfo?.name.trim() ?? '';
  if (name.isNotEmpty) return name;
  final id = processInfo?.id.trim() ?? '';
  return id;
}

bool matchesApplicationSource(String? selectedApplicationKey, ProcessInfo? processInfo) {
  return selectedApplicationKey == null || selectedApplicationKey == applicationSourceKey(processInfo);
}
