// Covers databases that a development build marked current without creating
// the persistent subagent roster. The normal migration chain is skipped for
// such a file, so the every-open repair must restore both find and hire.
import 'dart:io';

import 'package:crux/src/models/subagent.dart';
import 'package:crux/src/storage/agent_store.dart';
import 'package:crux/src/storage/database.dart';
import 'package:drift/native.dart';
import 'package:test/test.dart';

void main() {
  test('repairs a current-version database missing the agents table', () async {
    final dir = await Directory.systemTemp.createTemp('crux_agents_repair');
    final file = File('${dir.path}/test.db');

    // Create the current schema, then reproduce the broken persisted state:
    // the table is missing while SQLite's user_version remains current.
    final db1 = CruxDatabase.forTesting(NativeDatabase(file));
    await db1.customStatement('DROP TABLE agents');
    await db1.close();

    final db2 = CruxDatabase.forTesting(NativeDatabase(file));
    final store = AgentStore(db2);

    // find_agents calls listAll; it must work before any agent is hired.
    expect(await store.listAll('/workspace'), isEmpty);

    // hire_agent uses the same restored table for name allocation and insert.
    final hired = await store.hire(
      projectPath: '/workspace',
      role: SubagentRole.worker,
      model: 'test/model',
    );
    expect(hired.name, isNotEmpty);
    expect((await store.listAll('/workspace')).single.name, hired.name);

    await db2.close();
    await dir.delete(recursive: true);
  });
}
