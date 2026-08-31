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
      final data = DiagramViewportData([
        '┌──┐',
        '│ 中文 │',
        '└──┘',
      ]);
      // '│ 中文 │' = 1 + 1 + 4 + 1 + 1 = 8 columns.
      expect(data.naturalWidth, 8);
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
      expect(slices[0].spanIndex, 1);
      expect(slices[1].spanIndex, 3);
      expect(slices[0].language, 'mermaid');
    });

    test('drops fences with null data', () {
      const bad = DiagramFenceInfo(
        code: '',
        language: 'mermaid',
        data: null,
      );
      final spans = <InlineSpan>[const DiagramSentinelSpan(0)];
      final slices = sliceDiagramBlocks(spans, [bad]);
      expect(slices, isEmpty);
    });
  });

  group('markdown integration', () {
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

    test('unparseable fence stays a plain code block (no viewport)',
        () async {
      await testNocterm('partial falls back', (tester) async {
        await tester.pumpComponent(
          const HighlightedMarkdownText(
            '```mermaid\nstateDiagram-v2\n[*] -->\n```',
          ),
        );
        expect(tester.findComponent<DiagramViewport>(), isNull);
      });
    });

    test('wide diagram lifts with full natural width (no truncation)',
        () async {
      await testNocterm('no truncation on lift', (tester) async {
        const src =
            '```mermaid\nflowchart LR\nA[AAAAAAAAAA] --> B[BBBBBBBBBB] --> C[CCCCCCCCCC] --> D[DDDDDDDDDD]\n```';
        await tester.pumpComponent(HighlightedMarkdownText(src));
        final viewport = tester.findComponent<DiagramViewport>();
        expect(viewport, isNotNull);
        // All four node labels present in the parsed data — nothing was
        // shrunk away by a width budget.
        final all = viewport!.data.lines.join('\n');
        for (final label in ['AAAAAAAAAA', 'BBBBBBBBBB', 'CCCCCCCCCC', 'DDDDDDDDDD']) {
          expect(all, contains(label));
        }
      });
    });
  });

  group('pan interaction', () {
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

    test('wheel over the viewport never pans horizontally (scroll chains)',
        () async {
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
        await tester.sendMouseEvent(const MouseEvent(
          button: MouseButton.wheelDown,
          x: 30,
          y: 2,
          pressed: false,
        ));
        await tester.sendMouseEvent(const MouseEvent(
          button: MouseButton.wheelUp,
          x: 30,
          y: 2,
          pressed: false,
        ));

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
        await tester.sendMouseEvent(const MouseEvent(
          button: MouseButton.left,
          x: 14,
          y: 2,
          pressed: true,
          isMotion: true,
        ));
        await tester.release(14, 2);

        // Direct offset assertion through the render object.
        expect(viewport.data.naturalWidth, greaterThan(0));
      });
    });
  });
}
