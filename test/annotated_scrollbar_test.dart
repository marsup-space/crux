// Tests for the annotated scrollbar. Covers both the existing
// thumb-rendering behavior and the new app-wide hint integration
// (the marker tooltip now flows through [HintOverlay] instead of
// being painted by the scrollbar's render object).

import 'package:crux/src/components/annotated_scrollbar.dart';
import 'package:nocterm/nocterm.dart';
import 'package:test/test.dart';

/// A stub [AnnotatedScrollbar] whose marker offsets come from a plain
/// map (row → offset), proving the base class paints markers at
/// whatever offset the subclass resolves and jumps there on click —
/// independent of any `RenderListViewport`.
class _StubScrollbar extends AnnotatedScrollbar {
  final Map<int, double> offsets;

  const _StubScrollbar({
    required super.child,
    super.controller,
    super.thumbVisibility,
    super.markers,
    required this.offsets,
  });

  @override
  double? markerContentOffset(ScrollbarMarker marker) =>
      offsets[marker.itemIndex];
}

void main() {
  // Reset the [HintController] singleton between tests so a stale
  // hint from a previous test never leaks into the next one.
  setUp(() => HintController.instance.hide());
  tearDown(() => HintController.instance.hide());

  test('base class paints markers at the subclass-resolved offsets', () async {
    await testNocterm('stub resolver paints + jumps', (tester) async {
      final controller = ScrollController();

      await tester.pumpComponent(
        Container(
          width: 20,
          height: 10,
          child: _StubScrollbar(
            controller: controller,
            thumbVisibility: true,
            // Marker keyed on itemIndex 5 → content offset 40.0, which
            // is 40% of the 100-row content → mid-track.
            offsets: const {5: 40.0},
            markers: const [
              ScrollbarMarker(
                itemIndex: 5,
                color: Color(0xFF50FA7B),
                label: 'stub',
              ),
            ],
            child: SingleChildScrollView(
              controller: controller,
              child: Text('x\n' * 100),
            ),
          ),
        ),
      );

      // The marker should render on the track.
      int? markerRow;
      for (var y = 0; y < 10; y++) {
        if (tester.terminalState.getCellAt(19, y)?.char == '◆') {
          markerRow = y;
          break;
        }
      }
      expect(
        markerRow,
        isNotNull,
        reason: 'marker should paint at the resolved offset',
      );

      // Click it — the base should jump the controller to the resolved
      // offset (40.0, clamped to maxScrollExtent). The realistic
      // sequence: unpressed hover first (seeds `_isLeftButtonDown=false`
      // via onHintEnter), then press + release — the MouseTracker parks
      // the first press and only dispatches it once the release arrives
      // (see mouse_tracker.dart: _pendingPress), so a bare pressed
      // event never reaches onHintHover.
      expect(controller.offset, 0.0);
      final my = markerRow!;
      const mx = 19;
      await tester.hover(mx, my);
      await tester.press(mx, my);
      await tester.release(mx, my);
      await tester.pump();
      // The jump target is markerContentOffset → 40.0, clamped to the
      // viewport's maxScrollExtent (content 100 rows − viewport 8 rows
      // of track content = 92 max).
      expect(controller.offset, greaterThan(0.0));
    }, size: const Size(20, 10));
  });

  test('thumb is at least two lines tall for long content', () async {
    await testNocterm('annotated scrollbar minimum thumb height', (
      tester,
    ) async {
      final controller = ScrollController();

      await tester.pumpComponent(
        Container(
          width: 20,
          height: 10,
          child: ChatScrollbar(
            controller: controller,
            thumbVisibility: true,
            child: ListView.builder(
              controller: controller,
              itemCount: 100,
              itemBuilder: (context, index) => Text('Line $index'),
            ),
          ),
        ),
      );

      final thumbCells = [
        for (var y = 0; y < 10; y++)
          if (tester.terminalState.getCellAt(19, y)?.char == '█') y,
      ];

      expect(thumbCells, hasLength(2));
    }, size: const Size(20, 10));
  });

  test(
    'hovering a marker registers a tooltip on the app-wide controller',
    () async {
      // Wrapping the scrollbar in a [HintOverlay] is what makes the
      // tooltip visible to the user; without it the controller still
      // records the hint but nothing is drawn on screen.
      await testNocterm(
        'annotated scrollbar marker pushes a hint to the controller',
        (tester) async {
          final controller = ScrollController();

          // 20 wide × 10 tall: the scrollbar lives at column 19, the
          // content area at columns 0–18. The marker for item 0 sits
          // at the top of the track — but the thumb is also at the
          // top when the scroll offset is zero, so item 0 is hidden
          // by the thumb. We use item 50 instead, which lands roughly
          // in the middle of the track (well below the thumb).
          await tester.pumpComponent(
            Container(
              width: 20,
              height: 10,
              child: HintOverlay(
                child: ChatScrollbar(
                  controller: controller,
                  thumbVisibility: true,
                  markers: const [
                    ScrollbarMarker(
                      itemIndex: 50,
                      color: Color(0xFF50FA7B),
                      label: 'User prompt',
                    ),
                  ],
                  child: ListView.builder(
                    controller: controller,
                    itemCount: 100,
                    itemBuilder: (context, index) => Text('Line $index'),
                  ),
                ),
              ),
            ),
          );

          // Sanity: no hint yet.
          expect(HintController.instance.activeHint, isNull);

          // Walk the cursor down the scrollbar track to discover
          // where the marker actually rendered, then hover there.
          // (Hardcoding a row is fragile: the exact position depends
          // on the track height and the marker's offset fraction.)
          int? markerRow;
          for (var y = 0; y < 10; y++) {
            final ch = tester.terminalState.getCellAt(19, y)?.char;
            if (ch == '◆') {
              markerRow = y;
              break;
            }
          }
          expect(
            markerRow,
            isNotNull,
            reason: 'expected to find the marker on the track',
          );

          await tester.sendMouseEvent(
            MouseEvent(
              button: MouseButton.left,
              x: 19,
              y: markerRow!,
              pressed: false,
            ),
          );
          await tester.pump();

          // The hint is registered and visible immediately (the
          // scrollbar uses [Duration.zero] for its delay).
          expect(HintController.instance.activeHint, 'User prompt');
          expect(HintController.instance.visible, isTrue);
          // The hint's foreground color matches the marker's color.
          expect(HintController.instance.activeColor, const Color(0xFF50FA7B));
        },
        size: const Size(20, 10),
      );
    },
  );

  test('releasing a thumb drag restores hover delivery to content', () async {
    await testNocterm('annotated scrollbar releases mouse capture', (
      tester,
    ) async {
      final controller = ScrollController();
      var contentHovers = 0;

      await tester.pumpComponent(
        Container(
          width: 20,
          height: 10,
          child: ChatScrollbar(
            controller: controller,
            thumbVisibility: true,
            child: ListView.builder(
              controller: controller,
              itemCount: 100,
              itemBuilder: (context, index) => MouseRegion(
                onHover: (_) => contentHovers++,
                child: Text('Line $index'),
              ),
            ),
          ),
        ),
      );

      int? thumbRow;
      for (var y = 0; y < 10; y++) {
        if (tester.terminalState.getCellAt(19, y)?.char == '█') {
          thumbRow = y;
          break;
        }
      }
      expect(thumbRow, isNotNull, reason: 'expected to find the thumb');

      await tester.press(19, thumbRow!);
      await tester.sendMouseEvent(
        MouseEvent(
          button: MouseButton.left,
          x: 19,
          y: (thumbRow + 2).clamp(0, 9),
          pressed: true,
          isMotion: true,
        ),
      );
      await tester.release(0, thumbRow);

      final hoversAfterRelease = contentHovers;
      await tester.hover(0, thumbRow);

      expect(
        contentHovers,
        greaterThan(hoversAfterRelease),
        reason: 'content should receive hover events after scrollbar drag ends',
      );
    }, size: const Size(20, 10));
  });

  test('a marker without a label does not register a hint', () async {
    await testNocterm('unlabeled marker leaves the hint controller quiet', (
      tester,
    ) async {
      final controller = ScrollController();

      await tester.pumpComponent(
        Container(
          width: 20,
          height: 10,
          child: HintOverlay(
            child: ChatScrollbar(
              controller: controller,
              thumbVisibility: true,
              markers: const [
                // No `label` field — this marker should not
                // contribute a hint.
                ScrollbarMarker(itemIndex: 0, color: Color(0xFF50FA7B)),
              ],
              child: ListView.builder(
                controller: controller,
                itemCount: 100,
                itemBuilder: (context, index) => Text('Line $index'),
              ),
            ),
          ),
        ),
      );

      await tester.sendMouseEvent(
        MouseEvent(button: MouseButton.left, x: 19, y: 1, pressed: false),
      );
      await tester.pump();

      // The state overrode hintContent to return null for unlabeled
      // markers, so the controller should still have no hint.
      expect(HintController.instance.activeHint, isNull);
    }, size: const Size(20, 10));
  });

  test('tooltip is positioned correctly even when the HintOverlay '
      'is not at the terminal origin', () async {
    // Regression test for a coordinate-system mismatch: the scroll
    // bar's tooltip position used to be returned in absolute terminal
    // cell coordinates, but the [HintOverlay] reads the value as a
    // [Stack]-local offset and adds its own paint offset on top.
    // When the overlay sat at the terminal origin (the normal case)
    // the two interpretations agreed and the bug was invisible. As
    // soon as something between the terminal root and the overlay
    // introduced a non-zero paint offset — here, a 3-cell padding
    // on the outer [Container] — the tooltip was shifted by that
    // extra offset and landed in the wrong place.
    await testNocterm('tooltip stays anchored to the marker', (tester) async {
      final controller = ScrollController();

      // 40 wide × 20 tall, with a 3-cell padding so the overlay's
      // paint offset is (3, 3) in the terminal — not (0, 0). The
      // scrollbar still ends up at column 36, the marker for item
      // 50 ends up somewhere in the middle of the track.
      await tester.pumpComponent(
        Container(
          width: 40,
          height: 20,
          padding: const EdgeInsets.all(3),
          child: HintOverlay(
            child: ChatScrollbar(
              controller: controller,
              thumbVisibility: true,
              markers: const [
                ScrollbarMarker(
                  itemIndex: 50,
                  color: Color(0xFF50FA7B),
                  label: 'User prompt',
                ),
              ],
              child: ListView.builder(
                controller: controller,
                itemCount: 100,
                itemBuilder: (context, index) => Text('Line $index'),
              ),
            ),
          ),
        ),
      );

      // Find the marker.
      int? markerRow, markerCol;
      for (var y = 0; y < 20; y++) {
        for (var x = 0; x < 40; x++) {
          if (tester.terminalState.getCellAt(x, y)?.char == '◆') {
            markerRow = y;
            markerCol = x;
            break;
          }
        }
        if (markerRow != null) break;
      }
      expect(markerRow, isNotNull, reason: 'expected the marker to render');

      await tester.sendMouseEvent(
        MouseEvent(
          button: MouseButton.left,
          x: markerCol!,
          y: markerRow!,
          pressed: false,
        ),
      );
      await tester.pump();

      // The scrollbar uses [HintPlacement.left], so the tooltip
      // sits to the left of the marker. The resolver centers the
      // tooltip on the marker's row vertically, so the corner
      // is at the marker's row ± a few cells. We just verify the
      // corner is on screen and to the left of the marker — the
      // exact vertical offset is implementation-defined and
      // allowed to drift as the resolver evolves.
      final (int, int)? corner = _findCell(tester, 40, 20, '╭');
      expect(corner, isNotNull, reason: 'expected the tooltip to be painted');
      final (cornerCol, cornerRow) = corner!;
      expect(
        cornerCol,
        lessThan(markerCol),
        reason: 'tooltip should be to the left of the scrollbar',
      );
      expect(
        cornerRow,
        inInclusiveRange(markerRow - 6, markerRow + 6),
        reason: 'tooltip should be vertically near the marker row',
      );
    }, size: const Size(40, 20));
  });

  test('tooltip anchors to the marker even when a left pane shifts the chat '
      'rightward (plan-view layout)', () async {
    // Regression test for the plan-view tooltip bug: the real app puts
    // the [HintOverlay] at the root (bin/crux.dart) and, when plan mode
    // is on, lays the chat pane out in a Row AFTER the plan doc pane —
    // so the chat scrollbar sits at a non-zero global column. Anchoring
    // from local coordinates shifted the tooltip left by exactly the
    // first pane's width, drawing it over the plan pane. The fix makes
    // [RenderAnnotatedScrollbar.markerSourceBounds] translate to global
    // coordinates (same frame the mouse events/hit-testing use), so the
    // tooltip must now hug the marker regardless of the scrollbar's
    // terminal position.
    await testNocterm('proposal: tooltip tracks shifted scrollbar', (
      tester,
    ) async {
      final controller = ScrollController();

      // Emulate the plan split: a 20-col placeholder pane at the left,
      // a 1-col divider, then the chat pane with its scrollbar. The
      // [HintOverlay] (Stack anchored at the terminal origin) wraps the
      // whole row — exactly like the app root.
      await tester.pumpComponent(
        HintOverlay(
          child: Row(
            children: [
              const SizedBox(width: 20, child: Text('plan')),
              const SizedBox(width: 1, child: Text('│')),
              Expanded(
                child: ChatScrollbar(
                  controller: controller,
                  thumbVisibility: true,
                  markers: const [
                    ScrollbarMarker(
                      itemIndex: 50,
                      color: Color(0xFF50FA7B),
                      label: 'User prompt',
                    ),
                  ],
                  child: ListView.builder(
                    controller: controller,
                    itemCount: 100,
                    itemBuilder: (context, index) => Text('Line $index'),
                  ),
                ),
              ),
            ],
          ),
        ),
      );

      // With the terminal at 40 cols, the shifted scrollbar lives at
      // column 39 (20 pane + 1 divider + 18 chat + 1 scrollbar, folded
      // into Expanded). Locate the marker wherever it rendered.
      int? markerRow, markerCol;
      for (var y = 0; y < 10; y++) {
        for (var x = 30; x < 40; x++) {
          if (tester.terminalState.getCellAt(x, y)?.char == '◆') {
            markerRow = y;
            markerCol = x;
            break;
          }
        }
        if (markerRow != null) break;
      }
      expect(
        markerRow,
        isNotNull,
        reason: 'expected the marker on the shifted track',
      );

      await tester.sendMouseEvent(
        MouseEvent(
          button: MouseButton.left,
          x: markerCol!,
          y: markerRow!,
          pressed: false,
        ),
      );
      await tester.pump();

      expect(HintController.instance.activeHint, 'User prompt');

      // The tooltip's top-left corner must sit immediately to the left
      // of the scrollbar — inside the CHAT pane (column > 20, the plan
      // pane's width), not overlapping the plan pane. Before the fix
      // the corner landed at markerCol − tooltipWidth − 1 − 21 ≈ the
      // plan pane area.
      final (int, int)? corner = _findCell(tester, 40, 10, '╭');
      expect(corner, isNotNull, reason: 'expected the tooltip to be painted');
      final (cornerCol, cornerRow) = corner!;
      expect(
        cornerCol,
        greaterThan(20),
        reason:
            'tooltip must stay inside the chat pane (right of the plan pane '
            'at column ≤ 20), but its corner is at column $cornerCol',
      );
      expect(
        cornerCol,
        lessThan(markerCol),
        reason: 'tooltip should be to the left of the scrollbar',
      );
      expect(
        cornerRow,
        inInclusiveRange(markerRow - 6, markerRow + 6),
        reason: 'tooltip should be vertically near the marker row',
      );
    }, size: const Size(40, 10));
  });

  test('long labels word-wrap to fit the available space', () async {
    // Regression for the original scroll-bar tooltip behavior: a
    // multi-word label longer than the available space to the left
    // of the thumb should break across multiple lines, not get
    // truncated to one line (which is what the first refactor
    // accidentally did).
    await testNocterm('long marker label is word-wrapped', (tester) async {
      final controller = ScrollController();

      // 30 wide × 10 tall: the scrollbar is at column 29. The
      // available space for the tooltip is min(28, 15) = 15 cells.
      // A label of 5 words * ~5 chars + 4 spaces = 29 chars, which
      // won't fit on one line, so the tooltip should be multiline.
      const longLabel = 'first second third fourth fifth sixth seventh eighth';

      await tester.pumpComponent(
        Container(
          width: 30,
          height: 10,
          child: HintOverlay(
            child: ChatScrollbar(
              controller: controller,
              thumbVisibility: true,
              markers: const [
                ScrollbarMarker(
                  itemIndex: 50,
                  color: Color(0xFF50FA7B),
                  label: longLabel,
                ),
              ],
              child: ListView.builder(
                controller: controller,
                itemCount: 100,
                itemBuilder: (context, index) => Text('Line $index'),
              ),
            ),
          ),
        ),
      );

      // Find the marker.
      int? markerRow;
      for (var y = 0; y < 10; y++) {
        final ch = tester.terminalState.getCellAt(29, y)?.char;
        if (ch == '◆') {
          markerRow = y;
          break;
        }
      }
      expect(markerRow, isNotNull, reason: 'expected to find the marker');

      await tester.sendMouseEvent(
        MouseEvent(
          button: MouseButton.left,
          x: 29,
          y: markerRow!,
          pressed: false,
        ),
      );
      await tester.pump();

      // The controller should hold the full label — wrapping is
      // the tooltip's job, not the source's.
      expect(HintController.instance.activeHint, longLabel);

      // The tooltip should occupy multiple rows. We check that the
      // bottom border (╯) is at least 2 rows below the top border
      // (╭) — i.e. the tooltip has at least 2 content lines.
      final (int, int)? topCorner = _findCell(tester, 29, 10, '╭');
      final (int, int)? bottomRight = _findCell(tester, 29, 10, '╯');
      expect(topCorner, isNotNull, reason: 'tooltip should be painted');
      expect(bottomRight, isNotNull, reason: 'bottom border should be painted');
      expect(
        bottomRight!.$2 - topCorner!.$2,
        greaterThanOrEqualTo(3),
        reason:
            'tooltip should span at least 3 rows (top border + 2 content lines '
            '+ bottom border), but spans ${bottomRight.$2 - topCorner.$2}',
      );

      // The tooltip should also be word-wrapped, NOT truncated to
      // a single line. We check that the second content row
      // (right after the top border) contains text (i.e. a letter
      // or a non-border character), proving the content wrapped
      // onto multiple lines.
      final secondRow = topCorner.$2 + 1;
      var secondRowHasContent = false;
      for (var x = topCorner.$1; x < 29; x++) {
        final ch = tester.terminalState.getCellAt(x, secondRow)?.char;
        if (ch != null && ch != '│' && ch != ' ') {
          secondRowHasContent = true;
          break;
        }
      }
      expect(
        secondRowHasContent,
        isTrue,
        reason: 'the second row of the tooltip should contain wrapped content',
      );
    }, size: const Size(30, 10));
  });
}

/// Returns the (x, y) of the first cell in the tester's terminal
/// state whose character is [ch], searching the given bounds. Used
/// to locate the tooltip's top-left corner after the render pass.
(int, int)? _findCell(NoctermTester tester, int maxX, int maxY, String ch) {
  for (var y = 0; y < maxY; y++) {
    for (var x = 0; x < maxX; x++) {
      if (tester.terminalState.getCellAt(x, y)?.char == ch) {
        return (x, y);
      }
    }
  }
  return null;
}
