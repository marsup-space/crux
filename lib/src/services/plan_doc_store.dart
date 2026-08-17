import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/plan_selection.dart';

/// Append-only snapshot log for one plan document within one session.
///
/// Layout on disk:
///
///   <projectPath>/.crux/plans/<sessionId>/<planName>/
///     v1.md
///     v2.md
///     …
///     index.json   ← [{version, at, kind, revertedTo?}, …]
///
/// Invariants (design doc §5 P5):
///   - **HEAD == the file on disk, always.** Every accepted agent
///     edit/write to the plan doc is snapshotted as the next version
///     (`kind: edit`).
///   - Revert creates a NEW version whose content equals the target
///     (`kind: revert, revertedTo: N`) — history stays linear and
///     auditable; nothing is ever rewound or deleted.
///   - Viewing an old version is pure UI: no snapshot, no mutation.
///
/// The store is a dumb persistence layer: it never parses markdown and
/// never talks to the UI. The [PlanModeController] drives it.
class PlanDocStore {
  final String projectPath;
  final int sessionId;
  final String planName;

  PlanDocStore({
    required this.projectPath,
    required this.sessionId,
    required this.planName,
  });

  Directory get _dir => Directory(
        p.join(projectPath, '.crux', 'plans', '$sessionId', planName),
      );

  File get _indexFile => File(p.join(_dir.path, 'index.json'));

  File _versionFile(int version) => File(p.join(_dir.path, 'v$version.md'));

  /// The current index entries, oldest first. Empty when nothing has
  /// been snapshotted yet.
  List<PlanVersionEntry> readIndex() {
    final file = _indexFile;
    if (!file.existsSync()) return const [];
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! List) return const [];
      return [
        for (final e in decoded)
          if (e is Map<String, dynamic>) PlanVersionEntry.fromJson(e),
      ];
    } catch (_) {
      // A corrupt index is treated as empty rather than fatal — the
      // versioned files are still on disk and the next append rewrites
      // the index wholesale.
      return const [];
    }
  }

  /// Highest version number in the log (0 = nothing snapshotted yet).
  int get headVersion {
    final index = readIndex();
    if (index.isEmpty) return 0;
    return index.map((e) => e.version).reduce((a, b) => a > b ? a : b);
  }

  /// Read the content of version [version], or null when it doesn't
  /// exist.
  String? readVersion(int version) {
    final file = _versionFile(version);
    if (!file.existsSync()) return null;
    return file.readAsStringSync();
  }

  /// Append [content] as the next version. Returns the new version
  /// number. The write is atomic-ish (index rewritten last) so a crash
  /// mid-append leaves at worst an orphaned `vN.md` the next append
  /// overwrites.
  int append(
    String content, {
    PlanVersionKind kind = PlanVersionKind.edit,
    int? revertedTo,
    DateTime? at,
  }) {
    final index = List<PlanVersionEntry>.from(readIndex());
    final version =
        index.isEmpty ? 1 : index.map((e) => e.version).reduce((a, b) => a > b ? a : b) + 1;
    _dir.createSync(recursive: true);
    _versionFile(version).writeAsStringSync(content);
    index.add(PlanVersionEntry(
      version: version,
      at: at ?? DateTime.now(),
      kind: kind,
      revertedTo: revertedTo,
    ));
    _indexFile.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert([for (final e in index) e.toJson()]),
    );
    return version;
  }

  /// Initialize the log from the current on-disk content if it is empty.
  /// Returns the head version after the call.
  int ensureInitialized(String currentDiskContent) {
    if (headVersion == 0) {
      append(currentDiskContent, kind: PlanVersionKind.init);
    }
    return headVersion;
  }
}
