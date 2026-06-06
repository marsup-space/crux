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
  IntColumn get createdAt => integer()();
}

class FileReadState extends Table {
  IntColumn get sessionId =>
      integer().references(Sessions, #id, onDelete: KeyAction.cascade)();
  TextColumn get path => text()();
  IntColumn get mtimeMs => integer()();
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
