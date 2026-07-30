// Walk up the directory tree looking for marker files. Used by
// LSP server specs to figure out where a project's root is.
//
// Inspired by OpenCode's `Filesystem.up` helper. The behavior:
//   - Start at `start` and walk to its parent, then grandparent, etc.
//   - Stop without entering `stop` (exclusive upper bound).
//   - Return the first directory that contains at least one of the
//     `markers` in its direct children (not recursively).
//   - If `excludeMarkers` is non-empty, skip directories that contain
//     any of those — useful for "find nearest package.json but not
//     inside a node_modules subtree".
//   - If no hit and `fallbackToStop` is true, return `stop`. Otherwise
//     return null.

import 'dart:io';

import 'package:path/path.dart' as p;

/// Walk up from [start] looking for any of [markers]. Returns the
/// directory containing the first hit, or null if `stop` is reached
/// without one.
Future<String?> findUp({
  required List<String> markers,
  required String start,
  required String stop,
  List<String> excludeMarkers = const [],
}) async {
  final stopNorm = p.normalize(p.absolute(stop));
  var dir = p.normalize(p.absolute(start));
  if (!Directory(dir).existsSync()) {
    dir = p.dirname(dir);
  }

  while (true) {
    if (excludeMarkers.isNotEmpty && _hasAny(dir, excludeMarkers)) {
      // Excluded — skip this directory and walk up.
      final parent = p.dirname(dir);
      if (parent == dir || _isAtOrAbove(parent, stopNorm)) return null;
      dir = parent;
      continue;
    }
    if (_hasAny(dir, markers)) {
      return dir;
    }
    if (_isAtOrAbove(dir, stopNorm)) return null;
    final parent = p.dirname(dir);
    if (parent == dir) return null; // reached filesystem root
    dir = parent;
  }
}

/// Same as [findUp] but returns [stop] if nothing is found. Convenient
/// for servers that always have a meaningful fallback (most do).
Future<String> findUpOrStop({
  required List<String> markers,
  required String start,
  required String stop,
  List<String> excludeMarkers = const [],
}) async {
  final hit = await findUp(
    markers: markers,
    start: start,
    stop: stop,
    excludeMarkers: excludeMarkers,
  );
  return hit ?? stop;
}

bool _hasAny(String dir, List<String> filenames) {
  for (final name in filenames) {
    if (File(p.join(dir, name)).existsSync()) return true;
  }
  return false;
}

bool _isAtOrAbove(String dir, String stop) {
  return p.normalize(dir) == p.normalize(stop);
}
