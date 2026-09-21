import 'package:drift/drift.dart';
import 'package:sqlite3/sqlite3.dart' show SqliteException;

import '../models/subagent.dart';
import '../utils/worker_constellations.dart';
import 'database.dart' as db;

/// Data-access layer for the `agents` roster table — the persistent
/// subagent identities of the v2 execution model.
///
/// Identity is durable, execution is transient: this store owns only the
/// *who* (name / role / domain / model binding) and the distilled memory
/// (knowledge / worklog). Runs live in memory inside the process that
/// started them and never touch this table beyond flipping `status` and
/// `run_owner_session_id`.
///
/// Rosters are workspace-scoped (v37): every method takes a
/// [projectPath] scope and filters on it, so each workspace sees only
/// its own agents, and constellation names are allocated within the
/// scope — the same id (`orion`) can exist in different workspaces.
/// Callers pass the workspace root (the session's `projectPath`, which
/// for workspace sessions is `Directory.current.path`).
///
/// A single instance is shared app-wide (same lifetime as the database
/// connection — see [SessionStore.agentStore]).
class AgentStore {
  final db.CruxDatabase _db;

  AgentStore(this._db);

  /// All roster rows in [projectPath], ordered by recency of activity.
  Future<List<db.Agent>> listAll(String projectPath) {
    final query = _db.select(_db.agents)
      ..where((a) => a.projectPath.equals(projectPath))
      ..orderBy([(a) => OrderingTerm.desc(a.lastActiveAt)]);
    return query.get();
  }

  /// All roster rows for one role, within [projectPath].
  Future<List<db.Agent>> listByRole(String projectPath, SubagentRole role) {
    final query = _db.select(_db.agents)
      ..where((a) => a.projectPath.equals(projectPath))
      ..where((a) => a.role.equals(role.name))
      ..orderBy([(a) => OrderingTerm.desc(a.lastActiveAt)]);
    return query.get();
  }

  /// Look up one agent by its persisted constellation id (`orion`)
  /// within [projectPath]. The composite key is (projectPath, name),
  /// so a name alone is ambiguous across workspaces.
  Future<db.Agent?> byName(String projectPath, String name) {
    final query = _db.select(_db.agents)
      ..where((a) => a.projectPath.equals(projectPath))
      ..where((a) => a.name.equals(name.trim().toLowerCase()));
    return query.getSingleOrNull();
  }

  /// Allocate the next free constellation name for [role] within
  /// [projectPath], skipping ids already taken in that workspace.
  /// When the pool cycles, appends a numeric suffix (`orion-2`,
  /// `orion-3`, …) deterministic over the existing rows, so two
  /// processes allocating in the same table converge on the same
  /// candidate set (the unique constraint is the final arbiter).
  Future<String> allocateName(String projectPath, SubagentRole role) async {
    final pool = role == SubagentRole.worker
        ? kWorkerConstellations
        : kExpertConstellations;
    final taken = {for (final row in await listAll(projectPath)) row.name};
    // Unsuffixed ids first, in pool order.
    for (final constellation in pool) {
      if (!taken.contains(constellation.id)) return constellation.id;
    }
    // Pool exhausted: cycle with `-2`, -`3`, … per base id, in pool order.
    for (var cycle = 2; ; cycle++) {
      for (final constellation in pool) {
        final candidate = '${constellation.id}-$cycle';
        if (!taken.contains(candidate)) return candidate;
      }
      // Unreachable in practice: the suffix space is unbounded, so the
      // loop always finds a free name unless `taken` is infinite.
      if (cycle > 10000) throw StateError('constellation name space exhausted');
    }
  }

