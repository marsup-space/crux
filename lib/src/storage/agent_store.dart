import 'package:drift/drift.dart';

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
/// A single instance is shared app-wide (same lifetime as the database
/// connection — see [SessionStore.agentStore]).
class AgentStore {
  final db.CruxDatabase _db;

  AgentStore(this._db);

  /// All roster rows, ordered by recency of activity.
  Future<List<db.Agent>> listAll() {
    final query = _db.select(_db.agents)
      ..orderBy([(a) => OrderingTerm.desc(a.lastActiveAt)]);
    return query.get();
  }

  /// All roster rows for one role.
  Future<List<db.Agent>> listByRole(SubagentRole role) {
    final query = _db.select(_db.agents)
      ..where((a) => a.role.equals(role.name))
      ..orderBy([(a) => OrderingTerm.desc(a.lastActiveAt)]);
    return query.get();
  }

  /// Look up one agent by its persisted constellation id (`orion`).
  Future<db.Agent?> byName(String name) {
    final query = _db.select(_db.agents)
      ..where((a) => a.name.equals(name.trim().toLowerCase()));
    return query.getSingleOrNull();
  }

  /// Allocate the next free constellation name for [role], skipping ids
  /// already present in the table. When the pool cycles, appends a
  /// numeric suffix (`orion-2`, `orion-3`, …) deterministic over the
  /// existing rows, so two processes allocating in the same table
  /// converge on the same candidate set (the unique constraint is the
  /// final arbiter).
  Future<String> allocateName(SubagentRole role) async {
    final pool = role == SubagentRole.worker
        ? kWorkerConstellations
        : kExpertConstellations;
    final taken = {
      for (final row in await _db.select(_db.agents).get()) row.name,
    };
    // Unsuffixed ids first, in pool order.
    for (final constellation in pool) {
      if (!taken.contains(constellation.id)) return constellation.id;
    }
    // Pool exhausted: cycle with `-2`, -`3`, … per base id, in pool order.
    for (var cycle = 2;; cycle++) {
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
  Future<db.Agent> hire({
    required SubagentRole role,
    required String model,
    String domain = 'general',
  }) async {
    final name = await allocateName(role);
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.into(_db.agents).insert(
      db.AgentsCompanion.insert(
        name: name,
        role: role.name,
        model: model,
        domain: Value(domain),
        createdAt: now,
        lastActiveAt: now,
      ),
    );
    return (await byName(name))!;
  }

  /// Delete one roster row by name. The caller (config fullpane /
  /// manager) is responsible for refusing deletes of busy agents —
  /// this store layer only removes the identity and its distilled
  /// memory.
  Future<void> deleteByName(String name) async {
    await (_db.delete(_db.agents)
          ..where((a) => a.name.equals(name.trim().toLowerCase())))
        .go();
  }

  /// Mark [name] busy under [sessionId] and record the dispatched
  /// intention. No-op when the agent does not exist.
  Future<void> markBusy(
    String name, {
    required int sessionId,
    required String intention,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await (_db.update(_db.agents)
          ..where((a) => a.name.equals(name)))
        .write(
      db.AgentsCompanion(
        status: Value('busy'),
        lastIntention: Value(intention),
        runOwnerSessionId: Value(sessionId),
        lastActiveAt: Value(now),
      ),
    );
  }

  /// Mark [name] ready again. Clears the run owner and stamps activity.
  Future<void> markReady(String name) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await (_db.update(_db.agents)
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
    required String name,
    required String knowledge,
    required String worklog,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await (_db.update(_db.agents)
          ..where((a) => a.name.equals(name)))
        .write(
      db.AgentsCompanion(
        knowledge: Value(knowledge),
        worklog: Value(worklog),
        lastActiveAt: Value(now),
      ),
    );
  }

  /// Reset every `busy` row to `ready` — the restart self-healing path.
  /// Called once at startup: no run survived the process, so no agent
  /// can still be busy. The `lastIntention` stays (it feeds the
  /// "previous task" tooltip line), only the liveness flags clear.
  Future<void> resetAllToReady() async {
    await (_db.update(_db.agents)
          ..where((a) => a.status.equals('busy')))
        .write(
      db.AgentsCompanion(
        status: Value('ready'),
        runOwnerSessionId: Value(null),
      ),
    );
  }
}
