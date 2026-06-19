import 'dart:io';

import 'tool_def.dart';

class FileReadTracker {
  final Map<String, int> _cache = {};
  int? _sessionId;
  final Future<void> Function(
    int sessionId,
    String normalizedPath,
    int mtimeMs,
  )?
  onRecordRead;

  FileReadTracker({int? sessionId, this.onRecordRead}) : _sessionId = sessionId;

  Future<void> recordRead(String filePath, int mtimeMs) async {
    final normalized = _normalize(filePath);
    _cache[normalized] = mtimeMs;
    if (_sessionId != null && onRecordRead != null) {
      try {
        await onRecordRead!(_sessionId!, normalized, mtimeMs);
      } catch (_) {
        // Persistence failure is non-fatal — the in-memory cache
        // update above is sufficient for the current session.
      }
    }
  }

  Future<GuardResult?> checkWriteGuard(String filePath) async {
    final normalized = _normalize(filePath);
    final file = File(filePath);

    if (!file.existsSync()) return null;

    final currentMtime = file.statSync().modified.millisecondsSinceEpoch;

    if (!_cache.containsKey(normalized)) {
      final content = file.readAsStringSync();
      await recordRead(filePath, currentMtime);
      return GuardResult(
        header:
            '[GUARD] Write was BLOCKED — file was not read before write. '
            'Your write did NOT take effect. The current file content is '
            'below; call edit or write again now and it will succeed '
            '(the file has been auto-read for you).',
        content: content,
        reason: 'read-before-write',
      );
    }

    final recordedMtime = _cache[normalized];
    if (recordedMtime != null && currentMtime > recordedMtime) {
      final content = file.readAsStringSync();
      await recordRead(filePath, currentMtime);
      return GuardResult(
        header:
            '[GUARD] Write was BLOCKED — file was modified since last '
            'read. Your write did NOT take effect. The new content is '
            'below; retry your edit with a pattern that matches this version.',
        content: content,
        reason: 'read-before-write',
      );
    }

    return null;
  }

  void loadFromMap(Map<String, int> data) {
    _cache.addAll(data.map((k, v) => MapEntry(_normalize(k), v)));
  }

  void loadSession(int sessionId, Map<String, int> data) {
    _sessionId = sessionId;
    _cache.clear();
    _cache.addAll(data.map((k, v) => MapEntry(_normalize(k), v)));
  }

  void clear() {
    _cache.clear();
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
