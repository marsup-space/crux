import 'dart:io';

import 'package:path/path.dart' as p;

String resolveUserDataDirectory({
  Map<String, String>? environment,
  bool? isWindows,
  String? systemTempPath,
}) {
  final env = environment ?? Platform.environment;
  final windows = isWindows ?? Platform.isWindows;

  if (windows) {
    final dataHome =
        env['LOCALAPPDATA'] ??
        env['APPDATA'] ??
        env['USERPROFILE'] ??
        systemTempPath ??
        Directory.systemTemp.path;
    return p.join(dataHome, 'crux');
  }

  final xdgDataHome = env['XDG_DATA_HOME'];
  if (xdgDataHome != null && xdgDataHome.isNotEmpty) {
    return p.join(xdgDataHome, 'crux');
  }

  final home = env['HOME'];
  if (home != null && home.isNotEmpty) {
    return p.join(home, '.local', 'share', 'crux');
  }

  return p.join(systemTempPath ?? Directory.systemTemp.path, 'crux');
}
