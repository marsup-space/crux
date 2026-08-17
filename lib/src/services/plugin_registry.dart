// Discovers spec-driven plugins for a project.
//
// Scans, in precedence order (later dirs only fill ids not seen yet):
//
//   <project>/.crux/plugins/     canonical (new)
//   <project>/.crux/widgets/     legacy project specs (pre-rename)
//   ~/.crux/plugins/             global — available in EVERY project
//   ~/.crux/widgets/             legacy global specs
//
// Any session (or human) that writes a spec into one of these is
// picked up by *every* Crux session on the project within one scan
// interval — the filesystem is the bus, and the registry is the
// reader.
//
// GLOBAL plugins (~/.crux/plugins/): the spec file lives in the user's
// home, but its status path / shell commands resolve against the
// CURRENT PROJECT root at render time. One global "tests" plugin works
// on every repo you open, monitoring each repo's own files and running
// each repo's own commands.
//
// Scan is fingerprint-based (path → mtime:size): no notification when
// nothing changed, so neither the side panel nor home rebuilds every
// 2 s for no reason.

library;

import 'dart:async';
import 'dart:io';

import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;

import 'plugin.dart';

/// One scanned directory: its path and whether specs found there are
/// global (resolve against the project root, not their own location).
class PluginScanRoot {
  final Directory dir;
  final bool isGlobal;
  const PluginScanRoot(this.dir, {required this.isGlobal});
}

class PluginRegistry extends ChangeNotifier {
  /// The project (workspace) root the registry is keyed on.
  final String projectPath;
  final Duration scanInterval;

  /// Override for the user's home directory (tests). Null → derive
  /// from the environment, same resolution as skill discovery.
  final String? homeOverride;

  Timer? _timer;

  /// File-system watcher per scanned directory, so spec edits reload
  /// immediately (~200 ms debounce) instead of waiting for the next
  /// poll. The poll stays as a fallback: watchers can't see a
  /// directory being *created*, and some filesystems don't deliver
  /// events reliably.
  final Map<String, StreamSubscription<FileSystemEvent>> _watchSubs = {};
  Timer? _debounce;

  Map<String, String> _lastFingerprint = const {};
  Map<String, Plugin> _specs = const {};

  /// Warnings from the last scan (unreadable/malformed specs), for
  /// surfacing in the UI or logs. Replaced on each scan.
  List<String> lastWarnings = const [];

  PluginRegistry({
    required this.projectPath,
    this.scanInterval = const Duration(seconds: 2),
    this.homeOverride,
  });

  /// The scanned roots, in precedence order. Project dirs win over
  /// global dirs; `plugins/` wins over legacy `widgets/`.
  List<PluginScanRoot> scanRoots() {
    final home = homeOverride ?? _homeDir();
    return [
      PluginScanRoot(
        Directory(p.join(projectPath, '.crux', 'plugins')),
        isGlobal: false,
      ),
      PluginScanRoot(
        Directory(p.join(projectPath, '.crux', 'widgets')),
        isGlobal: false,
      ),
      PluginScanRoot(
        Directory(p.join(home, '.crux', 'plugins')),
        isGlobal: true,
      ),
      PluginScanRoot(
        Directory(p.join(home, '.crux', 'widgets')),
        isGlobal: true,
      ),
    ];
  }

  static String _homeDir() {
    return Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.systemTemp.path;
  }

  /// Parsed specs, in stable (id) order.
  List<Plugin> get plugins => _specs.values.toList()
    ..sort((a, b) => a.id.compareTo(b.id));

  /// Specs that render on the sidebar ([Plugin.showsOnSidebar]).
  List<Plugin> get sidebarPlugins =>
      plugins.where((s) => s.showsOnSidebar).toList();

  /// Specs that render on the home grid ([Plugin.showsOnHome]).
  List<Plugin> get homePlugins =>
      plugins.where((s) => s.showsOnHome).toList();

  /// Begin periodic scanning + file watching. Idempotent.
  void start() {
    _timer ??= Timer.periodic(scanInterval, (_) => scan());
    scan();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    for (final sub in _watchSubs.values) {
      sub.cancel();
    }
    _watchSubs.clear();
    _debounce?.cancel();
    _debounce = null;
    super.dispose();
  }

  /// Watch each scanned directory for .toml changes and re-scan
  /// (debounced) so spec edits hot-reload the surfaces.
  void _startWatchers() {
    for (final root in scanRoots()) {
      if (_watchSubs.containsKey(root.dir.path)) continue;
      try {
        if (!root.dir.existsSync()) continue;
        _watchSubs[root.dir.path] = root.dir.watch().listen((event) {
          if (event.path.endsWith('.toml')) {
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 200), scan);
          }
        });
      } catch (_) {
        // Watcher unavailable — the poll fallback covers reloads.
      }
    }
  }

  /// One scan pass: fingerprint all roots, re-parse only when
  /// something changed, notify on any spec-set change.
  void scan() {
    // Watchers only see *existing* directories — once a dir appears
    // (or reappears), (re)start its watcher from the poll.
    _startWatchers();

    final fingerprints = <String, String>{};
    for (final root in scanRoots()) {
      try {
        if (!root.dir.existsSync()) continue;
        for (final entity in root.dir.listSync()) {
          if (entity is! File || !entity.path.endsWith('.toml')) continue;
          final stat = entity.statSync();
          fingerprints[entity.path] =
              '${stat.modified.microsecondsSinceEpoch}:${stat.size}';
        }
      } catch (_) {
        // Unreadable dir — treat as empty for this root.
      }
    }

    if (_mapEquals(fingerprints, _lastFingerprint)) return;
    _lastFingerprint = fingerprints;

    // Re-parse everything in root-precedence order so an id found in
    // more than one root resolves to the earliest (highest-precedence)
    // root. (Cheap: a handful of tiny TOML files.)
    final specs = <String, Plugin>{};
    final warnings = <String>[];
    for (final root in scanRoots()) {
      try {
        if (!root.dir.existsSync()) continue;
        final files = root.dir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.toml'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
        for (final file in files) {
          final id = p.basenameWithoutExtension(file.path);
          if (specs.containsKey(id)) continue; // higher precedence won
          final spec = Plugin.parse(file, isGlobal: root.isGlobal);
          if (spec == null) {
            warnings.add(
              '${p.relative(file.path, from: projectPath).startsWith('..') ? file.path : p.relative(file.path, from: projectPath)}: '
              'invalid spec (id must match file name; label and '
              'status.path required; TOML must parse)',
            );
            continue;
          }
          specs[spec.id] = spec;
        }
      } catch (_) {
        // Unreadable dir — keep whatever parsed from earlier roots.
      }
    }
    _specs = specs;
    lastWarnings = warnings;
    notifyListeners();
  }

  static bool _mapEquals(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }
}
