import 'package:test/test.dart';
import 'package:nocterm/nocterm.dart' hide isNotEmpty;
import 'package:crux/src/models/slash_command.dart';
import 'package:crux/src/models/message.dart';
import 'package:crux/src/components/ui/button.dart';
import 'package:crux/src/components/ui/toast.dart';
import 'package:crux/src/components/command_overlay.dart';
import 'package:crux/src/components/message_bubble.dart';

import 'package:crux/src/components/ui/highlighted_markdown_text.dart';
import 'package:crux/src/components/ui/highlight_service.dart';
import 'package:crux/src/components/ui/response_link_text.dart';
import 'package:crux/src/theme/crux_theme.dart';

void main() {
  group('HighlightedMarkdownText', () {
    test('h1 heading renders without # markers', () async {
      await testNocterm('h1', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 10,
            child: HighlightedMarkdownText('# Hello'),
          ),
        );
        expect(tester.terminalState, containsText('Hello'));
        expect(tester.terminalState.containsText('#'), isFalse);
      });
    });

    test('h2 heading renders without ## markers', () async {
      await testNocterm('h2', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 10,
            child: HighlightedMarkdownText('## Title'),
          ),
        );
        expect(tester.terminalState, containsText('Title'));
        expect(tester.terminalState.containsText('##'), isFalse);
      });
    });

    test('paragraph renders text', () async {
      await testNocterm('paragraph', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 10,
            child: HighlightedMarkdownText('Some plain text'),
          ),
        );
        expect(tester.terminalState, containsText('plain text'));
      });
    });

    test('bold renders without ** markers', () async {
      await testNocterm('bold', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 10,
            child: HighlightedMarkdownText('This is **bold** text'),
          ),
        );
        expect(tester.terminalState, containsText('bold'));
        expect(tester.terminalState.containsText('**bold**'), isFalse);
        expect(tester.terminalState.containsText('**'), isFalse);
      });
    });

    test('italic renders without * markers', () async {
      await testNocterm('italic', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 10,
            child: HighlightedMarkdownText('This is *italic* text'),
          ),
        );
        expect(tester.terminalState, containsText('italic'));
        expect(tester.terminalState.containsText('*italic*'), isFalse);
      });
    });

    test('strikethrough renders without ~~ markers', () async {
      await testNocterm('strikethrough', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 10,
            child: HighlightedMarkdownText('This is ~~deleted~~ text'),
          ),
        );
        expect(tester.terminalState, containsText('deleted'));
        expect(tester.terminalState.containsText('~~deleted~~'), isFalse);
        expect(tester.terminalState.containsText('~~'), isFalse);
      });
    });

    test('inline code renders without backtick markers', () async {
      await testNocterm('inline code', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 10,
            child: HighlightedMarkdownText('Use the `foo` function'),
          ),
        );
        expect(tester.terminalState, containsText('foo'));
        expect(tester.terminalState.containsText('`'), isFalse);
      });
    });

    test('code block renders with header and border', () async {
      await testNocterm('code block', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 24,
            child: HighlightedMarkdownText('```dart\nprint("hi");\n```'),
          ),
        );
        expect(tester.terminalState, containsText('print'));
        expect(tester.terminalState, containsText('dart'));
        expect(tester.terminalState, containsText('│'));
        expect(tester.terminalState.containsText('```'), isFalse);
      });
    });

    test('code block paints complete themed rows', () async {
      final theme = CruxThemeData.draculaFallback;
      await testNocterm('code block themed rows', (tester) async {
        await tester.pumpComponent(
          CruxTheme(
            data: theme,
            child: Container(
              width: 32,
              height: 8,
              child: const HighlightedMarkdownText(
                '```dart\nfinal x = 1;\n```',
              ),
            ),
          ),
        );

        final topLeft = tester.terminalState.getCellAt(0, 0)!;
        final topRight = tester.terminalState.getCellAt(31, 0)!;
        final codeLeft = tester.terminalState.getCellAt(0, 1)!;
        final codeRight = tester.terminalState.getCellAt(31, 1)!;
        final paddedInterior = tester.terminalState.getCellAt(20, 1)!;
        final bottomRight = tester.terminalState.getCellAt(31, 2)!;

        expect(topLeft.char, '┌');
        expect(topRight.char, '┐');
        expect(codeLeft.char, '│');
        expect(codeRight.char, '│');
        expect(bottomRight.char, '┘');

        for (final cell in [
          topLeft,
          topRight,
          codeLeft,
          codeRight,
          bottomRight,
        ]) {
          expect(cell.style.color, theme.codeBlockGutter);
          expect(cell.style.backgroundColor, theme.codeBlockBackground);
        }
        expect(paddedInterior.char, ' ');
        expect(paddedInterior.style.backgroundColor, theme.codeBlockBackground);
      }, size: const Size(32, 8));
    });

    test('code block selection omits visual border chrome', () async {
      final theme = CruxThemeData.draculaFallback;
      String? completed;
      await testNocterm('code block selection text', (tester) async {
        await tester.pumpComponent(
          CruxTheme(
            data: theme,
            child: Container(
              width: 32,
              height: 8,
              child: SelectionArea(
                onSelectionCompleted: (text) => completed = text,
                child: const HighlightedMarkdownText(
                  '```dart\nfinal x = 1;\nprint(x);\n```',
                ),
              ),
            ),
          ),
        );

        await tester.press(0, 0);
        await tester.sendMouseEvent(
          const MouseEvent(
            button: MouseButton.left,
            x: 31,
            y: 3,
            pressed: true,
            isMotion: true,
          ),
        );
        await tester.release(31, 3);

        expect(completed, isNotNull);
        expect(completed, contains('final x = 1;'));
        expect(completed, contains('print(x);'));
        expect(completed, isNot(contains('│')));
        expect(completed, isNot(contains('┌')));
        expect(completed, isNot(contains('└')));
        expect(completed, isNot(contains('┐')));
        expect(completed, isNot(contains('┘')));

        final topBorder = tester.terminalState.getCellAt(0, 0)!;
        final leftBorder = tester.terminalState.getCellAt(0, 1)!;
        final rightBorder = tester.terminalState.getCellAt(31, 1)!;
        final bottomBorder = tester.terminalState.getCellAt(0, 3)!;
        final codeText = tester.terminalState.getCellAt(2, 1)!;

        expect(topBorder.style.backgroundColor, theme.codeBlockBackground);
        expect(leftBorder.style.backgroundColor, theme.codeBlockBackground);
        expect(rightBorder.style.backgroundColor, theme.codeBlockBackground);
        expect(bottomBorder.style.backgroundColor, theme.codeBlockBackground);
        expect(
          codeText.style.backgroundColor,
          isNot(theme.codeBlockBackground),
        );
      }, size: const Size(32, 8));
    });

    // Regression: the code-block renderer used to split the source into
    // individual lines and highlight each one separately. That broke Dart's
    // `///` doc-comment grammar, because the `begin`/`while` pair only works
    // when the highlighter sees the full multi-line block. Symptom: the `///`
    // markers were highlighted but everything after them on the same line
    // silently disappeared.
    test('code block preserves /// doc comments', () async {
      await HighlightService.initialize();
      final theme = CruxThemeData.draculaFallback;
      await testNocterm('code block ///', (tester) async {
        const source =
            '```dart\n/// First line of doc.\n/// Second line.\nvoid main() {}\n```';
        await tester.pumpComponent(
          CruxTheme(
            data: theme,
            child: Container(
              width: 80,
              height: 24,
              child: HighlightedMarkdownText(source),
            ),
          ),
        );

        // The full comment text must survive (not just the `///` markers).
        expect(tester.terminalState, containsText('First line of doc.'));
        expect(tester.terminalState, containsText('Second line.'));
        expect(tester.terminalState, containsText('void main()'));
        // Every line of the code block should still have a gutter.
        final gutterCount = tester.terminalState
            .getText()
            .split('\n')
            .where((line) => line.startsWith('│ '))
            .length;
        expect(gutterCount, greaterThanOrEqualTo(3));

        // The `///` markers should be in the comment color (theme
        // `highlightComment`), not the default code-block text color.
        final commentMatches = tester.terminalState.findText(
          '/// First line of doc.',
        );
        expect(commentMatches, isNotEmpty);
        final firstCell = tester.terminalState.getCellAt(
          commentMatches.first.x,
          commentMatches.first.y,
        );
        expect(firstCell?.style.color, theme.highlightComment);
      });
    });

    test('blockquote renders with │ prefix', () async {
      await testNocterm('blockquote', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 10,
            child: HighlightedMarkdownText('> A quoted line'),
          ),
        );
        expect(tester.terminalState, containsText('│'));
        expect(tester.terminalState, containsText('quoted'));
        expect(tester.terminalState.containsText('>'), isFalse);
      });
    });

    test('link renders text and href without brackets', () async {
      await testNocterm('link', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 10,
            child: HighlightedMarkdownText(
              'Visit [Google](https://google.com)',
            ),
          ),
        );
        expect(tester.terminalState, containsText('Google'));
        expect(tester.terminalState, containsText('google.com'));
        expect(tester.terminalState.containsText('['), isFalse);
        expect(tester.terminalState.containsText(']('), isFalse);
      });
    });

    test('unordered list renders with bullet', () async {
      await testNocterm('ul', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 10,
            child: HighlightedMarkdownText('- Item one\n- Item two'),
          ),
        );
        expect(tester.terminalState, containsText('Item one'));
        expect(tester.terminalState, containsText('Item two'));
        expect(tester.terminalState, containsText('•'));
      });
    });

    test('ordered list renders with numbers', () async {
      await testNocterm('ol', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 10,
            child: HighlightedMarkdownText('1. First\n2. Second'),
          ),
        );
        expect(tester.terminalState, containsText('First'));
        expect(tester.terminalState, containsText('Second'));
      });
    });

    test('highlightText applies background color to matching excerpt', () async {
      await testNocterm('highlight', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 10,
            child: HighlightedMarkdownText(
              'The function returns early if the input buffer is empty and exits',
              highlightText: 'returns early if the input buffer is empty',
            ),
          ),
        );
        expect(tester.terminalState, containsText('returns early'));
        final matches = tester.terminalState.findText('returns early');
        expect(matches.length, greaterThan(0));
        final cell = tester.terminalState.getCellAt(
          matches.first.x,
          matches.first.y,
        );
        expect(cell?.style.backgroundColor, isNotNull);
      });
    });

    test('horizontal rule renders as dashes', () async {
      await testNocterm('hr', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 10,
            child: HighlightedMarkdownText('Above\n\n---\n\nBelow'),
          ),
        );
        expect(tester.terminalState, containsText('─'));
      });
    });

    test('image renders alt text', () async {
      await testNocterm('img', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 10,
            child: HighlightedMarkdownText('![Alt text](url)'),
          ),
        );
        expect(tester.terminalState, containsText('Alt text'));
      });
    });

    test('table renders with borders', () async {
      await testNocterm('table', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 24,
            child: HighlightedMarkdownText('| A | B |\n|---|---|\n| 1 | 2 |'),
          ),
        );
        expect(tester.terminalState, containsText('A'));
        expect(tester.terminalState, containsText('B'));
        expect(tester.terminalState, containsText('1'));
        expect(tester.terminalState, containsText('2'));
      });
    });

    test('table body rows alternate background colors', () async {
      final theme = CruxThemeData.draculaFallback;
      final headerBg = Color.alphaBlend(
        theme.surfaceVariant.withOpacity(0.5),
        theme.background,
      );
      final firstBodyBg = Color.alphaBlend(
        theme.surface.withOpacity(0.5),
        theme.background,
      );
      final secondBodyBg = Color.alphaBlend(
        theme.surfaceVariant.withOpacity(0.5),
        theme.background,
      );
      await testNocterm('table alternating rows', (tester) async {
        await tester.pumpComponent(
          NoctermApp(
            theme: theme.toTuiThemeData(),
            child: CruxTheme(
              data: theme,
              child: Container(
                width: 80,
                height: 24,
                child: const HighlightedMarkdownText(
                  '| A | B |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |',
                ),
              ),
            ),
          ),
        );

        final headerCell = tester.terminalState.getCellAt(2, 1)!;
        final firstBodyCell = tester.terminalState.getCellAt(2, 3)!;
        final secondBodyCell = tester.terminalState.getCellAt(2, 4)!;
        final firstBodyBorder = tester.terminalState.getCellAt(0, 3)!;
        final secondBodyBorder = tester.terminalState.getCellAt(0, 4)!;

        expect(headerCell.style.backgroundColor, headerBg);
        expect(firstBodyCell.style.backgroundColor, firstBodyBg);
        expect(secondBodyCell.style.backgroundColor, secondBodyBg);
        expect(firstBodyBorder.style.color, theme.outline);
        expect(secondBodyBorder.style.color, theme.outline);
        expect(firstBodyBorder.style.backgroundColor, theme.background);
        expect(secondBodyBorder.style.backgroundColor, theme.background);
      });
    });

    test(
      'TLDR ResponseLinkText renders tables with the same borders as the main '
      'response',
      () async {
        await testNocterm('tldr table', (tester) async {
          const input = '| A | B |\n|---|---|\n| 1 | 2 |';

          String mainBorder, tldrBorder;
          await tester.pumpComponent(
            Container(
              width: 80,
              height: 24,
              child: HighlightedMarkdownText(input),
            ),
          );
          mainBorder = tester.renderToString();

          await tester.pumpComponent(
            Container(
              width: 80,
              height: 24,
              child: const ResponseLinkText(markdownText: input),
            ),
          );
          tldrBorder = tester.renderToString();

          // Both renderers should produce the same box-drawing borders and
          // table content — the TLDR path was previously using a different
          // (incorrect) table renderer.
          expect(tldrBorder, contains('┌'));
          expect(tldrBorder, contains('┐'));
          expect(tldrBorder, contains('└'));
          expect(tldrBorder, contains('┘'));
          expect(tldrBorder, contains('├'));
          expect(tldrBorder, contains('┤'));
          expect(tldrBorder, contains('┬'));
          expect(tldrBorder, contains('┴'));
          expect(tldrBorder, contains('┼'));
          // Body cells must be present.
          expect(tldrBorder, contains('1'));
          expect(tldrBorder, contains('2'));
          // The two renderers should be byte-identical for the same input.
          expect(tldrBorder, equals(mainBorder));
        });
      },
    );
  });

  group('Button', () {
    test('renders label text', () async {
      await testNocterm('button renders', (tester) async {
        await tester.pumpComponent(Button(label: 'ClickMe', onPressed: () {}));
        expect(tester.terminalState, containsText('ClickMe'));
      });
    });

    test('triggers onPressed on tap', () async {
      await testNocterm('button tap', (tester) async {
        var pressed = false;
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 24,
            child: Button(label: 'Submit', onPressed: () => pressed = true),
          ),
        );
        expect(tester.terminalState, containsText('Submit'));

        await tester.tap(4, 0);
        expect(pressed, isTrue);
      });
    });
  });

  group('Toast', () {
    test('renders message text', () async {
      await testNocterm('toast renders', (tester) async {
        final toastKey = GlobalKey<ToastHubState>();
        await tester.pumpComponent(
          Container(width: 80, height: 24, child: ToastHub(key: toastKey)),
        );
        // No toast visible yet.
        expect(tester.terminalState, isNot(containsText('Model switched')));

        // Enqueue a toast and re-render.
        toastKey.currentState?.show('Model switched');
        await tester.pump();
        expect(tester.terminalState, containsText('Model switched'));
      });
    });

    test('renders error and status toasts with the right mode', () async {
      await testNocterm('toast modes render', (tester) async {
        final toastKey = GlobalKey<ToastHubState>();
        await tester.pumpComponent(
          Container(width: 80, height: 24, child: ToastHub(key: toastKey)),
        );
        toastKey.currentState?.show('something failed', mode: ToastMode.error);
        await tester.pump();
        expect(tester.terminalState, containsText('something failed'));

        // Wait for the 5 s error toast to elapse so we can show the next one.
        await tester.pump(const Duration(seconds: 6));
        toastKey.currentState?.show('all good', mode: ToastMode.status);
        await tester.pump();
        expect(tester.terminalState, containsText('all good'));
      });
    });
  });

  group('CommandOverlay', () {
    test('renders command list with selected item', () async {
      await testNocterm('command overlay renders', (tester) async {
        final commands = <SlashCommand>[
          SlashCommand(
            name: '/model',
            description: 'Switch model',
            params: ['name'],
          ),
          SlashCommand(name: '/new', description: 'Create new session'),
          SlashCommand(
            name: '/think',
            description: 'Toggle thinking',
            params: ['level'],
          ),
        ];

        await tester.pumpComponent(
          Container(
            width: 80,
            height: 24,
            child: CommandOverlay(
              commands: commands,
              selectedIndex: 0,
              scrollOffset: 0,
              maxVisible: 6,
            ),
          ),
        );

        expect(tester.terminalState, containsText('Commands'));
        expect(tester.terminalState, containsText('/model'));
        expect(tester.terminalState, containsText('/new'));
        expect(tester.terminalState, containsText('/think'));
      });
    });

    test('highlights selected command with > marker', () async {
      await testNocterm('command overlay selection', (tester) async {
        final commands = <SlashCommand>[
          SlashCommand(
            name: '/model',
            description: 'Switch model',
            params: ['name'],
          ),
          SlashCommand(name: '/new', description: 'Create new session'),
        ];

        await tester.pumpComponent(
          Container(
            width: 80,
            height: 24,
            child: CommandOverlay(
              commands: commands,
              selectedIndex: 1,
              scrollOffset: 0,
              maxVisible: 6,
            ),
          ),
        );

        final output = tester.renderToString(showBorders: true);
        expect(output, contains('>'));
      });
    });

    test('tap on command triggers callback', () async {
      await testNocterm('command overlay tap', (tester) async {
        var tappedIndex = -1;
        final commands = <SlashCommand>[
          SlashCommand(
            name: '/model',
            description: 'Switch model',
            params: ['name'],
          ),
          SlashCommand(name: '/new', description: 'Create new session'),
        ];

        await tester.pumpComponent(
          Container(
            width: 80,
            height: 24,
            child: CommandOverlay(
              commands: commands,
              selectedIndex: 0,
              scrollOffset: 0,
              maxVisible: 6,
              onTap: (index) => tappedIndex = index,
            ),
          ),
        );

        await tester.tap(3, 3);
        expect(tappedIndex, equals(0));
      });
    });
  });

  group('MessageBubble', () {
    test('renders message content', () async {
      await testNocterm('message bubble renders', (tester) async {
        final message = Message(
          id: 1,
          sessionId: 1,
          role: 'user',
          content: 'Hello world',
        );
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 24,
            child: MessageBubble(message: message),
          ),
        );
        expect(tester.terminalState, containsText('Hello world'));
      });
    });

    test('pairs each tool row with its own result', () async {
      await testNocterm('message bubble per-call result tap', (tester) async {
        final message = Message(
          id: 1,
          sessionId: 1,
          role: 'tool_call',
          content: '',
          toolCalls: const [
            ToolCallData(callId: 'call_1', name: 'write', input: {}),
            ToolCallData(callId: 'call_2', name: 'edit', input: {}),
          ],
        );
        final firstResult = Message(
          id: 2,
          sessionId: 1,
          role: 'tool',
          content: 'first result',
          toolCallId: 'call_1',
        );
        final secondResult = Message(
          id: 3,
          sessionId: 1,
          role: 'tool',
          content: 'second result',
          toolCallId: 'call_2',
        );

        String? tappedCallId;
        String? tappedContent;
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 10,
            child: MessageBubble(
              message: message,
              resultByCallId: {
                firstResult.toolCallId: firstResult,
                secondResult.toolCallId: secondResult,
              },
              onToolCallTap: (toolCall, pairedResult) {
                tappedCallId = toolCall.callId;
                tappedContent = pairedResult?.content;
              },
            ),
          ),
        );

        await tester.tap(2, 1);

        expect(tappedCallId, 'call_2');
        expect(tappedContent, 'second result');
      });
    });

    test('does not reuse another tool result when callId is missing', () async {
      await testNocterm('message bubble missing result no fallback', (
        tester,
      ) async {
        final message = Message(
          id: 1,
          sessionId: 1,
          role: 'tool_call',
          content: '',
          toolCalls: const [
            ToolCallData(
              callId: 'call_read',
              name: 'read',
              input: {'filePath': 'lib/a.dart'},
            ),
            ToolCallData(
              callId: 'call_edit',
              name: 'edit',
              input: {'filePath': 'lib/a.dart'},
            ),
          ],
        );
        final editGuardResult = Message(
          id: 2,
          sessionId: 1,
          role: 'tool',
          content: '[GUARD] Edit was BLOCKED — oldString does not match',
          toolCallId: 'call_edit',
        );

        await tester.pumpComponent(
          Container(
            width: 120,
            height: 10,
            child: MessageBubble(
              message: message,
              resultByCallId: {editGuardResult.toolCallId: editGuardResult},
            ),
          ),
        );

        expect(tester.terminalState, containsText('Read:'));
        expect(
          tester.terminalState,
          isNot(containsText('Read: lib/a.dart guard triggered')),
        );
        expect(tester.terminalState, containsText('Edit:'));
        expect(tester.terminalState, containsText('Edit: lib/a.dart guard'));
      });
    });
  });

  group('AI Agent Debug Workflow', () {
    test('keyboard interaction: type, send keys, read screen', () async {
      await testNocterm('keyboard workflow', (tester) async {
        await tester.pumpComponent(const _InputDemo());

        expect(tester.terminalState, containsText('Input:'));
        expect(tester.terminalState, containsText('Enter: 0'));

        await tester.sendKeyEvent(
          KeyboardEvent(logicalKey: LogicalKey.keyA, character: 'a'),
        );
        expect(tester.terminalState, containsText('Input: a'));

        await tester.enterText('hello');
        expect(tester.terminalState, containsText('Input: ahello'));

        await tester.sendEnter();
        expect(tester.terminalState, containsText('Enter: 1'));
      });
    });

    test('mouse interaction: hover and tap at coordinates', () async {
      await testNocterm('mouse workflow', (tester) async {
        var tapX = -1;
        var tapY = -1;

        await tester.pumpComponent(
          Container(
            width: 80,
            height: 24,
            child: GestureDetector(
              onTapDown: (details) {
                tapX = details.localPosition.dx.round();
                tapY = details.localPosition.dy.round();
              },
              child: Container(
                width: 20,
                height: 5,
                decoration: BoxDecoration(border: BoxBorder.all()),
                child: const Text('Tap me'),
              ),
            ),
          ),
        );

        expect(tester.terminalState, containsText('Tap me'));
        expect(tapX, equals(-1));

        await tester.tap(10, 3);
        expect(tapX, equals(10));
        expect(tapY, equals(3));
      });
    });

    test('renderToString gives visual screen for AI debugging', () async {
      await testNocterm('visual screen dump', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 24,
            child: Column(
              children: [
                Text('Header', style: TextStyle(color: Colors.cyan)),
                Expanded(child: Text('Body content')),
                Text('Footer'),
              ],
            ),
          ),
        );

        final visual = tester.renderToString(showBorders: true);
        expect(visual, contains('Header'));
        expect(visual, contains('Body content'));
        expect(visual, contains('Footer'));
      });
    });

    test('findState inspects component internal state', () async {
      await testNocterm('find state', (tester) async {
        await tester.pumpComponent(const _Counter());

        final state = tester.findState<_CounterState>();
        expect(state.count, equals(0));

        await tester.sendKey(LogicalKey.add);
        expect(state.count, equals(1));

        await tester.sendKey(LogicalKey.add);
        expect(state.count, equals(2));

        await tester.sendKey(LogicalKey.minus);
        expect(state.count, equals(1));

        expect(tester.terminalState, containsText('Count: 1'));
      });
    });

    test('getCellAt reads individual cell char and style', () async {
      await testNocterm('cell inspection', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 24,
            child: Text('ABC', style: TextStyle(color: Colors.red)),
          ),
        );

        final cell = tester.terminalState.getCellAt(0, 0);
        expect(cell!.char, equals('A'));
      });
    });
  });
}

class _Counter extends StatefulComponent {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int count = 0;

  @override
  Component build(BuildContext context) {
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        if (event.logicalKey == LogicalKey.add) {
          setState(() => count++);
          return true;
        }
        if (event.logicalKey == LogicalKey.minus) {
          setState(() => count--);
          return true;
        }
        return false;
      },
      child: Container(
        width: 80,
        height: 24,
        child: Center(child: Text('Count: $count')),
      ),
    );
  }
}

class _InputDemo extends StatefulComponent {
  const _InputDemo();

  @override
  State<_InputDemo> createState() => _InputDemoState();
}

class _InputDemoState extends State<_InputDemo> {
  String inputText = '';
  int enterCount = 0;

  @override
  Component build(BuildContext context) {
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        if (event.logicalKey == LogicalKey.enter) {
          setState(() => enterCount++);
          return true;
        }
        if (event.character != null) {
          setState(() => inputText += event.character!);
        }
        return false;
      },
      child: Container(
        width: 80,
        height: 24,
        child: Column(
          children: [Text('Input: $inputText'), Text('Enter: $enterCount')],
        ),
      ),
    );
  }
}
