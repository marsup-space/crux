import 'dart:ffi';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart';

import '../models/session.dart';
import '../utils/user_data_directory.dart';
import 'tables.dart';

part 'database.g.dart';

@DriftDatabase(
  tables: [Sessions, Messages, Parts, FileReadState, FileLastWriter,
      ShellMonitorLogs],
)
class CruxDatabase extends _$CruxDatabase {
  CruxDatabase() : super(_openConnection());

  /// In-memory constructor for tests. Lets each test get a fresh,
  /// isolated database without touching the user's on-disk data
  /// dir, which is shared with other test files and would
  /// otherwise race on parallel test runs (`database is locked`).
  CruxDatabase.forTesting(super.executor);

  /// Schema history:
  ///
  ///   v1  – initial (sessions, messages)
  ///   v2  – messages.reasoningContent
  ///   v3  – messages.reasoningTokens, messages.thinkingDurationMs
  ///   v4  – sessions.thinkingMode, sessions.reasoningEffort
  ///   v5  – messages.reasoningEffort
  ///   v6  – fileReadState table
  ///   v7  – messages.toolCalls, messages.toolCallId
  ///   v8  – messages.tldr
  ///   v9  – sessions.ttftMs, sessions.tokPerSec, sessions.promptCacheHitTokens
  ///   v10 – offloaded_content table (later removed — see v22)
  ///   v11 – messages.preCompressTokens (later removed — see v22)
  ///   v12 – messages.reasoningSignature
  ///   v13 – fileReadState altered (session_id added to PK)
  ///   v14 – offloaded_content.intent (later removed — see v22)
  ///   v15 – messages.images
  ///   v16 – no structural changes (offloading was being phased out)
  ///   v17 – messages.parallelCount, used by `parallel_praise` rows
  ///         to carry the number of successful tool calls in the
  ///         round (drives the user-facing "N tool calls parallelized"
  ///         bubble in the chat history).
  ///   v18 – sessions.runningOwnerId and runningHeartbeatAt, used to
  ///         distinguish stale `running` rows from live runs owned by
  ///         another Crux process in the same project.
  ///   v19 – sessions.systemPrompt: the rendered system prompt
  ///         (a single joined text ready to send as one
  ///         `role: 'system'` message), computed once at session
  ///         start and re-attached verbatim on every subsequent
  ///         turn. See `docs/design-system-prompt.md`.
  ///   v20 – messages.meta: free-form JSON for inline UI metadata
  ///         attached to tool results (e.g. `{"routing":"system-proxy"}`
  ///         on a `webfetch` that fell back to the system proxy).
  ///         Read by the chat-history bubble renderer; never sent
  ///         to the LLM.
  ///   v21 – dropped `sessions.cost` and `messages.cost`. Cost tracking
  ///         was a half-built feature with a hardcoded rate table for
  ///         5 model IDs that mostly returned 0.0 for real-world
  ///         usage, and was never wired into any user-facing UI.
  ///         Existing rows lose whatever value they had at the time
  ///         of the migration; new rows have no `cost` column at all.
  ///   v22 – dropped the orphaned `offloaded_content` table and
  ///         `messages.pre_compress_tokens` column. Both were dead
  ///         schema from the removed tool-argument offloading
  ///         feature; this migration cleans them up on existing
  ///         installs. Fresh installs never created them.
  ///   v23 – added indexes on `messages.session_id` and
  ///         `sessions.project_path`. Without these indexes,
  ///         every per-session message query (`WHERE session_id =
  ///         ? ORDER BY id DESC LIMIT N`) and every sidebar list
  ///         query (`WHERE project_path = ?`) was a full table
  ///         scan. For users with many sessions or large sessions,
  ///         this dominated cold-cache load time — a 6–7s "loading
  ///         messages…" flash that the indexes eliminate. The CREATE
  ///         INDEX itself scans the table once, so first-time
  ///         upgrades to v23 take a few seconds longer; subsequent
  ///         launches benefit.
  ///   v24 – upgraded `idx_messages_session_id` to the composite
  ///         `idx_messages_session_id_id` on `(session_id, id DESC)`.
  ///         The leading column still serves the `WHERE session_id
  ///         = ?` lookup; the `id DESC` ordering lets SQLite skip
  ///         the in-memory `ORDER BY id DESC` sort the chunked
  ///         loader does (rows come back already in newest-first
  ///         order). Cheap win — saves a sort per chunk — and
  ///         also drops the now-redundant single-column index.
  ///   v25 – added composite index on `(project_path, archived_at)`
  ///         so the auto-archive / archived-count queries stay
  ///         O(log n).
  ///   v26 – added `sessions.temperature_override` for the
  ///         `/temperature` slash command. Nullable REAL clamped
  ///         to `[0.0, 1.0]` at write time; `null` means "use the
  ///         model's TOML `temperature` default". See
  ///         `lib/src/commands/cmd_temperature.dart`.
  ///   v27 – added `file_last_writer` table, one row per path,
  ///         tracking the session id and intent string of the last
  ///         edit/write that touched each file. The read-before-write
  ///         guard looks this up when mtime drift is detected and
  ///         the writer is a different session, so the guard's
  ///         response can name the writer and its intent. See
  ///         `docs/design-tools.md` and `file_read_tracker.dart`.
  ///   v28 – added `shell_monitor_logs` table, one row per shell
  ///         monitor event (run-start, per-check verdict, evaluator
  ///         error, timeout fallback, run-finish). The monitor loop
  ///         emits events via `ShellMonitorLogSink`; the sink in
  ///         `shell_monitor_log_store.dart` batches them per run and
  ///         flushes on run end, so a burst of checks is a single
  ///         DB write. `/d-monitor` reads this to verify the aux
  ///         monitor is judging correctly. No FK from `run_id` back
  ///         to anything — runs have no row of their own.
  @override
  int get schemaVersion => 28;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator m) async {
      await m.createAll();
      // Indexes on the two FK columns we filter on heavily. The
      // composite `(session_id, id DESC)` index serves two roles:
      // the leading column covers the `WHERE session_id = ?`
      // lookup, and the `id DESC` ordering lets SQLite skip the
      // in-memory `ORDER BY id DESC` sort that the chunked loader
      // does (rows come back already in newest-first order). The
      // single-column `project_path` index covers the sidebar
      // session-list query.
      //
      // Without these, every chat-panel switch does a full table
      // scan of `messages` (across every session the user has ever
      // opened) and the sidebar list does the same on `sessions`.
      // For users with many sessions or large sessions, that scan
      // dominates cold-cache startup time — 6–7 seconds of
      // "loading messages…" before the first chunk lands. See the
      // v23 schema-history note for the user-visible symptom.
      await m.database.customStatement(
        'CREATE INDEX idx_messages_session_id_id '
        'ON messages(session_id, id DESC)',
      );
      await m.database.customStatement(
        'CREATE INDEX idx_sessions_project_path ON sessions(project_path)',
      );
      // Composite index for the auto-archive and archived-count queries.
      // The leading `project_path` column serves the per-project filter;
      // `archivedAt` as the second column lets SQLite seek directly to
      // un-archived rows (or archived rows for the count) without a
      // full table scan. Without this, autoArchive loads every row into
      // Dart and archivedCount materializes up to 1000 rows just to count.
      await m.database.customStatement(
        'CREATE INDEX idx_sessions_project_archived '
        'ON sessions(project_path, archived_at)',
      );
      // Index for /d-monitor's "recent runs for this session" query.
      // Same shape as the upgrade branch in onUpgrade below.
      await m.database.customStatement(
        'CREATE INDEX idx_shell_monitor_logs_session_run '
        'ON shell_monitor_logs(session_id, run_id, id)',
      );
    },
    onUpgrade: (Migrator m, int from, int to) async {
      if (from < 2) {
        await m.addColumn(messages, messages.reasoningContent);
      }
      if (from < 3) {
        await m.addColumn(messages, messages.reasoningTokens);
        await m.addColumn(messages, messages.thinkingDurationMs);
      }
      if (from < 4) {
        await m.addColumn(sessions, sessions.thinkingMode);
        await m.addColumn(sessions, sessions.reasoningEffort);
      }
      if (from < 5) {
        await m.addColumn(messages, messages.reasoningEffort);
      }
      if (from < 6) {
        await m.createTable(fileReadState);
      }
      if (from < 7) {
        await m.addColumn(messages, messages.toolCalls);
        await m.addColumn(messages, messages.toolCallId);
      }
      if (from < 8) {
        await m.addColumn(messages, messages.tldr);
      }
      if (from < 9) {
        await m.addColumn(sessions, sessions.ttftMs);
        await m.addColumn(sessions, sessions.tokPerSec);
        await m.addColumn(sessions, sessions.promptCacheHitTokens);
      }
      if (from < 10) {
        // v10 originally created the offloaded_content table via
        // `m.createTable(offloadedContent)`. The Drift class is
        // gone from the current schema (the offloading feature was
        // removed in v22), so this migration issues the same DDL
        // as raw SQL. Users upgrading from v9 → v22 still need the
        // table to exist transiently so the v22 DROP can find it.
        await m.database.customStatement('''
CREATE TABLE offloaded_content (
  session_id INTEGER NOT NULL REFERENCES sessions (id) ON DELETE CASCADE,
  call_id TEXT NOT NULL,
  tool_name TEXT NOT NULL,
  byte_size INTEGER NOT NULL,
  line_count INTEGER NOT NULL,
  content TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (session_id, call_id)
)
''');
      }
      if (from < 11) {
        // v11 originally ran `m.addColumn(messages, messages.preCompressTokens)`.
        // The column is gone from the current schema (see v22), so
        // emit the ALTER directly. The column is nullable and has
        // no default — drift's `integer().nullable()` matches that.
        await m.database.customStatement(
          'ALTER TABLE messages ADD COLUMN pre_compress_tokens INTEGER',
        );
      }
      if (from < 12) {
        await m.addColumn(messages, messages.reasoningSignature);
      }
      if (from < 13) {
        // TableMigration is experimental in drift; the migration path
        // requires it, so suppress here rather than rewriting the schema.
        // ignore: experimental_member_use
        await m.alterTable(TableMigration(fileReadState));
      }
      if (from < 14) {
        // v14 originally ran `m.addColumn(offloadedContent, offloadedContent.intent)`.
        // The OffloadedContent class is gone, so issue the ALTER
        // directly. The column was added with a default of '' to
        // match `text().withDefault(const Constant(''))`.
        await m.database.customStatement(
          "ALTER TABLE offloaded_content ADD COLUMN intent TEXT NOT NULL DEFAULT ''",
        );
      }
      if (from < 15) {
        await m.addColumn(messages, messages.images);
      }
      // v15 → v16: no structural changes. offloaded_content and
      // pre_compress_tokens are dead schema — they remain on disk
      // so drift's validation passes but are never read/written.
      if (from < 17) {
        await m.addColumn(messages, messages.parallelCount);
      }
      if (from < 18) {
        await m.addColumn(sessions, sessions.runningOwnerId);
        await m.addColumn(sessions, sessions.runningHeartbeatAt);
      }
      if (from < 19) {
        await m.addColumn(sessions, sessions.systemPrompt);
      }
      if (from < 20) {
        await m.addColumn(messages, messages.meta);
      }
      if (from < 21) {
        // Drop the orphaned `cost` columns from both tables. SQLite
        // 3.35.0+ supports `ALTER TABLE ... DROP COLUMN` natively,
        // and every supported platform (macOS, modern Linux distros,
        // Windows 10/11) ships a version at or above that. If a
        // user somehow hits an older SQLite, the migration will
        // throw and the app will refuse to start — same failure
        // mode as any other migration error.
        await m.database.customStatement(
          'ALTER TABLE sessions DROP COLUMN cost',
        );
        await m.database.customStatement(
          'ALTER TABLE messages DROP COLUMN cost',
        );
      }
      if (from < 22) {
        // Drop the orphaned offloading schema. `offloaded_content`
        // is a top-level table (no FKs to maintain on the way down),
        // `pre_compress_tokens` is a leaf column on `messages` with
        // no dependents. Both were declared by drift v10/v11 and
        // were intentionally left on disk by the v16 "dead schema"
        // note; v22 is the cleanup. Fresh installs skip the DROP
        // because the table/column never existed in the first
        // place — the IF EXISTS guards make both statements
        // no-ops in that case.
        await m.database.customStatement(
          'DROP TABLE IF EXISTS offloaded_content',
        );
        await m.database.customStatement(
          'ALTER TABLE messages DROP COLUMN pre_compress_tokens',
        );
      }
      if (from < 23) {
        // Add indexes on the two FK columns we filter on. CREATE
        // INDEX IF NOT EXISTS so this is a no-op on installs that
        // already have them (e.g. a fresh install at v23 went
        // through onCreate, which ran the same statements). The
        // first run on an existing install scans the table once to
        // build the index — for a multi-session DB this is the
        // expected one-time cost, and the immediate payoff is
        // every per-session chat-panel switch going from full
        // table scan to indexed lookup.
        await m.database.customStatement(
          'CREATE INDEX IF NOT EXISTS idx_messages_session_id '
          'ON messages(session_id)',
        );
        await m.database.customStatement(
          'CREATE INDEX IF NOT EXISTS idx_sessions_project_path '
          'ON sessions(project_path)',
        );
      }
      if (from < 24) {
        // Upgrade the single-column messages index to the composite
        // `(session_id, id DESC)`. The leading column still serves
        // the `WHERE session_id = ?` lookup, so the query plan is
        // the same; the `id DESC` ordering additionally lets SQLite
        // skip the in-memory `ORDER BY id DESC` sort the chunked
        // loader does (rows come back already in newest-first
        // order). The single-column index is now redundant — a
        // composite index's leading prefix covers the same lookup
        // — so drop it to save disk space and per-write update cost.
        // `IF EXISTS` keeps this a no-op on fresh installs (which
        // never created the single-column one) and on installs
        // that already upgraded past v24.
        await m.database.customStatement(
          'CREATE INDEX IF NOT EXISTS idx_messages_session_id_id '
          'ON messages(session_id, id DESC)',
        );
        await m.database.customStatement(
          'DROP INDEX IF EXISTS idx_messages_session_id',
        );
      }
      if (from < 25) {
        // Add composite index on (project_path, archived_at) so the
        // auto-archive and archived-count queries stay O(log n) as
        // the sessions table grows. `IF EXISTS` keeps this a no-op
        // on fresh installs (which went through onCreate).
        await m.database.customStatement(
          'CREATE INDEX IF NOT EXISTS idx_sessions_project_archived '
          'ON sessions(project_path, archived_at)',
        );
      }
      if (from < 26) {
        // Add `sessions.temperature_override` so the `/temperature`
        // slash command can persist a per-session override that
        // wins over the model's TOML-configured `temperature`
        // default. Nullable REAL: `null` means "no override,
        // fall back to model default". No index — this is read
        // alongside the full session row, never queried in
        // isolation.
        //
        // Idempotent: SQLite ALTER TABLE ADD COLUMN fails with
        // "duplicate column name" if the column already exists,
        // so guard the ALTER on a PRAGMA check. This protects
        // users whose DB was created (or partially migrated)
        // with the column already present but user_version not
        // yet bumped past 25 — e.g. a previous run that crashed
        // between addColumn and drift's user_version write, or
        // a regenerated database.g.dart whose CREATE TABLE
        // already declares the column for fresh installs while
        // v25 user_version lingers. Without this guard the
        // startup fails with `SqliteException(1): duplicate
        // column name: temperature_override` and the app can't
        // open its database at all.
        final hasTemperatureOverride = await m.database
            .customSelect(
              "SELECT 1 FROM pragma_table_info('sessions') "
              "WHERE name = 'temperature_override' LIMIT 1",
            )
            .get();
        if (hasTemperatureOverride.isEmpty) {
          await m.addColumn(sessions, sessions.temperatureOverride);
        }
      }
      if (from < 27) {
        // Add `file_last_writer` for cross-session write attribution.
        // The read-before-write guard reads this on mtime drift to
        // name the session + intent that produced the file's current
        // content, so the agent can `session show` the writer before
        // retrying. `path` is the PK (one row per file), and the
        // FK to sessions cascades on session delete — losing the
        // attribution row is fine, the file just falls back to the
        // unattributed drift message.
        //
        // CREATE TABLE IF NOT EXISTS is unnecessary here: drift's
        // createTable on a fresh install (onCreate) already covers
        // it, and the only path leading into this branch is an
        // upgrade from v26 or earlier where the table didn't exist.
        // Plain createTable is enough.
        await m.createTable(fileLastWriter);
      }
      if (from < 28) {
        // Add `shell_monitor_logs` (one row per monitor event; see
        // the v28 schema-history note above). Fresh installs create
        // it in onCreate; this branch only runs on upgrades from
        // v27 or earlier where the table didn't exist yet.
        await m.createTable(shellMonitorLogs);
        // Index on (session_id, run_id, id) so `/d-monitor` can list
        // the most recent runs for the current session (or across
        // sessions) without scanning the whole table. The leading
        // session_id serves the per-session filter; run_id groups
        // one run's events; id orders events inside a run.
        await m.database.customStatement(
          'CREATE INDEX idx_shell_monitor_logs_session_run '
          'ON shell_monitor_logs(session_id, run_id, id)',
        );
      }
    },
  );
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dbDir = _getDatabaseDirectory();
    await Directory(dbDir).create(recursive: true);
    final file = File(p.join(dbDir, 'crux.db'));

    open.overrideFor(OperatingSystem.linux, _openLinuxSqlite);

    return NativeDatabase.createInBackground(
      file,
      setup: (db) {
        db.execute('PRAGMA journal_mode=WAL;');
        db.execute('PRAGMA busy_timeout=5000;');
        // Foreign-key enforcement is a per-connection setting — SQLite
        // never persists it in the DB file, so it must be re-applied
        // every time a connection opens. Drift guarantees that: it
        // invokes this [setup] callback from its connection-init path
        // on every open of the underlying sqlite3 connection (the
        // single background-isolate connection `createInBackground`
        // uses, readPool defaulting to 0), so every production
        // connection ends up with enforcement on.
        //
        // Without it, the `onDelete: KeyAction.cascade` foreign keys
        // declared in tables.dart are parsed but never enforced, and
        // any delete that relies on a cascade silently leaves orphan
        // rows behind.
        db.execute('PRAGMA foreign_keys=ON;');
      },
    );
  });
}

String _getDatabaseDirectory() {
  return resolveUserDataDirectory();
}

DynamicLibrary _openLinuxSqlite() {
  final candidates = [
    '/usr/lib/x86_64-linux-gnu/libsqlite3.so.0',
    '/usr/lib/libsqlite3.so.0',
    '/usr/lib64/libsqlite3.so.0',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) return DynamicLibrary.open(path);
  }
  return DynamicLibrary.open('libsqlite3.so.0');
}
