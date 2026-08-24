// Tests for NotesService — DB persistence plus the widget status-file
// projection (the "same architecture as crux dev" JSON bus).

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:crux/src/services/notes_service.dart';
import 'package:crux/src/storage/database.dart';
import 'package:crux/src/storage/notes_store.dart';
import 'package:crux/src/utils/todo_parser.dart';

void main() {
  late Directory project;
  late CruxDatabase db;
  late NotesService service;

  setUp(() {
    project = Directory.systemTemp.createTempSync('notes_service_');
    db = CruxDatabase.forTesting(NativeDatabase.memory());
    service = NotesService(
      NotesStore(db),
      projectPath: project.path,
    );
  });

  tearDown(() async {
    await db.close();
    try {
      project.deleteSync(recursive: true);
    } catch (_) {}
  });

  File statusFile() => File(p.join(project.path, NotesService.statusPath));

  Map<String, dynamic> readProjection() =>
      jsonDecode(statusFile().readAsStringSync()) as Map<String, dynamic>;

  group('renderDisplay', () {
    test('empty summary → "no todos"', () {
      expect(NotesService.renderDisplay(const TodoSummary([])), 'no todos');
    });

    test('count line only — items live in the todos array, not the label', () {
      final s = parseTodos('- [ ] a\n- [x] done\n- [ ] b\n');
      final display = NotesService.renderDisplay(s);
      expect(
        display,
        '2 todos',
      );
    });

    test('overflow no longer collapses — the full list scrolls at the host',
        () {
      final s = parseTodos(
        '- [ ] one\n- [ ] two\n- [ ] three\n- [ ] four\n- [ ] five\n',
      );
      // Count line only: rendering surfaces show every open todo in a
      // scrollable list, so there's no "+N more" overflow line anymore.
      expect(NotesService.renderDisplay(s), '5 todos');
    });

    test('singular "todo" for exactly one open item', () {
      final s = parseTodos('- [ ] only\n- [x] done\n');
      expect(NotesService.renderDisplay(s), '1 todo');
    });
  });

  group('projection', () {
    test('init writes the projection file from the (empty) DB', () async {
      final content = await service.init();
      expect(content, '');
      expect(statusFile().existsSync(), isTrue);
      final proj = readProjection();
      expect(proj['openCount'], 0);
      expect(proj['display'], 'no todos');
      expect(proj['todos'], isEmpty);
      expect(proj['updatedAt'], isA<String>());
    });

    test('save persists to the DB and refreshes the projection', () async {
      await service.init();
      final summary = await service.save('- [ ] write tests\n- [ ] ship\n');
      expect(summary.openCount, 2);

      // DB is the source of truth.
      expect(await service.load(), '- [ ] write tests\n- [ ] ship\n');

      final proj = readProjection();
      expect(proj['openCount'], 2);
      expect(proj['display'], '2 todos');
      // Structured rows carry text + source line index.
      expect(proj['todos'], [
        {'text': 'write tests', 'line': 0},
        {'text': 'ship', 'line': 1},
      ]);
    });

    test('todos array carries the full open list (host scrolls, no cap)',
        () async {
      await service.init();
      await service.save(
        '- [ ] one\n- [ ] two\n- [ ] three\n- [ ] four\n',
      );
      final proj = readProjection();
      expect(proj['todos'], hasLength(4)); // uncapped — full list
      expect(proj['display'], '4 todos');
    });

    test('projection reflects fenced-code todos being ignored', () async {
      await service.init();
      await service.save('- [ ] real\n```\n- [ ] fake\n```\n');
      final proj = readProjection();
      expect(proj['openCount'], 1);
      final todos = proj['todos'] as List;
      expect(todos, hasLength(1));
      expect((todos.single as Map)['text'], 'real');
      expect(proj['display'], isNot(contains('fake')));
    });

    test('a torn/absent projection regenerates on next save', () async {
      await service.init();
      statusFile().deleteSync();
      expect(statusFile().existsSync(), isFalse);
      await service.save('- [ ] back\n');
      expect(readProjection()['openCount'], 1);
    });
  });

  group('markTodoDone', () {
    test('flips the exact line and rewrites the projection', () async {
      await service.init();
      await service.save('- [ ] a\n- [ ] b\n- [ ] c\n');
      final summary = await service.markTodoDone(1);
      expect(summary.openCount, 2);
      expect(await service.load(), '- [ ] a\n- [x] b\n- [ ] c\n');

      final proj = readProjection();
      expect(proj['openCount'], 2);
      final todos = proj['todos'] as List;
      expect(todos.map((t) => (t as Map)['text']), ['a', 'c']);
      expect(proj['display'], '2 todos');
    });

    test('out-of-range line is a no-op', () async {
      await service.init();
      await service.save('- [ ] a\n');
      final summary = await service.markTodoDone(99);
      expect(summary.openCount, 1);
      expect(await service.load(), '- [ ] a\n');
    });

    test('an already-done or non-todo line is a no-op', () async {
      await service.init();
      await service.save('- [x] done\nplain text\n');
      await service.markTodoDone(0);
      expect(await service.load(), '- [x] done\nplain text\n');
      await service.markTodoDone(1);
      expect(await service.load(), '- [x] done\nplain text\n');
    });

    test('works with star / plus / ordered markers', () async {
      await service.init();
      await service.save('* [ ] star\n+ [ ] plus\n1. [ ] ordered\n');
      await service.markTodoDone(1);
      expect(await service.load(), '* [ ] star\n+ [x] plus\n1. [ ] ordered\n');
    });

    test('flips the empty-bracket form `- []` (no space)', () async {
      // The parser treats `- []` as an unchecked todo; the flip must
      // rebuild the marker, not search for the literal `[ ]` string —
      // regression for the real note content that never ticked off.
      await service.init();
      await service.save('- [] coding plan box\n- [] second\n');
      final summary = await service.markTodoDone(0);
      expect(summary.openCount, 1);
      expect(await service.load(), '- [x] coding plan box\n- [] second\n');

      final proj = readProjection();
      expect(proj['openCount'], 1);
      final todos = proj['todos'] as List;
      expect((todos.single as Map)['text'], 'second');
    });

    test('markTodoOpen undoes a done todo (the widget undo window)',
        () async {
      await service.init();
      await service.save('- [ ] a\n- [ ] b\n');
      await service.markTodoDone(0);
      expect(await service.load(), '- [x] a\n- [ ] b\n');

      final summary = await service.markTodoOpen(0);
      expect(summary.openCount, 2);
      expect(await service.load(), '- [ ] a\n- [ ] b\n');

      final proj = readProjection();
      expect(proj['openCount'], 2);
      expect(proj['todos'], hasLength(2));
      expect(proj['display'], '2 todos');
    });

    test('markTodoOpen is a no-op on an already-open or non-todo line',
        () async {
      await service.init();
      await service.save('- [ ] a\nplain\n');
      await service.markTodoOpen(0);
      expect(await service.load(), '- [ ] a\nplain\n');
      await service.markTodoOpen(1);
      expect(await service.load(), '- [ ] a\nplain\n');
      await service.markTodoOpen(99);
      expect(await service.load(), '- [ ] a\nplain\n');
    });
  });
}
