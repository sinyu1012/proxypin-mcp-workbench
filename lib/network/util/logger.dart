import 'package:flutter/foundation.dart';

import 'dart:io';
import 'package:logger/logger.dart';

class _AllLevelFilter extends LogFilter {
  @override
  bool shouldLog(LogEvent event) {
    return true;
  }
}

final logger = Logger(
    filter: _AllLevelFilter(),
    printer: PrettyPrinter(
      methodCount: 0,
      errorMethodCount: 15,
      lineLength: 120,
      colors: true,
      printEmojis: false,
      excludeBox: {Level.info: true, Level.debug: true},
    ),
    output: _DebugFileOutput(),
  );

class _DebugFileOutput extends LogOutput {
  File? _file;

  @override
  void output(OutputEvent event) {
    if (!kReleaseMode) {
      try {
        _file ??= File('${Platform.resolvedExecutable.substring(0, Platform.resolvedExecutable.lastIndexOf(Platform.pathSeparator))}${Platform.pathSeparator}proxypin_debug.log');
        _file!.writeAsStringSync('${event.lines.join('\n')}\n', mode: FileMode.append);
      } catch (_) {}
    }
    for (var line in event.lines) {
      print(line);
    }
  }
}
