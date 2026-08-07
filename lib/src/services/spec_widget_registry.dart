// Discovers spec widgets for a project.
//
// Scans `<project>/.crux/widgets/*.toml` on an interval and exposes the
// parsed specs. Because the scan is keyed on the project path, any
// session (or human) that writes a spec file into a project's
// `.crux/widgets/` directory is picked up by *every* Crux session
// opened on that project within one scan interval — the filesystem is
// the bus, and the registry is the reader.
//
// Scan is fingerprint-based (path → mtime:size): no notification when
// nothing changed, so the side panel doesn't rebuild every 2 s for no
// reason.

library;

import 'dart:async';
import 'dart:io';

import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;

import 'spec_widget.dart';

class SpecWidgetRegistry extends ChangeNotifier {
  final String projectPath;
  final Duration scanInterval;

  Timer? _timer;

  /// File-system watcher on the widgets dir so spec edits reload
  /// immediately (~200 ms debounce) instead of waiting for the next
  /// poll. The poll stays as a fallback: the watcher can't see the
  /// directory being *created* (it only watches an existing dir) and
  /// some filesystems don't deliver events reliably.
  StreamSubscription<FileSystemEvent>? _watchSub;
  Timer? _debounce;

  Map<String, String> _lastFingerprint = const {};
  Map<String, SpecWidget> _specs = const {};

  /// Warnings from the last scan (unreadable/malformed specs), for
  /// surfacing in the UI or logs. Replaced on each scan.
  List<String> lastWarnings = const [];

  SpecWidgetRegistry({
    required this.projectPath,
    this.scanInterval = const Duration(seconds: 2),
  });

  /// `<project>/.crux/widgets/` — the only directory scanned.
  Directory get widgetsDir =>
      Directory(p.join(projectPath, '.crux', 'widgets'));

  /// Parsed specs, in stable (file-name) order.
  List<SpecWidget> get widgets => _specs.values.toList();

  /// Begin periodic scanning + file watching. Idempotent.
  void start() {
    _timer ??= Timer.periodic(scanInterval, (_) => scan());
    _startWatcher();
    scan();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _watchSub?.cancel();
    _watchSub = null;
    _debounce?.cancel();
    _debounce = null;
    super.dispose();
  }

  /// Watch the widgets directory for .toml changes and re-scan
  /// (debounced) so spec edits hot-reload the sidebar row.
  void _startWatcher() {
    if (_watchSub != null) return;
    try {
      final dir = widgetsDir;
      if (!dir.existsSync()) return;
      _watchSub = dir.watch().listen((event) {
        if (event.path.endsWith('.toml')) {
          _debounce?.cancel();
          _debounce = Timer(
            const Duration(milliseconds: 200),
            scan,
          );
        }
      });
    } catch (_) {
      // Watcher unavailable — the poll fallback covers reloads.
    }
  }

  /// One scan pass: fingerprint the directory, re-parse only when
  /// something changed, notify on any spec-set change.
  void scan() {
    // The watcher only sees an *existing* directory — once the widgets
    // dir appears (or reappears), (re)start the watcher from the poll.
    _startWatcher();

    final dir = widgetsDir;
    final fingerprints = <String, String>{};
    try {
      if (dir.existsSync()) {
        for (final entity in dir.listSync()) {
          if (entity is! File || !entity.path.endsWith('.toml')) continue;
          final stat = entity.statSync();
          fingerprints[entity.path] =
              '${stat.modified.microsecondsSinceEpoch}:${stat.size}';
        }
      }
    } catch (_) {
      // Unreadable widgets dir — treat as empty, keep old specs.
    }

    if (_mapEquals(fingerprints, _lastFingerprint)) return;
    _lastFingerprint = fingerprints;

    // Re-parse everything (cheap: a handful of tiny TOML files).
    final specs = <String, SpecWidget>{};
    final warnings = <String>[];
    for (final path in fingerprints.keys) {
      final spec = SpecWidget.parse(File(path));
      if (spec == null) {
        warnings.add(
          '${p.basename(path)}: invalid spec (id must match file name; '
          'label and status.path required; TOML must parse)',
        );
        continue;
      }
      specs[spec.id] = spec;
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
