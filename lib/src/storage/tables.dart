import 'package:drift/drift.dart';

import '../models/session.dart';

class Sessions extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get slug => text().withDefault(const Constant(''))();
  TextColumn get title => text().withDefault(const Constant(''))();
  TextColumn get model => text().withDefault(const Constant(''))();
  TextColumn get status => textEnum<SessionStatus>()();
  TextColumn get agent => text().withDefault(const Constant(''))();
  IntColumn get parentId => integer().nullable()();
  TextColumn get projectPath => text().withDefault(const Constant(''))();
  IntColumn get tokensIn => integer().withDefault(const Constant(0))();
  IntColumn get tokensOut => integer().withDefault(const Constant(0))();
  IntColumn get contextTokens => integer().withDefault(const Constant(0))();
  RealColumn get ttftMs => real().withDefault(const Constant(0.0))();
  RealColumn get tokPerSec => real().withDefault(const Constant(0.0))();
  IntColumn get promptCacheHitTokens =>
      integer().withDefault(const Constant(0))();
  TextColumn get thinkingMode =>
      text().withDefault(const Constant('enabled'))();
  TextColumn get reasoningEffort => text().nullable()();

  /// Optional per-session override for the sampling temperature that
  /// wins over the model's TOML-configured default at API-call time.
  ///
  /// Set via the `/temperature` slash command. User input is clamped
  /// to `[0.0, 1.0]` regardless of what is typed — the underlying
  /// LLM API accepts up to 2.0, but Crux intentionally narrows the
  /// user-facing range to the well-trodden 0–1 "deterministic ↔
  /// creative" axis. `null` means "no override, fall back to the
  /// model's TOML `temperature`".
  RealColumn get temperatureOverride => real().nullable()();
  TextColumn get runningOwnerId => text().nullable()();
  IntColumn get runningHeartbeatAt => integer().nullable()();

  /// Session kind: `NULL`/`'session'` for a normal workspace-bound
  /// session, `'chat'` for Chat mode. Chat rows are workspace-free
  /// (`projectPath` is `''`), carry a minimal system prompt (no
  /// project notes, no skills), are listed in every Crux instance's
  /// "Chats" section (not the project-scoped "Sessions" list), and
  /// are mutually exclusive across instances via the same
  /// running-lease mechanism that guards regular sessions.
  ///
  /// Nullable rather than `withDefault('session')` so the v29
  /// migration is a single `ALTER TABLE ADD COLUMN` with no
  /// backfill — existing rows read as `NULL`, which the model
  /// layer treats identically to `'session'`.
  TextColumn get kind => text().nullable()();

  /// Per-session subagent-mode switches. NULL = never touched in
  /// this session → the runtime falls back to the global default
  /// from `config.toml [subagent]`. Once flipped here, the session's
  /// value is authoritative (switching sessions switches modes;
  /// reopening restores them).
  BoolColumn get subagentWorkersOn => boolean().nullable()();
  BoolColumn get subagentExpertsOn => boolean().nullable()();

  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
  IntColumn get archivedAt => integer().nullable()();

  /// When non-null, the session (workspace or chat) is pinned: it
  /// renders at the top of the sidebar's "Pinned" section and is
  /// exempt from the 3-day auto-archive sweep. Nullable so the
  /// migration is a bare `ALTER TABLE ADD COLUMN` with no backfill;
  /// existing rows read as `NULL` (unpinned).
  IntColumn get pinnedAt => integer().nullable()();

  /// The rendered system prompt — the joined content of all four
  /// layers, ready to be sent as a single `role: 'system'` message.
  /// Computed once at session start and re-attached verbatim on every
  /// turn.
  ///
  /// Stored on the session row (not as a synthetic `role: 'system'`
  /// message in the messages table) so:
  ///   - the compactor can never accidentally compact away Crux's
  ///     identity,
  ///   - a model switch is a single `UPDATE` (no scanning the
  ///     messages table to find the system message),
  ///   - the TUI's `/context` panel can read it directly,
  ///   - `/clear` doesn't need a special case for the system message.
  ///
  /// `null` for legacy sessions opened before schema v19; the turn
  /// pipeline falls back to a freshly-rendered system prompt the
  /// first time such a session is used.
  TextColumn get systemPrompt => text().nullable()();
}