  /// Create a new agent row with an auto-allocated constellation name.
  ///
  /// The model binding is permanent for the agent's lifetime (see the
  /// table docs): callers must have already resolved the model through
  /// the pool + concurrency + budget rules.
  ///
  /// `allocateName` reads the table then inserts — a check-then-act
  /// window. Two hires racing in the same process (the chat executor
  /// runs one round's tool calls in parallel via `Future.wait`) or in
  /// two processes can pick the same name; the loser's INSERT fails
  /// on the UNIQUE constraint. That failure is the *arbiter* the
  /// `allocateName` docs promise: catch it, re-read the table (the
  /// winner's row is now committed), and retry with the next free
  /// name. Bounded so a pathological table can't loop forever.
  Future<db.Agent> hire({
    required String projectPath,
    required SubagentRole role,
    required String model,
    String domain = 'general',
    int? createdBySessionId,
  }) async {
    const maxAttempts = 8;
    Object? lastError;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final name = await allocateName(projectPath, role);
      final now = DateTime.now().millisecondsSinceEpoch;
      try {
        await _db
            .into(_db.agents)
            .insert(
              db.AgentsCompanion.insert(
                projectPath: Value(projectPath),
                name: name,
                role: role.name,
                model: model,
                domain: Value(domain),
                createdBySessionId: Value(createdBySessionId),
                // Hiring *is* a use: seed the "last used by" stamp so
                // the chat agent bar shows the chip from the first
                // moment.
                lastUsedBySessionId: Value(createdBySessionId),
                createdAt: now,
                lastActiveAt: now,
              ),
            );
        return (await byName(projectPath, name))!;
      } on SqliteException catch (e) {
        // 2067 = SQLITE_CONSTRAINT_UNIQUE; 1555 =
        // SQLITE_CONSTRAINT_PRIMARYKEY — the (project_path, name)
        // composite key (v37). Either means the name was just taken by
        // a racing hire; only name collisions are retryable here,
        // anything else (NOT NULL, FK, disk I/O) must surface.
        if (e.extendedResultCode != 2067 && e.extendedResultCode != 1555) {
          rethrow;
        }
        lastError = e;
        // Small cooperative yield so a same-process racer commits its
        // winning row before we re-read the table.
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    throw StateError(
      'agent name allocation lost the uniqueness race $maxAttempts times: '
      '$lastError',
    );
  }

  /// Delete one roster row by name within [projectPath]. The caller
  /// (config fullpane / manager) is responsible for refusing deletes
  /// of busy agents — this store layer only removes the identity and
  /// its distilled memory.
  Future<void> deleteByName(String projectPath, String name) async {
    await (_db.delete(_db.agents)
          ..where((a) => a.projectPath.equals(projectPath))
          ..where((a) => a.name.equals(name.trim().toLowerCase())))
        .go();
  }

  /// Mark [name] busy under [sessionId] and record the dispatched
  /// intention. Also stamps `lastUsedBySessionId` — a dispatch counts as
  /// a use, regardless of who hired the agent. No-op when the agent does
  /// not exist.
  Future<void> markBusy(
    String projectPath,
    String name, {
    required int sessionId,
    required String intention,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await (_db.update(_db.agents)
          ..where((a) => a.projectPath.equals(projectPath))
          ..where((a) => a.name.equals(name)))
        .write(
          db.AgentsCompanion(
            status: Value('busy'),
            lastIntention: Value(intention),
            runOwnerSessionId: Value(sessionId),
            lastUsedBySessionId: Value(sessionId),
            lastActiveAt: Value(now),
          ),
        );
  }

  /// Mark [name] ready again. Clears the run owner and stamps activity,
  /// but deliberately keeps `lastUsedBySessionId` (the bar needs it to
  /// still show the chip once the run ends).
  Future<void> markReady(String projectPath, String name) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await (_db.update(_db.agents)
          ..where((a) => a.projectPath.equals(projectPath))
          ..where((a) => a.name.equals(name)))
        .write(
          db.AgentsCompanion(
            status: Value('ready'),
            runOwnerSessionId: Value(null),
            lastActiveAt: Value(now),
          ),
        );
  }

  /// Overwrite the distilled memory fields (the distillation pipeline's
  /// write path) and stamp activity.
  Future<void> writeDistilled({
    required String projectPath,
    required String name,
    required String knowledge,
    required String worklog,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await (_db.update(_db.agents)
          ..where((a) => a.projectPath.equals(projectPath))
          ..where((a) => a.name.equals(name)))
        .write(
          db.AgentsCompanion(
            knowledge: Value(knowledge),
            worklog: Value(worklog),
            lastActiveAt: Value(now),
          ),
        );
  }

  /// Overwrite the agent's reasoning effort override (null = back to
  /// the provider's server default). Read at each dispatch; no-op
  /// when the agent does not exist.
  Future<void> setReasoningEffort(
    String projectPath,
    String name,
    String? effort,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await (_db.update(_db.agents)
          ..where((a) => a.projectPath.equals(projectPath))
          ..where((a) => a.name.equals(name)))
        .write(
          db.AgentsCompanion(
            reasoningEffort: Value(effort),
            lastActiveAt: Value(now),
          ),
        );
  }

  /// Reset every `busy` row to `ready` — the restart self-healing path.
  /// Called once at startup: no run survived the process, so no agent
  /// can still be busy. The `lastIntention` stays (it feeds the
  /// "previous task" tooltip line), only the liveness flags clear.
  /// Not project-scoped: a busy row is busy regardless of workspace,
  /// and no run survived THIS process.
  Future<void> resetAllToReady() async {
    await (_db.update(_db.agents)..where((a) => a.status.equals('busy'))).write(
      db.AgentsCompanion(
        status: Value('ready'),
        runOwnerSessionId: Value(null),
      ),
    );
  }
}
