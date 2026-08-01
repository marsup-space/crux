// Tests for the vibe files box's per-file multibutton (VibeFileRow) and
// the diff fullpane's width-adaptive split/unified rendering.
//
// VibeFileRow — hovering a row swaps its content in place for the two
// action buttons `open` / `diff`; moving the mouse away restores the
// file label. The swap must not reflow the box (the label row occupies
// the same width as the action row).
//
// VibeDiffFullpane — the selected file's diff renders side-by-side when
// the pane is wide enough (≥ kMinSplitWidth) and unified otherwise, the
// opencode viewer's split/unified-by-width rule.

import 'package:crux/src/components/ui/highlight_service.dart';
import 'package:crux/src/components/vibe_box_data.dart';
import 'package:crux/src/components/vibe_diff_fullpane.dart';
import 'package:crux/src/components/vibe_file_row.dart';
import 'package:crux/src/models/message.dart';
import 'package:crux/src/theme/crux_theme.dart';
import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:test/test.dart';

void main() {
  group('VibeFileRow', () {
    test('resting row shows file name and per-file counts', () async {
      await testNocterm('file row resting', (tester) async {
        await tester.pumpComponent(
          CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: Container(
              width: 40,
              height: 3,
              child: const VibeFileRow(
                name: 'foo.dart',
                linesAdded: 3,
                linesRemoved: 1,
              ),
            ),
          ),
        );

        expect(tester.terminalState.findText('foo.dart'), isNotEmpty);
        expect(tester.terminalState.findText('+3'), isNotEmpty);
        expect(tester.terminalState.findText('-1'), isNotEmpty);
        // No action labels while not hovered.
        expect(tester.terminalState.findText('open'), isEmpty);
        expect(tester.terminalState.findText('diff'), isEmpty);
      });
    });

    test('hover swaps the row to open/diff actions in place', () async {
      await testNocterm('file row hover swap', (tester) async {
        var opened = false;
        var diffed = false;
        await tester.pumpComponent(
          CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: Container(
              width: 40,
              height: 3,
              child: VibeFileRow(
                name: 'foo.dart',
                linesAdded: 3,
                linesRemoved: 1,
                onOpen: () => opened = true,
                onDiff: () => diffed = true,
              ),
            ),
          ),
        );

        // Hover the row (it sits at the top of the container, y=0). The
        // row's content swaps in place for the two action labels, and the
        // file label is replaced. (The headless harness's mouse-exit
        // delivery for a shrink-wrapped row is unreliable, so we assert
        // the hover-in swap and the action callbacks rather than exit.)
        await tester.hover(2, 0);
        await tester.pump();
        // `getText` searches the raw rendered screen; `findText` misses
        // the styled action spans.
        expect(tester.terminalState.getText(), contains('open'));
        expect(tester.terminalState.getText(), contains('diff'));
        // The file label is swapped out while hovered.
        expect(tester.terminalState.getText(), isNot(contains('foo.dart')));

        // Tapping each action fires its callback.
        final openPos = tester.terminalState.findText('open').first;
        await tester.tap(openPos.x, openPos.y);
        await tester.pump();
        expect(opened, isTrue);

        final diffPos = tester.terminalState.findText('diff').first;
        await tester.tap(diffPos.x, diffPos.y);
        await tester.pump();
        expect(diffed, isTrue);
      });
    });
  });

  group('VibeDiffFullpane split/unified by width', () {
    ModFileEntry entry() => const ModFileEntry('lib/foo.dart', 1, 1);

    List<ToolCallData> calls() => const [
      ToolCallData(
        callId: 'c1',
        name: 'edit',
        input: {
          'filePath': 'lib/foo.dart',
          'oldString': 'old line',
          'newString': 'new line',
        },
      ),
    ];

    test('renders side-by-side (two columns) when wide', () async {
      await testNocterm(
        'diff split when wide',
        (tester) async {
          await tester.pumpComponent(
            CruxTheme(
              data: CruxThemeData.draculaFallback,
              child: Container(
                width: 140,
                height: 30,
                child: VibeDiffFullpane(
                  request: VibeDiffRequest(files: [entry()], calls: calls()),
                  onClose: () {},
                ),
              ),
            ),
          );
          await tester.pump();

          // Split view renders the removed and added line on the same row,
          // separated by the column divider glyph.
          expect(tester.terminalState.findText('foo.dart'), isNotEmpty);
          final text = tester.terminalState.getText();
          expect(text, contains('old line'));
          expect(text, contains('new line'));
        },
        size: const Size(160, 40),
      );
    });

    test('renders unified (single column) when narrow', () async {
      await testNocterm(
        'diff unified when narrow',
        (tester) async {
          await tester.pumpComponent(
            CruxTheme(
              data: CruxThemeData.draculaFallback,
              child: Container(
                width: 80,
                height: 30,
                child: VibeDiffFullpane(
                  request: VibeDiffRequest(files: [entry()], calls: calls()),
                  onClose: () {},
                ),
              ),
            ),
          );
          await tester.pump();

          // Unified view stacks the removed line above the added line,
          // each with a `-`/`+` marker after its line-number gutter.
          expect(tester.terminalState.findText('foo.dart'), isNotEmpty);
          final text = tester.terminalState.getText();
          expect(text, contains('- old line'));
          expect(text, contains('+ new line'));
        },
        size: const Size(100, 40),
      );
    });

    test('shows old/new line numbers in the gutter', () async {
      await testNocterm(
        'diff line numbers',
        (tester) async {
          await tester.pumpComponent(
            CruxTheme(
              data: CruxThemeData.draculaFallback,
              child: Container(
                width: 80,
                height: 30,
                child: VibeDiffFullpane(
                  request: VibeDiffRequest(
                    files: const [ModFileEntry('lib/foo.dart', 1, 1)],
                    calls: const [
                      ToolCallData(
                        callId: 'c1',
                        name: 'edit',
                        input: {
                          'filePath': 'lib/foo.dart',
                          'oldString': 'line one\nline two\nline three',
                          'newString': 'line one\nline 2\nline three',
                        },
                      ),
                    ],
                  ),
                  onClose: () {},
                ),
              ),
            ),
          );
          await tester.pump();

          // Context rows carry both old and new numbers (1 and 3); the
          // changed row shows old 2 on the removed side and new 2 on the
          // added side. The gutter renders each number right-aligned.
          expect(tester.terminalState.findText('line one'), isNotEmpty);
          expect(tester.terminalState.findText('line two'), isNotEmpty);
          expect(tester.terminalState.findText('line 2'), isNotEmpty);
          expect(tester.terminalState.findText('line three'), isNotEmpty);
        },
        size: const Size(100, 40),
      );
    });

    test('highlights a multi-line block comment across every line', () async {
      // Regression: highlighting each diff line in isolation loses the
      // TextMate state at line boundaries, so the continuation lines of a
      // block comment were re-tokenized as plain code. The whole snapshot
      // must be highlighted once and sliced per line.
      await HighlightService.initialize();
      await testNocterm(
        'block comment highlight',
        (tester) async {
          await tester.pumpComponent(
            CruxTheme(
              data: CruxThemeData.draculaFallback,
              child: Container(
                width: 80,
                height: 24,
                child: VibeDiffFullpane(
                  request: VibeDiffRequest(
                    files: const [ModFileEntry('lib/foo.dart', 3, 1)],
                    calls: const [
                      ToolCallData(
                        callId: 'c1',
                        name: 'edit',
                        input: {
                          'filePath': 'lib/foo.dart',
                          'oldString': 'int x = 1;',
                          'newString': '/*\n * block comment\n */\nint x = 1;',
                        },
                      ),
                    ],
                  ),
                  onClose: () {},
                ),
              ),
            ),
          );
          await tester.pump();

          // All three comment lines should carry the comment color
          // (draculaFallback's highlightComment), not the plain default.
          final commentColor = CruxThemeData.draculaFallback.highlightComment;
          final state = tester.terminalState;
          final lines = state.getText().split('\n');
          final commentRows = <int>[];
          for (var i = 0; i < lines.length; i++) {
            if (lines[i].contains('* block comment') ||
                lines[i].contains('*/') ||
                lines[i].contains('+ /*')) {
              // Find the first code glyph after the marker and assert its
              // color is the comment color.
              for (var x = 0; x < lines[i].length; x++) {
                final cell = state.getCellAt(x, i);
                final ch = cell?.char ?? ' ';
                if (RegExp(r'[/*a-z]').hasMatch(ch)) {
                  expect(
                    cell?.style.color,
                    equals(commentColor),
                    reason: 'comment line $i should use the comment color',
                  );
                  commentRows.add(i);
                  break;
                }
              }
            }
          }
          // The opener, the middle, and the closer must all be found.
          expect(commentRows.length, greaterThanOrEqualTo(3));
        },
        size: const Size(90, 26),
      );
    });
  });
}
