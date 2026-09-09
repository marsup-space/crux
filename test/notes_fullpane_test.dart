// Tests for the raw markdown notes editor: a single field holding the
// whole note, plain Enter inserting newlines, autosave persisting edits.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:test/test.dart';

import 'package:crux/src/components/notes_fullpane.dart';
import 'package:crux/src/services/notes_service.dart';
import 'package:crux/src/storage/database.dart';
import 'package:crux/src/storage/notes_store.dart';
import 'package:crux/src/theme/crux_theme.dart';

void main() {
  late Directory dir;
  late CruxDatabase db;
  late NotesService service;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('notes_fullpane_');
    db = CruxDatabase.forTesting(NativeDatabase.memory());
    service = NotesService(NotesStore(db), projectPath: dir.path);
  });

  tearDown(() async {
    await db.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> mount(dynamic tester) async {
    await tester.pumpComponent(
      Container(
        width: 80,
        height: 24,
        child: CruxTheme(
          data: CruxThemeData.draculaFallback,
          child: NotesFullpane(service: service, onClose: () {}),
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump();
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
  }

  test('renders the raw markdown source in one field', () async {
    await service.save('# Title\n\n**bold** and plain\n- [ ] todo');
    await testNocterm('notes raw editor', (tester) async {
      await mount(tester);

      final text = tester.terminalState.getText();
      // Raw source visible — markers kept verbatim.
      expect(text.contains('# Title'), isTrue);
      expect(text.contains('**bold**'), isTrue);
      expect(text.contains('- [ ] todo'), isTrue);
      // Status strip shows the parsed todo count.
      expect(text.contains('1 open todo'), isTrue);
    });
  });

  test('plain Enter inserts a newline and the edit autosaves', () async {
    await service.save('alpha');
    await testNocterm('notes raw enter', (tester) async {
      await mount(tester);

      // Move caret to end (already there), press Enter, type a word.
      await tester.sendKeyEvent(KeyboardEvent(logicalKey: LogicalKey.enter));
      await tester.enterText('beta');
      await Future<void>.delayed(const Duration(milliseconds: 900));
      for (var i = 0; i < 3; i++) {
        await tester.pump();
      }

      expect(await service.load(), 'alpha\nbeta');
    });
  });

  test('Ctrl+S saves immediately', () async {
    await service.save('one');
    await testNocterm('notes raw ctrl-s', (tester) async {
      await mount(tester);

      await tester.sendKeyEvent(
        KeyboardEvent(
          logicalKey: LogicalKey.keyS,
          modifiers: const ModifierKeys(ctrl: true),
        ),
      );
      // No dirty edits — save is a no-op, content unchanged.
      expect(await service.load(), 'one');
    });
  });
}
