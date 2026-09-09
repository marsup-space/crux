// Verifies the REAL v32 onUpgrade path: a database file created at
// schema v31 with legacy placeholder titles is re-opened and the
// rows come back with '' (untitled). Uses a temp FILE database so
// closing + re-opening actually re-runs drift's migration.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:crux/src/storage/database.dart' hide Session;

void main() {
  test('real v32 onUpgrade resets placeholder titles on re-open', () async {
    final dir = await Directory.systemTemp.createTemp('crux_v32_test');
    final file = File('${dir.path}/test.db');

    // Open at current schema, seed, then rewind user_version to 31
    // so the next open believes the DB is pre-v32.
    final db1 = CruxDatabase.forTesting(NativeDatabase(file));
    await db1.customStatement(
      "INSERT INTO sessions (slug, title, kind, status, created_at, updated_at) "
      "VALUES ('s1', 'New Session', NULL, 0, 0, 0)",
    );
    await db1.customStatement(
      "INSERT INTO sessions (slug, title, kind, status, created_at, updated_at) "
      "VALUES ('s2', 'New Chat', 'chat', 0, 0, 0)",
    );
    await db1.customStatement(
      "INSERT INTO sessions (slug, title, kind, status, created_at, updated_at) "
      "VALUES ('s3', 'Real Title', NULL, 0, 0, 0)",
    );
    await db1.customStatement('PRAGMA user_version = 31');
    await db1.close();

    // Re-open: drift sees user_version 31 < 32 → runs onUpgrade.
    final db2 = CruxDatabase.forTesting(NativeDatabase(file));
    final rows = await db2.customSelect('SELECT title FROM sessions').get();
    final titles = rows.map((r) => r.read<String>('title')).toList()..sort();
    expect(titles, ['', '', 'Real Title']);
    await db2.close();
    await dir.delete(recursive: true);
  });
}
