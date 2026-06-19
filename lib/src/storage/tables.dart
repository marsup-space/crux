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
  RealColumn get cost => real().withDefault(const Constant(0.0))();
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
  RealColumn get cost => real().withDefault(const Constant(0.0))();
  IntColumn get tokensIn => integer().withDefault(const Constant(0))();
  IntColumn get tokensOut => integer().withDefault(const Constant(0))();
  TextColumn get toolCalls => text().withDefault(const Constant(''))();
  TextColumn get toolCallId => text().withDefault(const Constant(''))();
  TextColumn get tldr => text().withDefault(const Constant(''))();
  TextColumn get error => text().nullable()();
  IntColumn get parentMsgId => integer().nullable()();

  /// Orphaned column — the offloading infrastructure was removed.
  /// Kept in the schema so drift's codegen compiles, but never read.
  IntColumn get preCompressTokens => integer().nullable()();
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

/// Orphaned table — the offloading infrastructure was removed.
/// Kept in the schema so drift's codegen compiles and past
/// migrations work, but the actual on-disk table is dropped at
/// schema v16 via [CruxDatabase._dropOffloadedContent].
class OffloadedContent extends Table {
  IntColumn get sessionId =>
      integer().references(Sessions, #id, onDelete: KeyAction.cascade)();
  TextColumn get callId => text()();
  TextColumn get toolName => text()();
  IntColumn get byteSize => integer()();
  IntColumn get lineCount => integer()();
  TextColumn get content => text()();
  TextColumn get intent => text().withDefault(const Constant(''))();
  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {sessionId, callId};
}
