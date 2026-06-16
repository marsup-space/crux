import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;

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

  Map<String, dynamic> toJson() => {
    'path': path,
    'lastOpenedMs': lastOpenedAt.millisecondsSinceEpoch,
  };

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
/// Backed by `<userDataDir>/recent_projects.json` so the list survives
/// across Crux invocations. The on-disk format is a small JSON document
/// with an `entries` array, oldest entries trimmed once
/// [maxEntries] is exceeded.
///
/// The store fires [ChangeNotifier] notifications on every mutation
/// so widgets that show suggestions (the chat input's `/project`
/// autocomplete, for instance) can re-render without polling.
///
/// File I/O errors (missing file, malformed JSON, write failure) are
/// swallowed: the store falls back to an empty in-memory list and
/// tries again on the next write. Crux should keep launching even
/// when the recent-projects file is busted.
class RecentProjectsStore extends ChangeNotifier {
  /// Maximum number of entries kept on disk and in memory.
  static const int maxEntries = 16;

  /// Absolute path of the JSON file backing this store. Exposed for
  /// `/d-paths` debug output and tests.
  final String filePath;

  List<RecentProject> _entries = const [];

  RecentProjectsStore._(this.filePath, this._entries);

  /// Build an empty store pointing at the canonical on-disk location.
  /// Use this when the chat panel needs a non-null instance up
  /// front (before the disk read resolves) and will populate it
  /// from [load] shortly afterwards. Subsequent [add] calls persist
  /// as usual.
  factory RecentProjectsStore.empty() {
    return RecentProjectsStore._(
      p.join(resolveUserDataDirectory(), 'recent_projects.json'),
      const [],
    );
  }

  /// Test-only constructor that points the store at an arbitrary
  /// JSON file. Production code should use [RecentProjectsStore.empty]
  /// or [RecentProjectsStore.load] so the file lives under the
  /// canonical user-data dir. Kept public (rather than hidden in a
  /// test-only sublibrary) so the on-disk format can be exercised
  /// directly without polluting the user's real recent-projects list.
  ///
  /// Named `forTesting` to discourage accidental use from app code;
  /// using this in production will diverge the recent-projects file
  /// from the canonical location the rest of Crux reads from.
  factory RecentProjectsStore.forTesting(String filePath) {
    return RecentProjectsStore._(filePath, const []);
  }

  /// Resolve the canonical on-disk location and load any persisted
  /// entries. Returns an empty list when the file is missing or
  /// unreadable.
  static Future<RecentProjectsStore> load() async {
    final filePath = p.join(resolveUserDataDirectory(), 'recent_projects.json');
    final file = File(filePath);
    if (!await file.exists()) {
      return RecentProjectsStore._(filePath, const []);
    }
    try {
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        return RecentProjectsStore._(filePath, const []);
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return RecentProjectsStore._(filePath, const []);
      }
      final rawEntries = decoded['entries'];
      if (rawEntries is! List) {
        return RecentProjectsStore._(filePath, const []);
      }
      final entries = <RecentProject>[];
      for (final raw in rawEntries) {
        if (raw is Map<String, dynamic>) {
          final entry = RecentProject.fromJson(raw);
          if (entry.path.isNotEmpty) entries.add(entry);
        }
      }
      return RecentProjectsStore._(filePath, entries);
    } catch (_) {
      return RecentProjectsStore._(filePath, const []);
    }
  }

  /// Replace the in-memory list with [newEntries]. No file write —
  /// the caller has either already loaded from disk or is about to
  /// overwrite the file via a subsequent [add]/[clear]. Fires
  /// [notifyListeners] when the list actually changes.
  ///
  /// Used by the chat panel after the async [load] resolves to
  /// pour the persisted entries into the placeholder store created
  /// in `initState`. Avoiding a duplicate file write at that point
  /// keeps the in-memory state and the on-disk JSON identical.
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

    final next = <RecentProject>[RecentProject(
      path: normalized,
      lastOpenedAt: now,
    )];
    for (final existing in _entries) {
      if (p.equals(existing.path, normalized)) continue;
      next.add(existing);
      if (next.length >= maxEntries) break;
    }
    _entries = next;
    notifyListeners();

    try {
      await File(filePath).parent.create(recursive: true);
      final payload = jsonEncode({
        'entries': _entries.map((e) => e.toJson()).toList(),
      });
      await File(filePath).writeAsString('$payload\n', flush: true);
    } catch (_) {
      // Best-effort: in-memory state is still updated, so a later
      // successful write will eventually flush the latest snapshot.
    }
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
}