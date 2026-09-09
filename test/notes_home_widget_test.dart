// Tests for the home dashboard `my notes` box — same data + interaction
// as the sidebar my-notes spec widget, reusing NotesService and the
// shared ClickableTodoList.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:test/test.dart';

import 'package:crux/src/components/home/home_widgets.dart';
import 'package:crux/src/components/home/widgets/notes_widget.dart';
import 'package:crux/src/services/git_status_service.dart';
import 'package:crux/src/services/notes_service.dart';
import 'package:crux/src/storage/database.dart';
import 'package:crux/src/storage/notes_store.dart';
import 'package:crux/src/theme/crux_theme.dart';

void main() {
  late Directory dir;
  late CruxDatabase db;
  late NotesService service;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('notes_home_widget_');
    db = CruxDatabase.forTesting(NativeDatabase.memory());
    service = NotesService(NotesStore(db), projectPath: dir.path);
  });

  tearDown(() async {
    await db.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> pump(
    dynamic tester,
    NotesHomeWidget widget,
    HomeContext ctx,
  ) async {
    await tester.pumpComponent(
      Container(
        width: 60,
        height: 12,
        child: CruxTheme(
          data: CruxThemeData.draculaFallback,
          child: Builder(builder: (context) => widget.build(context, ctx, 1)),
        ),
      ),
    );
    await tester.pump();
  }

  HomeContext ctx({void Function()? openNotes}) => HomeContext(
    runCommand: (_) => true,
    close: () {},
    seedInput: (_) {},
    gitStatusService: GitStatusService(),
    sessions: () => const [],
    currentSessionId: () => null,
    switchSession: (_) => false,
    notesService: service,
    openNotes: openNotes,
  );

  test(
    'renders the projection todos as clickable rows + open button',
    () async {
      await service.save('# Title\n- [ ] fix bug\n- [ ] write tests');
      var opened = 0;
      await testNocterm('notes home box', (tester) async {
        await pump(
          tester,
          NotesHomeWidget(service: service, openNotes: () {}),
          ctx(openNotes: () => opened++),
        );

        final text = tester.terminalState.getText();
        expect(text.contains('2 todos'), isTrue);
        expect(text.contains('☐ fix bug'), isTrue);
        expect(text.contains('☐ write tests'), isTrue);
        expect(text.contains('open'), isTrue);

        // Open button fires the fullpane callback.
        final open = tester.terminalState.findText('open').first;
        await tester.hover(open.x + 1, open.y);
        await tester.pump();
        await tester.tap(open.x + 1, open.y);
        await tester.pump();
        expect(opened, 1);
      });
    },
  );

  test('clicking a todo row marks it done via the shared service', () async {
    await service.save('- [ ] fix bug');
    await testNocterm('notes home box toggle', (tester) async {
      await pump(
        tester,
        NotesHomeWidget(service: service, openNotes: null),
        ctx(),
      );

      final row = tester.terminalState.findText('fix bug').first;
      await tester.hover(row.x + 1, row.y);
      await tester.pump();
      await tester.tap(row.x + 1, row.y);
      await tester.pump();

      // Locally checked immediately.
      expect(tester.terminalState.containsText('☑ fix bug'), isTrue);
      // Persisted to the DB via NotesService.
      expect(await service.load(), '- [x] fix bug');
    });
  });

  test('no notes feature → placeholder', () async {
    final bare = HomeContext.minimal(close: () {});
    await testNocterm('notes home box none', (tester) async {
      await tester.pumpComponent(
        Container(
          width: 60,
          height: 12,
          child: CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: Builder(
              builder: (context) => NotesHomeWidget(
                service: null,
                openNotes: null,
              ).build(context, bare, 1),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.terminalState.containsText('no notes feature'), isTrue);
    });
  });

  test('long todos wrap with a hanging indent', () async {
    const long =
        'alpha bravo charlie delta echo foxtrot golf hotel india '
        'juliet kilo lima mike';
    await service.save('- [ ] $long');
    await testNocterm('notes home box wrap', (tester) async {
      await tester.pumpComponent(
        Container(
          width: 30,
          height: 8,
          child: CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: Builder(
              builder: (context) => NotesHomeWidget(
                service: service,
                openNotes: null,
              ).build(context, ctx(), 1),
            ),
          ),
        ),
      );
      await tester.pump();

      final text = tester.terminalState.getText();
      // Checkbox flush-left with a single-space gutter.
      expect(RegExp(r'(^|\n)☐ ').hasMatch(text), isTrue);
      // Wrapped continuation lines are indented under the content column.
      expect(RegExp(r'\n  \S').hasMatch(text), isTrue);
    }, size: const Size(30, 12));
  });
}
