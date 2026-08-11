// Tests for NotesStore (project_notes CRUD) — in-memory drift DB.

import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'package:crux/src/storage/database.dart';
import 'package:crux/src/storage/notes_store.dart';

void main() {
  late CruxDatabase db;
  late NotesStore store;

  setUp(() {
    db = CruxDatabase.forTesting(NativeDatabase.memory());
    store = NotesStore(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('load returns null when no note exists', () async {
    expect(await store.load('/proj'), isNull);
    expect(await store.loadContent('/proj'), '');
  });

  test('save inserts a row and stamps updatedAt', () async {
    final before = DateTime.now().millisecondsSinceEpoch;
    final note = await store.save('/proj', '# hello\n- [ ] task');
    expect(note.projectPath, '/proj');
    expect(note.content, contains('task'));
    expect(note.updatedAt, greaterThanOrEqualTo(before));

    final loaded = await store.load('/proj');
    expect(loaded, isNotNull);
    expect(loaded!.content, '# hello\n- [ ] task');
  });

  test('save upserts — second write replaces content', () async {
    await store.save('/proj', 'v1');
    final v2 = await store.save('/proj', 'v2');
    expect(v2.content, 'v2');
    expect(await store.loadContent('/proj'), 'v2');
    // Still a single row.
    final all = await db.select(db.projectNotes).get();
    expect(all.length, 1);
  });

  test('notes are project-scoped — distinct paths stay separate', () async {
    await store.save('/a', 'note a');
    await store.save('/b', 'note b');
    expect(await store.loadContent('/a'), 'note a');
    expect(await store.loadContent('/b'), 'note b');
  });

  test('delete removes only the target project row', () async {
    await store.save('/a', 'note a');
    await store.save('/b', 'note b');
    await store.delete('/a');
    expect(await store.load('/a'), isNull);
    expect(await store.loadContent('/b'), 'note b');
  });
}
