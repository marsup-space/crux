import 'package:bloc_test/bloc_test.dart';
import 'package:crux/src/components/overlay_cubit.dart';
import 'package:crux/src/components/overlay_types.dart';
import 'package:crux/src/models/slash_command.dart';
import 'package:crux/src/utils/file_searcher.dart';
import 'package:nocterm/nocterm.dart' hide OverlayState, isEmpty;
import 'package:test/test.dart';

void main() {
  late TextEditingController textController;
  late List<String> executedCommands;

  OverlayCubit buildCubit({int maxVisibleItems = 3}) {
    return OverlayCubit(
      maxVisibleItems: maxVisibleItems,
      textController: textController,
      executeCommandCallback: executedCommands.add,
    );
  }

  setUp(() {
    textController = TextEditingController();
    executedCommands = [];
  });

  tearDown(() {
    textController.dispose();
  });

  group('OverlayCubit', () {
    blocTest<OverlayCubit, OverlayState>(
      'shows command overlay and wraps selection',
      build: buildCubit,
      act: (cubit) {
        cubit.showCommands(_commands(4));
        cubit.moveCommandSelectionUp();
        cubit.moveCommandSelectionDown();
      },
      expect: () => [
        isA<OverlayState>()
            .having((s) => s.overlayMode, 'mode', OverlayMode.command)
            .having((s) => s.filteredCommands.length, 'commands', 4)
            .having((s) => s.selectedCommandIndex, 'selected', 0),
        isA<OverlayState>()
            .having((s) => s.selectedCommandIndex, 'selected', 3)
            .having((s) => s.commandScrollOffset, 'scroll', 1),
        isA<OverlayState>()
            .having((s) => s.selectedCommandIndex, 'selected', 0)
            .having((s) => s.commandScrollOffset, 'scroll', 0),
      ],
    );

    blocTest<OverlayCubit, OverlayState>(
      'scrolls command overlay by visible page',
      build: buildCubit,
      act: (cubit) {
        cubit.showCommands(_commands(8));
        cubit.onScrollCommand(_wheel(MouseButton.wheelDown));
        cubit.onScrollCommand(_wheel(MouseButton.wheelDown));
        cubit.onScrollCommand(_wheel(MouseButton.wheelUp));
      },
      skip: 1,
      expect: () => [
        isA<OverlayState>().having((s) => s.commandScrollOffset, 'scroll', 3),
        isA<OverlayState>().having((s) => s.commandScrollOffset, 'scroll', 5),
        isA<OverlayState>().having((s) => s.commandScrollOffset, 'scroll', 2),
      ],
    );

    test('command tap executes leaf commands and clears overlay', () {
      final cubit = buildCubit();
      addTearDown(cubit.close);

      cubit.showCommands(_commands(1));
      cubit.onTapCommand(0);

      expect(cubit.state.overlayMode, OverlayMode.off);
      expect(textController.text, isEmpty);
      expect(executedCommands, ['/cmd0']);
    });

    test('command tap seeds text for parameter commands', () {
      final cubit = buildCubit();
      addTearDown(cubit.close);

      const command = SlashCommand(
        name: '/model',
        description: 'Switch model',
        params: ['name'],
      );
      cubit.showCommands([command]);
      cubit.onTapCommand(0);

      expect(textController.text, '/model ');
      expect(textController.selection.extentOffset, textController.text.length);
      expect(cubit.state.overlayMode, OverlayMode.command);
      expect(executedCommands, isEmpty);
    });

    test('suggestion tap executes final parameter', () {
      final cubit = buildCubit();
      addTearDown(cubit.close);
      const command = SlashCommand(
        name: '/theme',
        description: 'Switch theme',
        params: ['theme'],
      );
      textController.text = '/theme ca';
      textController.selection = TextSelection.collapsed(
        offset: textController.text.length,
      );

      cubit.showParameterSuggestions(
        command: command,
        paramIndex: 0,
        suggestions: const [CommandSuggestion(value: 'cappuccino')],
      );
      cubit.onTapSuggestion(0);

      expect(cubit.state.overlayMode, OverlayMode.off);
      expect(textController.text, isEmpty);
      expect(executedCommands, ['/theme cappuccino']);
    });

    test('suggestion tap advances multi-parameter commands', () {
      final cubit = buildCubit();
      addTearDown(cubit.close);
      const command = SlashCommand(
        name: '/provider',
        description: 'Configure provider',
        params: ['provider', 'key'],
      );
      textController.text = '/provider op';
      textController.selection = TextSelection.collapsed(
        offset: textController.text.length,
      );

      cubit.showParameterSuggestions(
        command: command,
        paramIndex: 0,
        suggestions: const [CommandSuggestion(value: 'openai')],
      );
      cubit.onTapSuggestion(0);

      expect(textController.text, '/provider openai ');
      expect(textController.selection.extentOffset, textController.text.length);
      expect(cubit.state.overlayMode, OverlayMode.parameter);
      expect(executedCommands, isEmpty);
    });

    blocTest<OverlayCubit, OverlayState>(
      'shows @mention results and moves file selection',
      build: buildCubit,
      act: (cubit) {
        cubit.showAtMention(atOffset: 6, query: 'lib', resetResults: true);
        cubit.setAtMentionResults(const [
          FileMatch(
            relativePath: 'lib/a.dart',
            kind: FileMatchKind.file,
            score: 10,
          ),
          FileMatch(
            relativePath: 'lib/src/',
            kind: FileMatchKind.directory,
            score: 8,
          ),
        ]);
        cubit.moveFileSelectionDown();
      },
      expect: () => [
        isA<OverlayState>()
            .having((s) => s.overlayMode, 'mode', OverlayMode.atMention)
            .having((s) => s.atMentionQuery, 'query', 'lib')
            .having((s) => s.isSearching, 'searching', isTrue),
        isA<OverlayState>()
            .having((s) => s.filteredFiles.length, 'files', 2)
            .having((s) => s.selectedFileIndex, 'selected', 0)
            .having((s) => s.isSearching, 'searching', isFalse),
        isA<OverlayState>().having(
          (s) => s.selectedFile?.relativePath,
          'selected file',
          'lib/src/',
        ),
      ],
    );

    test('insertAtMention replaces active query and closes overlay', () {
      final cubit = buildCubit();
      addTearDown(cubit.close);

      textController.text = 'open @li';
      textController.selection = TextSelection.collapsed(
        offset: textController.text.length,
      );
      cubit.showAtMention(atOffset: 5, query: 'li', resetResults: true);
      cubit.setAtMentionResults(const [
        FileMatch(
          relativePath: 'lib/main.dart',
          kind: FileMatchKind.file,
          score: 12,
        ),
      ]);

      cubit.insertAtMention(null);

      expect(textController.text, 'open @lib/main.dart ');
      expect(textController.selection.extentOffset, textController.text.length);
      expect(cubit.state.overlayMode, OverlayMode.off);
    });

    blocTest<OverlayCubit, OverlayState>(
      'toggles fullpane and session manager flags',
      build: buildCubit,
      act: (cubit) {
        cubit.setFullpaneVisible(true);
        cubit.setSessionManagerVisible(true);
        cubit.setOverlayOff();
      },
      expect: () => [
        isA<OverlayState>().having((s) => s.showFullpane, 'fullpane', isTrue),
        isA<OverlayState>().having(
          (s) => s.showSessionManager,
          'session manager',
          isTrue,
        ),
        isA<OverlayState>()
            .having((s) => s.showFullpane, 'fullpane', isFalse)
            .having((s) => s.showSessionManager, 'session manager', isFalse),
      ],
    );
  });
}

List<SlashCommand> _commands(int count) {
  return [
    for (var i = 0; i < count; i++)
      SlashCommand(name: '/cmd$i', description: 'Command $i'),
  ];
}

MouseEvent _wheel(MouseButton button) {
  return MouseEvent(button: button, x: 0, y: 0, pressed: false);
}
