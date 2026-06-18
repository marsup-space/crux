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

@DriftDatabase(tables: [Sessions, Messages, Parts, FileReadState, OffloadedContent])
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
  ///   v10 – offloaded_content table
  ///   v11 – messages.preCompressTokens
  ///   v12 – messages.reasoningSignature
  ///   v13 – fileReadState altered (session_id added to PK)
  ///   v14 – offloaded_content.intent
  ///   v15 – messages.images
  ///   v16 – offloaded_content and preCompressTokens are now dead
  ///         schema (the offloading infrastructure was removed).
  ///         The table/column persist on disk for drift validation
  ///         but no application code reads or writes them.
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
  @override
  int get schemaVersion => 19;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator m) async {
      await m.createAll();
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
        await m.createTable(offloadedContent);
      }
      if (from < 11) {
        await m.addColumn(messages, messages.preCompressTokens);
      }
      if (from < 12) {
        await m.addColumn(messages, messages.reasoningSignature);
      }
      if (from < 13) {
        await m.alterTable(TableMigration(fileReadState));
      }
      if (from < 14) {
        await m.addColumn(offloadedContent, offloadedContent.intent);
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
    },
  );
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dbDir = _getDatabaseDirectory();
    await Directory(dbDir).create(recursive: true);
    final file = File(p.join(dbDir, 'crux.db'));

    open.overrideFor(OperatingSystem.linux, _openLinuxSqlite);

    return NativeDatabase.createInBackground(file, setup: (db) {
      db.execute('PRAGMA journal_mode=WAL;');
      db.execute('PRAGMA busy_timeout=5000;');
    });
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
