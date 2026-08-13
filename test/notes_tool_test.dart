import 'dart:io';

import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'package:crux/src/storage/storage.dart';
import 'package:crux/src/tools/notes_tool.dart';
import 'package:crux/src/tools/tool_def.dart';

void main() {
  late CruxDatabase db;
  late SessionStore store;
  late NotesTool tool;
  late Directory tempProject;

  ToolContext ctx() => ToolContext(
    sessionId: 0,
    messageId: 0,
    abort: AbortSignal(),
    workingDirectory: tempProject.path,
  );

  setUp(() async {
    db = CruxDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    store = SessionStore(db);
    tool = NotesTool(store: store);

    tempProject = await Directory.systemTemp.createTemp('crux_notes_tool_');
    addTearDown(() async {
      if (await tempProject.exists()) {
        await tempProject.delete(recursive: true);
      }
    });
  });

  test('schema takes no arguments', () {
    final schema = tool.parametersSchema;
    expect(schema['type'], 'object');
    expect((schema['properties'] as Map), isEmpty);
  });

  test('returns "no notes yet" when the project has no note', () async {
    final result = await tool.execute({}, ctx());
    expect(result.output, contains('No notes yet'));
    expect(result.metadata['exists'], isFalse);
    expect(result.metadata['charCount'], 0);
  });

  test('returns the full note content verbatim', () async {
    await store.notesStore.save(
      tempProject.path,
      '- [ ] fix the bug\n- [ ] write tests\n\nSome free-form text.',
    );

    final result = await tool.execute({}, ctx());

    expect(result.output, contains('fix the bug'));
    expect(result.output, contains('write tests'));
    expect(result.output, contains('Some free-form text.'));
    expect(result.output, contains('my notes — updated'));
    expect(result.metadata['charCount'], greaterThan(0));
    expect(result.metadata['updatedAt'], isA<int>());
  });

  test('reads the live row — a later save is reflected on the next call',
      () async {
    await store.notesStore.save(tempProject.path, 'v1');
    final first = await tool.execute({}, ctx());
    expect(first.output, contains('v1'));
    expect(first.output, isNot(contains('v2')));

    await store.notesStore.save(tempProject.path, 'v2');
    final second = await tool.execute({}, ctx());
    expect(second.output, contains('v2'));
    expect(second.output, isNot(contains('v1')));
  });

  test('only reads the note for the current project', () async {
    await store.notesStore.save(
      '/some/other/project',
      'secret from another project',
    );

    final result = await tool.execute({}, ctx());

    expect(result.output, contains('No notes yet'));
    expect(result.output, isNot(contains('secret')));
  });
}
