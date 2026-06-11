import 'dart:io';

import 'tool_def.dart';

class FileReadTracker {
  final Map<String, int> _cache = {};

  void recordRead(String filePath, int mtimeMs) {
    final normalized = _normalize(filePath);
    _cache[normalized] = mtimeMs;
  }

  GuardResult? checkWriteGuard(String filePath) {
    final normalized = _normalize(filePath);
    final file = File(filePath);

    if (!file.existsSync()) return null;

    final currentMtime = file.statSync().modified.millisecondsSinceEpoch;

    if (!_cache.containsKey(normalized)) {
      final content = file.readAsStringSync();
      recordRead(filePath, currentMtime);
      return GuardResult(
        header:
            '[GUARD] No changes were made — file was not read before write. '
            'We re-read it for you (saved a round trip). The content is '
            'below; you can call edit/write again now without having to '
            'call read first.',
        content: content,
      );
    }

    final recordedMtime = _cache[normalized];
    if (recordedMtime != null && currentMtime > recordedMtime) {
      final content = file.readAsStringSync();
      recordRead(filePath, currentMtime);
      return GuardResult(
        header:
            '[GUARD] No changes were made — file was modified since last '
            'read. We re-read it for you (saved a round trip). The new '
            'content is below; retry your edit with a pattern that matches '
            'this version.',
        content: content,
      );
    }

    return null;
  }

  void loadFromMap(Map<String, int> data) {
    _cache.addAll(data.map((k, v) => MapEntry(_normalize(k), v)));
  }

  Map<String, int> toMap() {
    return Map.fromEntries(_cache.entries);
  }

  String _normalize(String path) {
    var p = path;
    if (!p.startsWith('/')) p = '/$p';
    p = p.replaceAll('/./', '/');
    p = p.replaceAll(RegExp(r'/\.$'), '');
    if (p.endsWith('/..')) {
      p = '${p.substring(0, p.length - 3)}/__dotdot__';
    }
    var iterations = 0;
    while (p.contains('/../') && iterations < 64) {
      p = p.replaceAll(RegExp(r'/[^/]+/\.\./'), '/');
      iterations++;
    }
    p = p.replaceAll('/__dotdot__', '/..');
    if (p.endsWith('/..')) {
      final lastSep = p.lastIndexOf('/', p.length - 4);
      if (lastSep > 0) {
        p = p.substring(0, lastSep);
      } else {
        p = '/';
      }
    }
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }
}
