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
        header: 'File not yet read, here is the current content:',
        content: content,
      );
    }

    final recordedMtime = _cache[normalized];
    if (recordedMtime != null && currentMtime > recordedMtime) {
      final content = file.readAsStringSync();
      recordRead(filePath, currentMtime);
      return GuardResult(
        header: 'File modified since last read, here is the new content:',
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
