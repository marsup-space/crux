// Verifies the REAL v36 onUpgrade path: a v35 database (agents table
// without `last_used_by_session_id`) gains the column, and existing rows
// are backfilled from `created_by_session_id` so the chat agent bar keeps
// its pre-v36 behaviour for data written before the column existed.
// Uses a temp FILE database so closing + re-opening actually re-runs
// drift's migration (same shape as migration_v32_untitled_test.dart).
import 'dart:io';

import 'package:crux/src/storage/database.dart' hide Session;
import 'package:drift/native.dart';
import 'package:test/test.dart';

void main() {
  test('real v36 onUpgrade adds + backfills last_used_by_session_id', () async {
    final dir = await Directory.systemTemp.createTemp('crux_v36_test');
    final file = File('${dir.path}/test.db');

    // Build a v35-shaped agents table: create at the current schema,
    // seed two rows, then DROP the v36 column and rewind user_version so
    // the next open believes the DB predates the migration.
    final db1 = CruxDatabase.forTesting(NativeDatabase(file));
    await db1.customStatement(
      "INSERT INTO agents (name, role, model, domain, status, knowledge, "
      "worklog, last_intention, created_by_session_id, created_at, "
      "last_active_at) VALUES "
      "('orion', 'worker', 'm', 'general', 'ready', '', '', '', 42, 0, 0)",
    );
    await db1.customStatement(
      "INSERT INTO agents (name, role, model, domain, status, knowledge, "
      "worklog, last_intention, created_by_session_id, created_at, "
      "last_active_at) VALUES "
      "('vega', 'worker', 'm', 'general', 'ready', '', '', '', NULL, 0, 0)",
    );
    await db1.customStatement(
      'ALTER TABLE agents DROP COLUMN last_used_by_session_id',
    );
    await db1.customStatement('PRAGMA user_version = 35');
    await db1.close();

    // Re-open: drift sees user_version 35 < 36 → runs onUpgrade.
    final db2 = CruxDatabase.forTesting(NativeDatabase(file));
    final rows = await db2
        .customSelect(
          'SELECT name, last_used_by_session_id FROM agents ORDER BY name',
        )
        .get();
    expect(
      rows.firstWhere((r) => r.read<String>('name') == 'orion')
          .read<int?>('last_used_by_session_id'),
      42,
      reason: 'backfilled from created_by_session_id',
    );
    expect(
      rows.firstWhere((r) => r.read<String>('name') == 'vega')
          .read<int?>('last_used_by_session_id'),
      isNull,
      reason: 'a NULL creator stays NULL (hidden in the bar, as before)',
    );
    await db2.close();
    await dir.delete(recursive: true);
  });
}
