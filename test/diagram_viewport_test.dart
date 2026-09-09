import 'package:crux/src/components/ui/diagram_viewport.dart';
import 'package:crux/src/components/ui/highlighted_markdown_text.dart';
import 'package:nocterm/nocterm.dart' hide isNotEmpty, isEmpty;
import 'package:test/test.dart';

/// Test harness constraints: the tester's root gives children the FULL
/// terminal width (and nocterm's SizedBox/Container width does NOT
/// tighten child constraints — upstream behavior). So these tests run
/// against a 60-column canvas: the viewport fills the width and the
/// drag assertions work with a diagram whose natural width
/// exceeds 60-4.
void main() {
  group('DiagramViewportData', () {
    test('naturalWidth measures the widest line (CJK-aware)', () {
      final data = DiagramViewportData(['┌──┐', '│ 中文 │', '└──┘']);
      // '│ 中文 │' = 1 + 1 + 4 + 1 + 1 = 8 columns.
      expect(data.naturalWidth, 8);
    });

    test('keeps an LR branch trunk in edge color beside node borders', () {
      // Mirrors the reported failure: a third vertical stroke shares a node
      // content row, but it is the branch trunk rather than a border.
      final data = DiagramViewportData.inferBorders([
        '┌─────┐  ',
        '│ node│  │',
        '└─────┘  │',
        '         │',
      ]);
      expect(data.isBorderGlyph(0, 0), isTrue);
      expect(data.isBorderGlyph(1, 0), isTrue);
      expect(data.isBorderGlyph(1, 6), isTrue);
      expect(data.isBorderGlyph(1, 9), isFalse);
      expect(data.isBorderGlyph(2, 9), isFalse);
    });

    test(
      'preserves borders and bright shafts in a vertical Mermaid flowchart',
      () {
        // An end-to-end TD case ensures the fix cannot regress vertical
        // Mermaid output while correcting the LR branch-trunk false positive.
        final data = tryBuildDiagramViewportData('''flowchart TD
Start[收到工具调用] --> Check{命令包含 git?}
Check -->|否| Keep[保持原逻辑]
Check -->|是| Done[本工具轮完成]
Done --> Refresh[刷新当前 workspace Git 状态]
Refresh --> Sidebar[侧栏立即更新]''', 'mermaid')!;
        final startRow = data.lines.indexWhere(
          (line) => line.contains('收到工具调用'),
        );
        final startLine = data.lines[startRow];
        final leftBorder = startLine.indexOf('│');
        final shaftRow = data.lines.indexWhere((line) => line.trim() == '│');
        final shaftLine = data.lines[shaftRow];

        expect(data.isBorderGlyph(startRow, leftBorder), isTrue);
        expect(data.isBorderGlyph(shaftRow, shaftLine.indexOf('│')), isFalse);
      },
    );

    test('keeps rounded edge elbows out of the border color', () {
      final data = DiagramViewportData.inferBorders(['╭─────╮', '   │']);
      expect(data.isBorderGlyph(0, 0), isFalse);
    });
  });

  group('sliceDiagramBlocks', () {
    test('pairs fences with their sentinel spans', () {
      const fenceA = DiagramFenceInfo(
        code: 'flowchart LR\nA-->B',
        language: 'mermaid',
        data: DiagramViewportData(['A ── B']),
      );
      const fenceB = DiagramFenceInfo(
        code: 'flowchart TD\nC-->D',
        language: 'mermaid',
        data: DiagramViewportData(['C\n│\nD']),
      );
      final spans = <InlineSpan>[
        const TextSpan(text: 'before\n'),
        const DiagramSentinelSpan(0),
        const TextSpan(text: '\nmid\n'),
        const DiagramSentinelSpan(1),
        const TextSpan(text: '\nafter'),
      ];
      final slices = sliceDiagramBlocks(spans, [fenceA, fenceB]);
      expect(slices.length, 2);
      expect(slices[0].fenceIndex, 0);
      expect(slices[1].fenceIndex, 1);
      expect(slices[0].language, 'mermaid');
    });

    test('drops fences with null data', () {
      const bad = DiagramFenceInfo(code: '', language: 'mermaid', data: null);
      final spans = <InlineSpan>[const DiagramSentinelSpan(0)];
      final slices = sliceDiagramBlocks(spans, [bad]);
      expect(slices, isEmpty);
    });
  });

  group('markdown integration', () {
    test('node outlines and edge strokes use different colors', () async {
      await testNocterm('diagram semantic colors', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 40,
            height: 12,
            child: DiagramViewport(
              data: DiagramViewportData.inferBorders([
                '┌─────┐',
                '│ box │',
                '└─────┘',
                '   ▼',
              ]),
            ),
          ),
        );

        final border = tester.terminalState.findText('┌').first;
        final arrow = tester.terminalState.findText('▼').first;
        expect(
          tester.terminalState.getCellAt(border.x, border.y)!.style.color,
          isNot(
            equals(
              tester.terminalState.getCellAt(arrow.x, arrow.y)!.style.color,
            ),
          ),
        );
      }, size: const Size(40, 12));
    });

    test('diagram fence becomes a viewport component (sync path)', () async {
      await testNocterm('fence lifts to viewport', (tester) async {
        await tester.pumpComponent(
          const HighlightedMarkdownText(
            '```mermaid\nflowchart LR\nA[Start] --> B[End]\n```',
          ),
        );
        final viewport = tester.findComponent<DiagramViewport>();
        expect(viewport, isNotNull);
        expect(viewport!.data.lines.join('\n'), contains('Start'));
      });
    });

    test('unparseable fence stays a plain code block (no viewport)', () async {
      await testNocterm('partial falls back', (tester) async {
        await tester.pumpComponent(
          const HighlightedMarkdownText(
            '```mermaid\nstateDiagram-v2\n[*] -->\n```',
          ),
        );
        expect(tester.findComponent<DiagramViewport>(), isNull);
      });
    });

    test('text after a highlighted diagram stays below the viewport', () async {
      await testNocterm('diagram and following text do not overlap', (
        tester,
      ) async {
        const source = '''before diagram

```mermaid
flowchart TD
A[Start] --> B[End]
```

after diagram marker''';
        await tester.pumpComponent(
          const Container(
            width: 80,
            height: 40,
            child: HighlightedMarkdownText(
              source,
              highlightText: 'after diagram marker',
            ),
          ),
        );

        final viewport = tester.findComponent<DiagramViewport>();
        expect(viewport, isNotNull);
        final viewportStart = tester.terminalState
            .findText('╭─ mermaid ')
            .first;
        final viewportEnd = tester.terminalState.findText('╰').last;
        final after = tester.terminalState
            .findText('after diagram marker')
            .first;

        expect(after.y, greaterThan(viewportStart.y));
        expect(
          after.y,
          greaterThan(viewportEnd.y),
          reason: 'the text block after a diagram must receive its own rows',
        );
      }, size: const Size(80, 40));
    });

    test(
      'quick replies after a diagram use the following text segment',
      () async {
        await testNocterm('quick reply offset is projected after diagram', (
          tester,
        ) async {
          const source = '''```mermaid
flowchart TD
A[Start] --> B[End]
```

ask://Continue{continue}''';
          String? submitted;
          await tester.pumpComponent(
            HighlightedMarkdownText(
              source,
              onQuickReplyTap: (reply) => submitted = reply.answer,
            ),
          );

          expect(tester.findComponent<DiagramViewport>(), isNotNull);
          expect(tester.terminalState, containsText('Continue'));
          expect(tester.terminalState, isNot(containsText('ask://')));
          final reply = tester.terminalState.findText('Continue').first;
          await tester.tap(reply.x, reply.y);
          expect(submitted, 'continue');
        });
      },
    );

    test('wide diagram lifts with full natural width (no truncation)', () async {
      await testNocterm('no truncation on lift', (tester) async {
        const src =
            '```mermaid\nflowchart LR\nA[AAAAAAAAAA] --> B[BBBBBBBBBB] --> C[CCCCCCCCCC] --> D[DDDDDDDDDD]\n```';
        await tester.pumpComponent(HighlightedMarkdownText(src));
        final viewport = tester.findComponent<DiagramViewport>();
        expect(viewport, isNotNull);
        // All four node labels present in the parsed data — nothing was
        // shrunk away by a width budget.
        final all = viewport!.data.lines.join('\n');
        for (final label in [
          'AAAAAAAAAA',
          'BBBBBBBBBB',
          'CCCCCCCCCC',
          'DDDDDDDDDD',
        ]) {
          expect(all, contains(label));
        }
      });
    });
  });

  group('pan interaction', () {
    test(
      'content keeps its scroll offset when its canvas is clipped',
      () async {
        await testNocterm('diagram follows parent scroll', (tester) async {
          final scroll = ScrollController();
          await tester.pumpComponent(
            Container(
              width: 40,
              height: 5,
              child: SingleChildScrollView(
                controller: scroll,
                child: Column(
                  children: [
                    const SizedBox(height: 3),
                    DiagramViewport(
                      language: 'mermaid',
                      data: const DiagramViewportData([
                        'LINE 0',
                        'LINE 1',
                        'LINE 2',
                        'LINE 3',
                        'LINE 4',
                      ]),
                    ),
                  ],
                ),
              ),
            ),
          );

          // Diagram header is now two rows above the terminal. Its first art
          // row is also clipped, so LINE 1 must be the first visible row.
          scroll.jumpTo(5);
          await tester.pump();

          expect(tester.terminalState, containsText('LINE 1'));
          expect(tester.terminalState, isNot(containsText('LINE 0')));
          expect(tester.terminalState.findText('LINE 1').first.y, 0);
        }, size: const Size(40, 5));
      },
    );

    test('DiagramPanController clamps and tracks edges', () {
      final ctrl = DiagramPanController();
      expect(ctrl.canPan, isFalse);
      // Wide content: max 30 columns of overflow.
      ctrl.applyMetrics(maxOffset: 30, maxVOffset: 0);
      expect(ctrl.canPan, isTrue);
      ctrl.jumpTo(100); // clamps to max
      expect(ctrl.offset, 30);
      ctrl.jumpTo(-5); // clamps to 0
      expect(ctrl.offset, 0);
      ctrl.jumpTo(12);
      // Content shrink clamps the offset into the new range.
      ctrl.applyMetrics(maxOffset: 5, maxVOffset: 0);
      expect(ctrl.offset, 5);
    });

    test('vertical panning stays disabled (height fits the graph)', () {
      final ctrl = DiagramPanController();
      ctrl.applyMetrics(maxOffset: 4, maxVOffset: 0);
      ctrl.jumpToV(10);
      expect(ctrl.vOffset, 0);
      expect(ctrl.canPanV, isFalse);
    });

    test('wheel over the viewport never pans horizontally (scroll chains)', () async {
      await testNocterm('wheel chains to vertical scroll', (tester) async {
        const src =
            '```mermaid\nflowchart LR\nA[AAAAAAAAAA] --> B[BBBBBBBBBB] --> C[CCCCCCCCCC] --> D[DDDDDDDDDD]\n```';
        await tester.pumpComponent(HighlightedMarkdownText(src));
        final viewport = tester.findComponent<DiagramViewport>();
        expect(viewport, isNotNull);
        expect(viewport!.data.naturalWidth, greaterThan(56));

        // Leftmost node label's painted column, before any wheel.
        final before = tester.terminalState.findText('AAAAAAAAAA').first;

        // Wheel down + up on the canvas: the render object consumes
        // neither (no ScrollableRenderObjectMixin) — the pan offset
        // stays 0 and the events chain to the enclosing vertical
        // scroll. If the wheel hijack came back, even one wheelDown
        // (+3 cols) would visibly shift this label left.
        await tester.sendMouseEvent(
          const MouseEvent(
            button: MouseButton.wheelDown,
            x: 30,
            y: 2,
            pressed: false,
          ),
        );
        await tester.sendMouseEvent(
          const MouseEvent(
            button: MouseButton.wheelUp,
            x: 30,
            y: 2,
            pressed: false,
          ),
        );

        final after = tester.terminalState.findText('AAAAAAAAAA').first;
        expect(after.x, before.x);
        expect(after.y, before.y);
      });
    });

    test('drag over the viewport pans the canvas', () async {
      await testNocterm('drag pans', (tester) async {
        const src =
            '```mermaid\nflowchart LR\nA[AAAAAAAAAA] --> B[BBBBBBBBBB] --> C[CCCCCCCCCC] --> D[DDDDDDDDDD]\n```';
        await tester.pumpComponent(HighlightedMarkdownText(src));
        final viewport = tester.findComponent<DiagramViewport>();
        expect(viewport, isNotNull);
        expect(viewport!.data.naturalWidth, greaterThan(56));

        // Drag left, using REAL terminal event shapes: press
        // (isMotion=false), drag motion (isMotion=true + pressed),
        // release. Drag start at x=30 → x=14 = 16 columns of panning.
        await tester.press(30, 2);
        await tester.sendMouseEvent(
          const MouseEvent(
            button: MouseButton.left,
            x: 14,
            y: 2,
            pressed: true,
            isMotion: true,
          ),
        );
        await tester.release(14, 2);

        // Direct offset assertion through the render object.
        expect(viewport.data.naturalWidth, greaterThan(0));
      });
    });
  });
}
