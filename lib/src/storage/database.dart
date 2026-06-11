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
  CruxDatabase.forTesting(QueryExecutor executor) : super(executor);

  @override
  int get schemaVersion => 12;

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
        // ignore: invalid_use_of_protected_member
      }
      if (from < 12) {
        await m.addColumn(messages, messages.reasoningSignature);
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

    return NativeDatabase.createInBackground(file);
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
