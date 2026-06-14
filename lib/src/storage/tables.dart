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
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
  IntColumn get archivedAt => integer().nullable()();
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

  /// Total round-trip token cost of the tool_call's args *before*
  /// compression. Set by the chat service when a LargePayloadTool's
  /// large args were off-loaded. Null for non-tool-call messages
  /// and for tool_call messages whose args were small enough to
  /// keep in full. The chat bubble uses this to render the
  /// pre/post compression comparison (e.g. `~~5000t~~, compressed: 15t`).
  IntColumn get preCompressTokens => integer().nullable()();
  TextColumn get images => text().withDefault(const Constant(''))();
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

/// Off-loaded large tool-call argument values. When a [LargePayloadTool]
/// call's argument (e.g. `write.content`, `edit.oldString/newString`)
/// exceeds the offload threshold, the full bytes are written here and
/// the persisted tool_call's argument is replaced with a stand-in
/// pointer (`[N lines, B bytes; recall: <callId>]`). The LLM can
/// recover the full bytes on demand via the `recall` tool.
///
/// Lifetime is bound to the session: `ON DELETE CASCADE` on the FK
/// to `sessions` ensures the bytes die with the session (whether by
/// explicit delete, or — once `/compact` exists — by a future
/// `cleanOffloadedContent` call from `archiveSession`).
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
