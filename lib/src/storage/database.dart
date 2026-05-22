import 'dart:ffi';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart';

import '../models/session.dart';
import 'tables.dart';

part 'database.g.dart';

@DriftDatabase(tables: [Sessions, Messages, Parts])
class CruxDatabase extends _$CruxDatabase {
  CruxDatabase() : super(_openConnection());

  CruxDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 3;

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
  final xdgDataHome = Platform.environment['XDG_DATA_HOME'];
  if (xdgDataHome != null && xdgDataHome.isNotEmpty) {
    return p.join(xdgDataHome, 'crux');
  }
  return p.join(
      Platform.environment['HOME'] ?? '.', '.local', 'share', 'crux');
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
