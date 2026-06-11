import 'dart:io';

import 'package:path/path.dart' as p;

String resolveUserDataDirectory({
  Map<String, String>? environment,
  bool? isWindows,
  String? systemTempPath,
  bool Function(String path)? directoryExists,
}) {
  final env = environment ?? Platform.environment;
  final windows = isWindows ?? Platform.isWindows;

  if (windows) {
    final exists =
        directoryExists ?? (String path) => Directory(path).existsSync();
    final legacyHomes = <String>{};
    for (final variableName in const ['HOME', 'USERPROFILE']) {
      final home = _nonEmpty(env[variableName]);
      if (home != null) legacyHomes.add(home);
    }
    for (final home in legacyHomes) {
      final legacyDirectory = p.join(home, '.local', 'share', 'crux');
      if (exists(legacyDirectory)) {
        return legacyDirectory;
      }
    }

    final dataHome =
        _nonEmpty(env['LOCALAPPDATA']) ??
        _nonEmpty(env['APPDATA']) ??
        _nonEmpty(env['USERPROFILE']) ??
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

String? _nonEmpty(String? value) {
  return value == null || value.isEmpty ? null : value;
}
