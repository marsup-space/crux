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

/// A plan doc the `/plan` autocomplete may offer, with the recency
/// signal used for ordering.
class KnownPlan {
  const KnownPlan({required this.name, this.lastUsedAt});

  /// Plan doc name with the `.md` suffix, e.g. `test run.md`.
  final String name;

  /// Most recent mtime across this plan's version-log directories
  /// ([PlanDocStore] writes at least `index.json` on every enter and
  /// edit). Null when the plan qualified via the name heuristic only
  /// (never entered on this machine).
  final DateTime? lastUsedAt;
}

/// Whether [baseName] (a `.md` file name) carries "plan" in it,
/// case-insensitive. Covers `PLAN.md`, `refactor-plan.md`,
/// `PlanNorge.md` (alnum-joined) — not `main.md`, `README.md`.
bool isPlanNameHeuristic(String baseName) =>
    baseName.toLowerCase().contains('plan');

/// Plan names known to this machine: every `<planName>` directory
/// under `<projectPath>/.crux/plans/<sessionId>/`.
///
/// A plan gets a version-log directory the first time it is entered
/// ([PlanDocStore] appends the init snapshot), so this is the
/// "has actually been used in plan mode on this machine" set. The
/// result is keyed by name — multiple sessions entering the same
/// plan collapse to the newest mtime — and ordered oldest-first
/// (empty when the project has no plan history at all).
Map<String, DateTime?> listKnownPlanNames(String projectPath) {
  final known = <String, DateTime?>{};
  final plansRoot = Directory(p.join(projectPath, '.crux', 'plans'));
  if (!plansRoot.existsSync()) return known;
  for (final sessionDir in plansRoot.listSync(followLinks: false)) {
    if (sessionDir is! Directory) continue;
    for (final planDir in sessionDir.listSync(followLinks: false)) {
      if (planDir is! Directory) continue;
      final name = p.basename(planDir.path);
      if (name.isEmpty) continue;
      final existing = known[name];
      // Null (heuristic-only) never overwrites a real timestamp, and a
      // newer timestamp wins over both.
      if (existing != null && existing.isAfter(_planDirMtime(planDir))) {
        continue;
      }
      known[name] = _planDirMtime(planDir);
    }
  }
  return known;
}

DateTime _planDirMtime(Directory planDir) {
  final index = File(p.join(planDir.path, 'index.json'));
  if (index.existsSync()) return index.lastModifiedSync();
  try {
    return planDir.statSync().modified;
  } catch (_) {
    return DateTime.fromMillisecondsSinceEpoch(0);
  }
}