class Messages extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get sessionId =>
      integer().references(Sessions, #id, onDelete: KeyAction.cascade)();
  TextColumn get role => text()();
  TextColumn get content => text().withDefault(const Constant(''))();
  TextColumn get reasoningContent => text().withDefault(const Constant(''))();
  TextColumn get reasoningSignature => text().withDefault(const Constant(''))();
  IntColumn get reasoningTokens => integer().withDefault(const Constant(0))();
  IntColumn get thinkingDurationMs =>
      integer().withDefault(const Constant(0))();
  TextColumn get reasoningEffort => text().nullable()();
  TextColumn get model => text().withDefault(const Constant(''))();
  IntColumn get tokensIn => integer().withDefault(const Constant(0))();
  IntColumn get tokensOut => integer().withDefault(const Constant(0))();
  TextColumn get toolCalls => text().withDefault(const Constant(''))();
  TextColumn get toolCallId => text().withDefault(const Constant(''))();
  TextColumn get tldr => text().withDefault(const Constant(''))();
  TextColumn get error => text().nullable()();
  IntColumn get parentMsgId => integer().nullable()();
  TextColumn get images => text().withDefault(const Constant(''))();

  /// Count of successful tool calls in the round, persisted on
  /// `parallel_praise` rows so the chat history bubble can render
  /// "N tool calls parallelized" without re-deriving the number.
  /// Always `0` for every other role.
  IntColumn get parallelCount => integer().withDefault(const Constant(0))();

  /// Free-form JSON metadata for inline UI affordances attached to
  /// this tool result. Read by the chat-history bubble renderer —
  /// **never** sent to the LLM as part of the tool result body.
  /// Default keys: `routing` (`"direct"` | `"system-proxy"`).
  /// Empty string = no UI metadata, render normally.
  TextColumn get meta => text().withDefault(const Constant(''))();

  IntColumn get createdAt => integer()();
}

class FileReadState extends Table {
  IntColumn get sessionId =>
      integer().references(Sessions, #id, onDelete: KeyAction.cascade)();
  TextColumn get path => text()();
  IntColumn get mtimeMs => integer()();

  @override
  Set<Column> get primaryKey => {sessionId, path};
}

/// Tracks which session last wrote each file, plus the intent string
/// the LLM passed to that edit/write. One row per path (not per
/// session+path like `FileReadState`), because attribution is
/// "who last touched this file globally" rather than "which
/// sessions have observed it".
///
/// The read-before-write guard looks this up when mtime drift is
/// detected and the file was last modified by a *different*
/// session — the guard's response then names that session and its
/// intent so the agent can `session show` / `session messages` it
/// for context before retrying.
///
/// `mtimeMs` is stored alongside the attribution so the guard can
/// refuse to show it when the on-disk mtime no longer matches what
/// the recorded writer produced — i.e. when an external process or
/// user edit changed the file after the recorded write, in which
/// case the intent no longer reflects the file's actual state.
class FileLastWriter extends Table {
  TextColumn get path => text()();
  IntColumn get writerSessionId =>
      integer().references(Sessions, #id, onDelete: KeyAction.cascade)();
  TextColumn get intent => text().withDefault(const Constant(''))();
  IntColumn get mtimeMs => integer()();

  @override
  Set<Column> get primaryKey => {path};
}

/// One row per project holding the user's free-form "my notes"
/// markdown. Keyed on [projectPath] (the workspace root) so every
/// Crux session opened on the same project reads/writes the same
/// note — project-specific, not session-specific. The note content
/// is the source of truth for the "my notes" sidebar widget, which
/// parses `- [ ]` todo items out of the markdown to show remaining
/// work.
///
/// No foreign key to sessions: a note belongs to the project, not to
/// any session, and must survive session deletion. See
/// `notes_store.dart` and the `my-notes.toml` plugin (bundled at
/// `plugins/`, seeded to `~/.crux/plugins/` on launch).
class ProjectNotes extends Table {
  /// The workspace root this note belongs to (Directory.current.path
  /// of the owning session). Primary key — one note per project.
  TextColumn get projectPath => text()();

