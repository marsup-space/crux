// Verifies the REAL v37 onUpgrade path: a v36 database (agents keyed
// by UNIQUE(name)) gains `project_path`, the primary key becomes the
// composite (project_path, name), and existing rows are backfilled
// with the project_path of the session that hired them. Rows with no
// resolvable hiring session keep '' (retired — visible in no
// workspace). Uses a temp FILE database so closing + re-opening
// actually re-runs drift's migration (same shape as
// migration_v35_last_used_by_test.dart).
import 'dart:io';

import 'package:crux/src/storage/database.dart' hide Session;
import 'package:drift/native.dart';
import 'package:test/test.dart';

void main() {
  test(
    'real v37 onUpgrade adds project_path + backfills from sessions',
    () async {
      final dir = await Directory.systemTemp.createTemp('crux_v37_test');
      final file = File('${dir.path}/test.db');

      // Build a v36-shaped database: create at the current schema, seed
      // a session + two agents (one attributable to the session, one
      // not), then strip the v37 shape and rewind user_version so the
      // next open believes the DB predates the migration.
      final db1 = CruxDatabase.forTesting(NativeDatabase(file));
      await db1.customStatement(
        "INSERT INTO sessions (slug, title, status, project_path, "
        "created_at, updated_at) VALUES "
        "('s1', 't', 'idle', '/proj/a', 0, 0)",
      );
      final sessionRow = await db1
          .customSelect('SELECT id FROM sessions')
          .getSingle();
      final sid = sessionRow.read<int>('id');

      // v36 shape: no project_path column, UNIQUE(name).
      await db1.customStatement('DROP TABLE agents');
      await db1.customStatement('''
CREATE TABLE agents (
  name TEXT NOT NULL,
  role TEXT NOT NULL,
  domain TEXT NOT NULL DEFAULT 'general',
  model TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'ready',
  knowledge TEXT NOT NULL DEFAULT '',
  worklog TEXT NOT NULL DEFAULT '',
  last_intention TEXT NOT NULL DEFAULT '',
  run_owner_session_id INTEGER,
  created_by_session_id INTEGER,
  last_used_by_session_id INTEGER,
  created_at INTEGER NOT NULL,
  last_active_at INTEGER NOT NULL,
  PRIMARY KEY (name)
)
''');
      await db1.customStatement(
        "INSERT INTO agents (name, role, model, domain, created_by_session_id, "
        "created_at, last_active_at) VALUES "
        "('orion', 'worker', 'm', 'general', $sid, 0, 0)",
      );
      await db1.customStatement(
        "INSERT INTO agents (name, role, model, domain, created_by_session_id, "
        "created_at, last_active_at) VALUES "
        "('vega', 'worker', 'm', 'general', NULL, 0, 0)",
      );
      await db1.customStatement('PRAGMA user_version = 36');
      await db1.close();

      // Re-open: drift sees user_version 36 < 37 → runs onUpgrade
      // (TableMigration rebuild + backfill).
      final db2 = CruxDatabase.forTesting(NativeDatabase(file));

      // Backfill: orion maps to its hiring session's project; vega has
      // no session → '' (retired).
      final rows = await db2
          .customSelect('SELECT name, project_path FROM agents ORDER BY name')
          .get();
      expect(
        rows
            .firstWhere((r) => r.read<String>('name') == 'orion')
            .read<String>('project_path'),
        '/proj/a',
        reason: 'backfilled from the hiring session\'s project_path',
      );
      expect(
        rows
            .firstWhere((r) => r.read<String>('name') == 'vega')
            .read<String>('project_path'),
        '',
        reason: 'no hiring session → retired (matches no workspace query)',
      );

      // The composite PK holds: the same name can now exist in two
      // workspaces, but not twice in one workspace.
      await db2.customStatement(
        "INSERT INTO agents (project_path, name, role, model, domain, "
        "created_at, last_active_at) VALUES "
        "('/proj/b', 'orion', 'worker', 'm', 'general', 0, 0)",
      );
      expect(
        () => db2.customStatement(
          "INSERT INTO agents (project_path, name, role, model, domain, "
          "created_at, last_active_at) VALUES "
          "('/proj/b', 'orion', 'worker', 'm', 'general', 0, 0)",
        ),
        throwsA(isA<Exception>()),
        reason: '(project_path, name) must be unique',
      );
      await db2.close();
      await dir.delete(recursive: true);
    },
  );
}
