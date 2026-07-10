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
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
  IntColumn get archivedAt => integer().nullable()();

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
