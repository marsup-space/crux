import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';

import '../utils/user_data_directory.dart';

/// One entry in the recently-opened-projects list.
///
/// The store keeps these in MRU order (most-recently opened first),
/// dedupes on absolute path, and caps the list at
/// [RecentProjectsStore.maxEntries].
class RecentProject {
  /// Absolute, normalized path (e.g. `/Users/me/code/foo`). Never empty.
  final String path;

  /// When this project was last opened. Updated every time the same
  /// path is re-added; the entry stays at the top of the MRU list.
  final DateTime lastOpenedAt;

  const RecentProject({required this.path, required this.lastOpenedAt});

  /// TOML-friendly representation: `[[entries]]` array-of-tables.
  Map<String, dynamic> toToml() => {
    'path': path,
    'lastOpenedMs': lastOpenedAt.millisecondsSinceEpoch,
  };

  /// Legacy JSON representation — kept for backward compat in tests.
  Map<String, dynamic> toJson() => toToml();

  factory RecentProject.fromJson(Map<String, dynamic> json) {
    final path = json['path'];
    final lastOpenedMs = json['lastOpenedMs'];
    return RecentProject(
      path: path is String ? path : '',
      lastOpenedAt: lastOpenedMs is int
          ? DateTime.fromMillisecondsSinceEpoch(lastOpenedMs)
          : DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  @override
  String toString() =>
      'RecentProject(path: $path, lastOpenedAt: $lastOpenedAt)';
}

/// Persistent list of recently-opened project directories.
///
/// Backed by `<userDataDir>/recent_projects.toml` so the list survives
/// across Crux invocations. The on-disk format is TOML with an
/// `[[entries]]` array-of-tables; oldest entries trimmed once
/// [maxEntries] is exceeded.
///
/// Legacy `<userDataDir>/recent_projects.json` files are still read
/// on load (backward compatibility), but writes always go to `.toml`.
///
/// The store fires [ChangeNotifier] notifications on every mutation
/// so widgets that show suggestions (the chat input's `/project`
/// autocomplete, for instance) can re-render without polling.
///
/// File I/O errors (missing file, malformed TOML, write failure) are
/// swallowed: the store falls back to an empty in-memory list and
/// tries again on the next write. Crux should keep launching even
/// when the recent-projects file is busted.
class RecentProjectsStore extends ChangeNotifier {
  /// Maximum number of entries kept on disk and in memory.
  static const int maxEntries = 16;

  /// Absolute path of the file backing this store. Exposed for
  /// `/d-paths` debug output and tests.
  final String filePath;

  /// Whether the backing file is TOML. Always true in production;
  /// test-only constructors that use `.json` paths may set this to
  /// false for JSON roundtrip verification.
  final bool _useToml;

  /// Canonical TOML file path.
  static String _canonicalTomlPath() =>
      p.join(resolveUserDataDirectory(), 'recent_projects.toml');

  /// Legacy JSON file path (read only, for backward compat).
  static String _canonicalJsonPath() =>
      p.join(resolveUserDataDirectory(), 'recent_projects.json');

  List<RecentProject> _entries = const [];

  RecentProjectsStore._(this.filePath, this._entries, this._useToml);

  /// Build an empty store pointing at the canonical TOML location.
  /// Use this when the chat panel needs a non-null instance up
  /// front (before the disk read resolves) and will populate it
  /// from [load] shortly afterwards. Subsequent [add] calls persist
  /// as usual (in TOML format).
  factory RecentProjectsStore.empty() {
    return RecentProjectsStore._(_canonicalTomlPath(), const [], true);
  }

  /// Test-only constructor that points the store at an arbitrary
  /// file. Production code should use [RecentProjectsStore.empty]
  /// or [RecentProjectsStore.load] so the file lives under the
  /// canonical user-data dir.
  ///
  /// If [asJson] is true (default), the path suffix should be `.json`
  /// and the store reads/writes JSON exclusively. Tests that want to
  /// exercise the TOML format should pass `asJson: false` with a
  /// `.toml` path.
  ///
  /// Named `forTesting` to discourage accidental use from app code.
  factory RecentProjectsStore.forTesting(
    String filePath, {
    bool asJson = true,
  }) {
    return RecentProjectsStore._(filePath, const [], !asJson);
  }

  /// Resolve the canonical on-disk location and load any persisted
  /// entries. Reads `recent_projects.toml` first; if that doesn't
  /// exist, falls back to the legacy `recent_projects.json`. Returns
  /// an empty list when both are missing or unreadable.
  static Future<RecentProjectsStore> load() async {
    final tomlPath = _canonicalTomlPath();
    final tomlFile = File(tomlPath);

    // Try TOML first
    if (await tomlFile.exists()) {
      try {
        final raw = await tomlFile.readAsString();
        if (raw.trim().isNotEmpty) {
          final map = TomlDocument.parse(raw).toMap();
          final entries = _parseEntries(map);
          return RecentProjectsStore._(tomlPath, entries, true);
        }
      } catch (_) {
        // Fall through to JSON
      }
    }

    // Fall back to legacy JSON
    final jsonPath = _canonicalJsonPath();
    final jsonFile = File(jsonPath);
    if (!await jsonFile.exists()) {
      return RecentProjectsStore._(tomlPath, const [], true);
    }
    try {
      final raw = await jsonFile.readAsString();
      if (raw.trim().isEmpty) {
        return RecentProjectsStore._(tomlPath, const [], true);
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return RecentProjectsStore._(tomlPath, const [], true);
      }
      final rawEntries = decoded['entries'];
      if (rawEntries is! List) {
        return RecentProjectsStore._(tomlPath, const [], true);
      }
      final entries = <RecentProject>[];
      for (final raw in rawEntries) {
        if (raw is Map<String, dynamic>) {
          final entry = RecentProject.fromJson(raw);
          if (entry.path.isNotEmpty) entries.add(entry);
        }
      }
      return RecentProjectsStore._(tomlPath, entries, true);
    } catch (_) {
      return RecentProjectsStore._(tomlPath, const [], true);
    }
  }

  /// Parse `entries` from a `TomlDocument.toMap()` result.
  /// Accepts both `[[entries]]` (array-of-tables → `List<Map>`) and
  /// `entries = [{...}]` (inline array).
  static List<RecentProject> _parseEntries(Map<String, dynamic> map) {
    final rawEntries = map['entries'];
    if (rawEntries is List) {
      final entries = <RecentProject>[];
      for (final raw in rawEntries) {
        if (raw is Map<String, dynamic>) {
          final entry = RecentProject.fromJson(raw);
          if (entry.path.isNotEmpty) entries.add(entry);
        }
      }
      return entries;
    }
    return const [];
  }

  /// Replace the in-memory list with [newEntries]. No file write —
  /// the caller has either already loaded from disk or is about to
  /// overwrite the file via a subsequent [add]/[clear]. Fires
  /// [notifyListeners] when the list actually changes.
  ///
  /// Used by the chat panel after the async [load] resolves to
  /// pour the persisted entries into the placeholder store created
  /// in `initState`. Avoiding a duplicate file write at that point
  /// keeps the in-memory state and the on-disk data identical.
  void seed(List<RecentProject> newEntries) {
    if (_listEquals(_entries, newEntries)) return;
    _entries = List.unmodifiable(newEntries);
    notifyListeners();
  }

  static bool _listEquals(List<RecentProject> a, List<RecentProject> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].path != b[i].path) return false;
      if (a[i].lastOpenedAt != b[i].lastOpenedAt) return false;
    }
    return true;
  }

  /// In-memory, read-only view of the recent-projects list, ordered
  /// most-recent first. Widgets bind to this and re-render when the
  /// store calls [notifyListeners].
  List<RecentProject> get entries => List.unmodifiable(_entries);

  /// Record [absolutePath] as the most-recently-opened project.
  ///
  /// Normalizes the path (resolves symlinks and collapses `.`/`..`)
  /// before storing so the same logical directory always maps to the
  /// same entry regardless of how it was typed. Re-adding an existing
  /// path promotes it to the front and updates its timestamp; the
  /// list is then trimmed back down to [maxEntries] entries.
  ///
  /// The write is best-effort: a failure to persist (e.g. the user
  /// data dir is read-only) is swallowed silently so a transient I/O
  /// hiccup doesn't break the running TUI.
  Future<void> add(String absolutePath) async {
    final normalized = _normalize(absolutePath);
    if (normalized.isEmpty) return;
    final now = DateTime.now();

    final next = <RecentProject>[
      RecentProject(path: normalized, lastOpenedAt: now),
    ];
    for (final existing in _entries) {
      if (p.equals(existing.path, normalized)) continue;
      next.add(existing);
      if (next.length >= maxEntries) break;
    }
    _entries = next;
    notifyListeners();

    try {
      await File(filePath).parent.create(recursive: true);
      if (_useToml) {
        await _writeToml();
      } else {
        final payload = jsonEncode({
          'entries': _entries.map((e) => e.toJson()).toList(),
        });
        await File(filePath).writeAsString('$payload\n', flush: true);
      }
    } catch (_) {
      // Best-effort: in-memory state is still updated, so a later
      // successful write will eventually flush the latest snapshot.
    }
  }

  /// Serialize current entries to TOML as `[[entries]]` array-of-tables.
  Future<void> _writeToml() async {
    final buf = StringBuffer();
    buf.writeln('# Crux recent projects — managed automatically');
    for (final entry in _entries) {
      buf.writeln();
      buf.writeln('[[entries]]');
      buf.writeln('path = ${_tomlEscapeString(entry.path)}');
      buf.writeln(
        'lastOpenedMs = ${entry.lastOpenedAt.millisecondsSinceEpoch}',
      );
    }
    buf.writeln();
    await File(filePath).writeAsString(buf.toString(), flush: true);
  }

  /// Drop every entry. Used by future debug commands or a "Clear
  /// recent projects" menu item; not wired into the UI today.
  Future<void> clear() async {
    if (_entries.isEmpty) return;
    _entries = const [];
    notifyListeners();
    try {
      final file = File(filePath);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Same swallow-best-effort policy as [add].
    }
  }

  /// Normalize a user-supplied project path to an absolute, symlink-
  /// resolved string. Falls back to the raw absolute path when the
  /// directory no longer exists (so a recent entry that the user
  /// later deleted still surfaces in the suggestion list — the
  /// executor will show "Directory not found" if they pick it).
  static String _normalize(String path) {
    if (path.isEmpty) return '';
    final absolute = p.normalize(p.absolute(path));
    try {
      // `resolveSymbolicLinks` returns the canonical path when the
      // target exists. On platforms where it throws (broken symlink,
      // permission denied), fall back to the raw absolute form.
      return Directory(absolute).resolveSymbolicLinksSync();
    } catch (_) {
      return absolute;
    }
  }

  /// Escape a string for a TOML basic string value.
  static String _tomlEscapeString(String s) {
    final escaped = s
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"')
        .replaceAll('\b', '\\b')
        .replaceAll('\f', '\\f')
        .replaceAll('\n', '\\n')
        .replaceAll('\r', '\\r')
        .replaceAll('\t', '\\t');
    return '"$escaped"';
  }
}