  /// The raw markdown the user edits in the notes fullpane.
  TextColumn get content => text().withDefault(const Constant(''))();

  /// Last write, millisecondsSinceEpoch. Drives the widget's
  /// "updated HH:MM" display and the status-file projection.
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {projectPath};
}

class Parts extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get messageId =>
      integer().references(Messages, #id, onDelete: KeyAction.cascade)();
  IntColumn get sessionId =>
      integer().references(Sessions, #id, onDelete: KeyAction.cascade)();
  TextColumn get type => text()();
  TextColumn get data => text().withDefault(const Constant('{}'))();
  IntColumn get createdAt => integer()();
}

/// One row per shell-monitor event (see `shell_monitor.dart` and the
/// monitor loop in `shell_base.dart`). When an auxiliary model is
/// configured, every long-running shell command spawns a monitor run;
/// this table is the run's audit trail — which checks fired, what the
/// model saw (output tail), what it decided (verdict + interval +
/// reason), and how the run ended (killed by monitor / finished on
/// its own / fell back to static timeout). Read by `/d-monitor` to
/// verify the aux monitor is judging correctly.
///
/// Rows are written in one batch when the run finishes (the sink in
/// `shell_monitor_log_store.dart` accumulates events in memory and
/// flushes on `finish`), so a burst of checks never interleaves with
/// other writes. A run's events share `runId`, a per-process
/// monotonically increasing id — NOT globally unique across Crux
/// restarts, so queries order by `id` (the rowid) within a run and
/// filter by `sessionId` / `createdAt` across runs.
class ShellMonitorLogs extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get sessionId =>
      integer().references(Sessions, #id, onDelete: KeyAction.cascade)();

  /// Groups all events of one monitor run (one shell command).
  /// Monotonic per Crux process; combined with [sessionId] and
  /// [createdAt] it identifies a run uniquely enough for the debug
  /// viewer. Not a foreign key — runs have no row of their own.
  IntColumn get runId => integer()();

  TextColumn get command => text().withDefault(const Constant(''))();
  TextColumn get intent => text().withDefault(const Constant(''))();

  /// 1-based check ordinal. `0` is the run-start event (emitted when
  /// the monitor arms, before any check has fired); `FINISH` is
  /// recorded as the final event with the next ordinal.
  IntColumn get checkNumber => integer()();

  /// Wall-clock seconds from process spawn to this event.
  IntColumn get elapsedSeconds => integer().withDefault(const Constant(0))();

  /// Bytes of stdout+stderr produced since the previous check. Null
  /// on run-start / run-finish (no snapshot was taken).
  IntColumn get newOutputBytes => integer().nullable()();

  /// Total bytes of stdout+stderr so far. Null on run-start/finish.
  IntColumn get totalOutputBytes => integer().nullable()();

  /// Verdict word (`PROGRESS` / `STUCK` / `UNCERTAIN`), or one of the
  /// loop-generated pseudo-verdicts `EVAL_ERROR` (evaluator threw),
  /// `FALLBACK` (monitor unavailable → static timeout armed),
  /// `FINISH` (run ended). Null only on the run-start event.
  TextColumn get verdict => text().nullable()();

  /// Model-chosen next-check interval in seconds. Null when absent.
  IntColumn get intervalSeconds => integer().nullable()();

  /// Free-text detail: model reason on verdicts, exception text on
  /// `EVAL_ERROR`, fallback note on `FALLBACK`, exit code on `FINISH`.
  TextColumn get reason => text().nullable()();

  /// Output tail shown to the model (capped at
  /// [kMonitorLogTailMaxChars]). Null on run-start/finish.
  TextColumn get outputTail => text().nullable()();

  IntColumn get createdAt => integer()();
}

/// The persistent agent roster — one row per subagent identity (v33).
///
/// Identity is durable; execution is not. A row records who the agent
/// *is* (name, role, domain, bound model) and what it has learned
/// (knowledge / worklog, written by the distillation pipeline); the
/// transient run that does the work lives only in memory. On restart
/// no run exists, so every row simply reads as `ready` again — the
/// v1 "stuck busy after restart" failure mode cannot occur.
///
/// Rosters are workspace-scoped (v37): every query filters on
/// [projectPath], so each project sees (and allocates constellation
/// names within) its own agent set. The unique constraint is the
/// composite `(project_path, name)` — the same constellation id may
/// exist in different workspaces.
///
/// `busy` is the in-memory run flag mirrored here for cross-session
/// visibility (another Crux instance's find_agents reads the table).
/// In practice each process owns its runs; the column exists so the
/// roster query has one source of truth and so crash-orphaned `busy`
/// rows are self-healing: a `busy` row with no live heartbeat owner
/// is treated as `ready` by readers.
class Agents extends Table {
  /// Workspace this agent belongs to (v37). Matches
  /// `sessions.project_path` of the session that hired it; `''` for
  /// rows whose hiring session is unknown (legacy pre-v37 rows).
  TextColumn get projectPath => text().withDefault(const Constant(''))();

  /// Stable constellation id, e.g. `orion` / `libra` / `orion-2`.
  /// The UI renders a localized display name from this id. Unique
  /// within a workspace (see [projectPath]).
  TextColumn get name => text()();

  /// `worker` or `expert`.
  TextColumn get role => text()();

  /// Free-form domain label, e.g. `token-refresh` / `release-pipeline`.
  TextColumn get domain => text().withDefault(const Constant('general'))();

  /// Composite `provider/model` bound at hire time. The binding is
  /// sticky for the agent's lifetime: its knowledge / worklog were
  /// distilled under this model's context scale, and provider caches
  /// are per model.
  TextColumn get model => text()();

  /// `ready` or `busy`. See the class doc for the self-healing rule.
  TextColumn get status => text().withDefault(const Constant('ready'))();

  /// Distilled domain knowledge (the "what I learned" report). Empty
  /// until the first distillation; fed back as context on later runs.
  TextColumn get knowledge => text().withDefault(const Constant(''))();

  /// Distilled work record (the "what I did, with what outcome"
  /// report). Empty until the first distillation; fed back as
  /// context on later runs.
  TextColumn get worklog => text().withDefault(const Constant(''))();

  /// The intention of the current (busy) or most recent (ready)
  /// assignment — the dispatcher's stated purpose, one line. Drives
  /// the chip tooltip and find_agents result rows.
  TextColumn get lastIntention => text().withDefault(const Constant(''))();

  /// Per-agent reasoning effort override (`off`/`low`/`normal`/`high`/
  /// `max`, one of the bound model's reasoning presets). NULL = never
  /// set: the run sends no `reasoning_effort` and the server default
  /// applies (the pre-v38 behavior). Read at each dispatch, so a
  /// change applies from the agent's next run; a live run keeps the
  /// value it started with.
  TextColumn get reasoningEffort => text().nullable()();

  /// Session that owns the live run, when `status = busy`. Readers
  /// treat a `busy` row whose owning session is not live as `ready`
  /// (crash-orphan self-healing).
  IntColumn get runOwnerSessionId => integer().nullable()();

  /// Session that hired this agent. The chat agent bar shows a `ready`
  /// chip ONLY when this matches the current session — rows predating the
  /// column (NULL) are hidden there too. The home roster box is a global
  /// view and ignores it.
  IntColumn get createdBySessionId => integer().nullable()();

  /// Session that most recently *used* this agent: set to the hiring
  /// session at hire time, then re-stamped on every [AgentStore.markBusy]
  /// (i.e. every dispatch). `markReady` deliberately leaves it alone, so
  /// the chip survives the run finishing — this is what makes the chat
  /// agent bar show "every subagent THIS session has used", including
  /// agents hired by another session but dispatched from here.
  ///
  /// Distinct from [runOwnerSessionId]: that one carries crash-orphan
  /// self-healing semantics (a `busy` row with a dead owner reads as
  /// `ready`) and clears on `markReady`, so it cannot answer "used before".
  /// Rows predating this column (NULL) are hidden in the bar, matching the
  /// pre-existing [createdBySessionId] behaviour. The home roster box is a
  /// global view and ignores it.
  IntColumn get lastUsedBySessionId => integer().nullable()();

  IntColumn get createdAt => integer()();
  IntColumn get lastActiveAt => integer()();

  @override
  Set<Column> get primaryKey => {projectPath, name};
}
