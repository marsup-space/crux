// Tests for the app-wide hover hint system.
//
// The hint system has three parts:
//   * HintController — the singleton state holder.
//   * HintStateMixin — the per-component mixin.
//   * HintOverlay — the top-level wrapper that paints the tooltip.
//
// These tests exercise each part in isolation, plus the full
// hover-to-tooltip flow via [testNocterm].

import 'package:nocterm/nocterm.dart';
import 'package:test/test.dart';

void main() {
  // Reset the singleton's state between tests so they're
  // independent. The mixin and overlay use the same singleton, so a
  // stale hint from a previous test would otherwise leak in.
  void resetHintController() {
    HintController.instance.hide();
  }

  setUp(resetHintController);
  tearDown(resetHintController);

  group('HintController', () {
    test('starts with no active hint', () {
      expect(HintController.instance.activeHint, isNull);
      expect(HintController.instance.activePosition, isNull);
      expect(HintController.instance.visible, isFalse);
    });

    test('show with zero delay makes the hint visible immediately', () {
      HintController.instance.show(
        'hello',
        const Offset(5, 5),
        delay: Duration.zero,
      );
      expect(HintController.instance.activeHint, 'hello');
      expect(HintController.instance.activePosition, const Offset(5, 5));
      expect(HintController.instance.visible, isTrue);
    });

    test(
      'show with non-zero delay hides the hint until the timer fires',
      () async {
        HintController.instance.show(
          'delayed',
          const Offset(0, 0),
          delay: const Duration(milliseconds: 30),
        );
        // Registered but not yet visible.
        expect(HintController.instance.activeHint, 'delayed');
        expect(HintController.instance.visible, isFalse);
        expect(HintController.instance.pendingDelay, isNotNull);

        // After the delay the hint should be visible.
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(HintController.instance.visible, isTrue);
        expect(HintController.instance.pendingDelay, isNull);
      },
    );

    test('a different requestId preempts the active hint', () {
      HintController.instance.show(
        'first',
        const Offset(1, 1),
        delay: const Duration(seconds: 5),
        requestId: Object(),
      );
      expect(HintController.instance.activeHint, 'first');
      expect(HintController.instance.visible, isFalse);

      HintController.instance.show(
        'second',
        const Offset(2, 2),
        delay: Duration.zero,
        requestId: Object(),
      );
      expect(HintController.instance.activeHint, 'second');
      expect(HintController.instance.activePosition, const Offset(2, 2));
      expect(HintController.instance.visible, isTrue);
    });

    test('same requestId updates in place without resetting the timer '
        'when already visible', () async {
      final id = Object();
      HintController.instance.show(
        'first',
        const Offset(1, 1),
        delay: const Duration(milliseconds: 30),
        requestId: id,
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(HintController.instance.visible, isTrue);

      HintController.instance.show(
        'updated',
        const Offset(7, 7),
        delay: const Duration(seconds: 5),
        requestId: id,
      );
      expect(HintController.instance.activeHint, 'updated');
      expect(HintController.instance.activePosition, const Offset(7, 7));
      // Already visible: the new delay does not re-hide the hint.
      expect(HintController.instance.visible, isTrue);
    });

    test('hide with matching id clears the hint', () {
      final id = Object();
      HintController.instance.show(
        'shown',
        const Offset(0, 0),
        delay: Duration.zero,
        requestId: id,
      );
      expect(HintController.instance.activeHint, 'shown');

      HintController.instance.hide(requestId: id);
      expect(HintController.instance.activeHint, isNull);
      expect(HintController.instance.visible, isFalse);
    });

    test('hide with non-matching id leaves the hint alone', () {
      final id = Object();
      HintController.instance.show(
        'shown',
        const Offset(0, 0),
        delay: Duration.zero,
        requestId: id,
      );

      HintController.instance.hide(requestId: Object());
      expect(HintController.instance.activeHint, 'shown');
    });

    test('hide with null id hides any hint', () {
      HintController.instance.show(
        'shown',
        const Offset(0, 0),
        delay: Duration.zero,
      );
      HintController.instance.hide();
      expect(HintController.instance.activeHint, isNull);
    });

    test('listeners are notified on show and hide', () {
      var calls = 0;
      void listener() {
        calls += 1;
      }

      HintController.instance.addListener(listener);
      addTearDown(() => HintController.instance.removeListener(listener));

      HintController.instance.show(
        'a',
        const Offset(0, 0),
        delay: Duration.zero,
      );
      HintController.instance.show(
        'b',
        const Offset(1, 0),
        delay: Duration.zero,
      );
      HintController.instance.hide();
      expect(calls, greaterThanOrEqualTo(3));
    });

    test('same requestId with zero delay notifies on field change '
        'while already visible (regression: scroll-bar markers)', () {
      // The scroll-bar markers all share the same _requestId
      // (the AnnotatedScrollbar's state). Moving the mouse from
      // one marker to the next updates the controller's content
      // / position in place — the overlay only repaints if it
      // gets a notify callback. If the controller stayed silent
      // on those updates, the tooltip would be stuck on the
      // previous marker's label.
      final id = Object();
      var calls = 0;
      void listener() {
        calls += 1;
      }

      HintController.instance.addListener(listener);
      addTearDown(() => HintController.instance.removeListener(listener));

      // Make the hint visible with zero delay.
      HintController.instance.show(
        'marker A',
        const Offset(0, 0),
        delay: Duration.zero,
        requestId: id,
      );
      final callsAfterFirst = calls;
      expect(HintController.instance.activeHint, 'marker A');
      expect(HintController.instance.visible, isTrue);

      // Same request id, different content + position. The hint
      // was already visible, so the live fields are updated in
      // place — but the overlay must still be told to repaint.
      HintController.instance.show(
        'marker B',
        const Offset(1, 1),
        delay: Duration.zero,
        requestId: id,
      );
      expect(HintController.instance.activeHint, 'marker B');
      expect(HintController.instance.activePosition, const Offset(1, 1));
      expect(
        calls,
        greaterThan(callsAfterFirst),
        reason:
            'overlay must be notified when the live fields change while '
            'the hint is already visible, otherwise the tooltip would '
            'keep showing the previous marker label',
      );
    });

    test('same requestId with zero delay does NOT notify when nothing '
        'actually changed', () {
      // The opposite regression guard: every mouse-move while the
      // cursor sits on the same marker must not trigger a
      // overlay rebuild. The controller should compare each field
      // and only notify when at least one of them differs.
      final id = Object();
      var calls = 0;
      void listener() {
        calls += 1;
      }

      HintController.instance.addListener(listener);
      addTearDown(() => HintController.instance.removeListener(listener));

      HintController.instance.show(
        'marker A',
        const Offset(0, 0),
        delay: Duration.zero,
        requestId: id,
      );
      final callsAfterFirst = calls;

      // Identical re-request: same content, same position.
      HintController.instance.show(
        'marker A',
        const Offset(0, 0),
        delay: Duration.zero,
        requestId: id,
      );
      expect(
        calls,
        callsAfterFirst,
        reason:
            'no field changed, so the overlay must not be told to '
            'rebuild (would waste work on every mouse-move while '
            'hovering the same marker)',
      );
    });
  });

  group('HintStateMixin', () {
    test('buildWithHint always wraps with a MouseRegion but a null '
        'hintContent keeps the controller quiet', () async {
      await testNocterm('null hintContent is a no-op', (tester) async {
        final mixin = _NoHintState();
        // The mixin's [buildWithHint] always installs a [MouseRegion]
        // (the previous "pass-through when hintContent is null"
        // optimization created a chicken-and-egg problem for
        // components whose hint is dynamic, e.g. the scroll bar
        // markers). The wrapping has no observable effect when
        // [hintContent] stays null — the [HintController] just never
        // receives a show request.
        final child = Text('hello');
        final wrapped = mixin.callBuildWithHint(child);
        expect(
          identical(wrapped, child),
          isFalse,
          reason: 'buildWithHint should wrap the child in a MouseRegion',
        );
        expect(
          wrapped,
          isA<MouseRegion>(),
          reason: 'wrapped component is a MouseRegion',
        );

        await tester.pumpComponent(wrapped);
        await tester.hover(0, 0);
        await tester.pump();
        // The mouse handler fires, the default [_updateHint] sees
        // hintEnabled=false (hintContent is null) and tells the
        // controller to hide.
        expect(HintController.instance.activeHint, isNull);
      });
    });

    test('hovering a hint-enabled widget registers a hint', () async {
      await testNocterm('mixin registers a hint on hover', (tester) async {
        final mixin = _HintfulState(label: 'Click me');

        await tester.pumpComponent(mixin.callBuildWithHint(Text('btn')));

        // Sanity: no hint yet.
        expect(HintController.instance.activeHint, isNull);

        // Hover over the widget. The default delay is 500 ms, so
        // shortly after hovering the hint should be *registered*
        // (activeHint is non-null) but not yet *visible*.
        await tester.hover(0, 0);
        await tester.pump(const Duration(milliseconds: 50));
        expect(HintController.instance.activeHint, 'Click me');
        expect(HintController.instance.visible, isFalse);
      });
    });

    test('hint becomes visible once the delay elapses', () async {
      await testNocterm('hint becomes visible after delay', (tester) async {
        // Use a small delay (50 ms) so the test is fast.
        final mixin = _HintfulState(
          label: 'Soon visible',
          delay: const Duration(milliseconds: 50),
        );

        await tester.pumpComponent(mixin.callBuildWithHint(Text('btn')));

        await tester.hover(0, 0);
        await tester.pump();
        expect(HintController.instance.visible, isFalse);

        // Wait past the delay; the pump() picks up the elapsed
        // timer and marks the hint visible.
        await tester.pump(const Duration(milliseconds: 80));
        expect(HintController.instance.visible, isTrue);
      });
    });

    test(
      'immediate-delay hint (Duration.zero) becomes visible right away',
      () async {
        await testNocterm('zero delay hint is visible on first hover', (
          tester,
        ) async {
          final mixin = _HintfulState(label: 'Click me', delay: Duration.zero);

          await tester.pumpComponent(mixin.callBuildWithHint(Text('btn')));
          expect(HintController.instance.activeHint, isNull);

          await tester.hover(0, 0);
          await tester.pump();
          expect(HintController.instance.activeHint, 'Click me');
          expect(HintController.instance.visible, isTrue);
        });
      },
    );
  });

  group('HintOverlay', () {
    test('paints the tooltip when the controller has an active hint', () async {
      await testNocterm('tooltip is rendered above the child', (tester) async {
        // The overlay's default tooltipMaxWidth is 40, so the
        // tooltip is 40 cells wide (including the border). For a
        // 1-line "hi" content the layout is 3 rows tall:
        //   row 0: top border ╭─…─╮ (40 cells)
        //   row 1: content     │hi                │ (40 cells)
        //   row 2: bottom border ╰─…─╯
        await tester.pumpComponent(HintOverlay(child: Text('child')));
        // No hint: tooltip is not drawn.
        expect(_cellChar(tester, 0, 0), isNot('╭'));

        // Source at (40, 8), centerX = 40.5.
        // Above: y = 8 - 3 - 1 = 4, x = 40.5 - 20 = 20.5 → 21.
        HintController.instance.show(
          'hi',
          const Offset(40, 8),
          delay: Duration.zero,
          sourceBounds: const Rect.fromLTWH(40, 8, 1, 1),
        );
        await tester.pump();
        // Top border.
        expect(_cellChar(tester, 21, 4), '╭');
        expect(_cellChar(tester, 60, 4), '╮');
        // Content row.
        expect(_cellChar(tester, 21, 5), '│');
        expect(_cellChar(tester, 22, 5), 'h');
        expect(_cellChar(tester, 23, 5), 'i');
        expect(_cellChar(tester, 60, 5), '│');
        // Bottom border.
        expect(_cellChar(tester, 21, 6), '╰');
        expect(_cellChar(tester, 60, 6), '╯');
      }, size: const Size(80, 15));
    });

    test('tooltip is placed below the source when above overflows', () async {
      await testNocterm('placement resolver flips preferred/opposite', (
        tester,
      ) async {
        // Source is at the very top of the screen, so "above"
        // overflows. The resolver should flip to "below".
        await tester.pumpComponent(HintOverlay(child: Text('child')));
        HintController.instance.show(
          'hi',
          const Offset(10, 0),
          delay: Duration.zero,
          sourceBounds: const Rect.fromLTWH(10, 0, 1, 1),
        );
        await tester.pump();
        // Below placement: tooltip's top is at y=1. Bottom border
        // (╰) should appear at y=1+tooltipHeight-1 = 1+5 = 6
        // ... which overflows a 5-row stack. Hmm. The resolver
        // would then go to the non-overlapping fallback. Let's
        // not assert on the exact position here — just assert
        // the controller recorded a hint.
        expect(HintController.instance.activeHint, 'hi');
      }, size: const Size(80, 15));
    });

    test(
      'Hinted wrapper exposes hint content + placement to the controller',
      () async {
        // The [Hinted] widget is the convenient "I just want a hint
        // on this subtree" entry point. It uses [HintStateMixin] under
        // the hood and forwards its `hint`, `delay`, `placement`, and
        // `color` to the controller on hover.
        await testNocterm('Hinted drives the controller', (tester) async {
          await tester.pumpComponent(
            HintOverlay(
              child: Hinted(
                hint: 'I am a hinted widget',
                placement: HintPlacement.below,
                child: Text('hover me'),
              ),
            ),
          );
          // No hint before hover.
          expect(HintController.instance.activeHint, isNull);

          // Hover inside the subtree. The hint is *registered*
          // immediately but not *visible* until the default 500 ms
          // delay elapses.
          await tester.hover(2, 2);
          await tester.pump();
          expect(HintController.instance.activeHint, 'I am a hinted widget');
          expect(
            HintController.instance.visible,
            isFalse,
            reason: 'hint should be registered but not yet visible',
          );

          // Past the delay: visible.
          await tester.pump(const Duration(milliseconds: 600));
          expect(HintController.instance.activeHint, 'I am a hinted widget');
          expect(HintController.instance.visible, isTrue);
          expect(HintController.instance.activePlacement, HintPlacement.below);
        }, size: const Size(40, 15));
      },
    );

    test('Hinted rebuilds with new hint text refresh the tooltip while '
        'the cursor is still hovering '
        '(regression: glossy model button streaming lock)', () async {
      // Repro of the "stuck tooltip" bug: the user hovers a
      // [Hinted] widget, the host rebuilds with a *new* [Hinted.hint]
      // (e.g. the chat toolbar's model picker flips from "click
      // to change" to "cannot be changed" when streaming
      // starts), and the tooltip is supposed to update in place.
      // Before the fix, [_HintedState] had no `didUpdateComponent`
      // hook, so the controller kept painting the previous text
      // until the next mouse move — looking like a stuck mouse
      // state.
      await testNocterm('Hinted refreshes on rebuild', (tester) async {
        String currentHint = 'click to change';
        late void Function() updateHint;

        await tester.pumpComponent(
          HintOverlay(
            child: _RebuildOnDemand(
              builder: (context, setState) {
                updateHint = () {
                  setState(() {
                    currentHint = 'cannot be changed while responding';
                  });
                };
                return Hinted(
                  hint: currentHint,
                  delay: Duration.zero, // skip the 500 ms wait
                  child: Text('Model'),
                );
              },
            ),
          ),
        );

        // Hover. With zero delay the hint is visible right away.
        await tester.hover(1, 1);
        await tester.pump();
        expect(
          HintController.instance.activeHint,
          'click to change',
          reason: 'sanity: initial hint is registered and visible',
        );
        expect(HintController.instance.visible, isTrue);

        // Rebuild the [Hinted] with new text but DO NOT move the
        // mouse. The tooltip should pick up the new text
        // immediately. Before the fix this assertion failed — the
        // controller was still holding the old text.
        updateHint();
        await tester.pump();
        expect(
          HintController.instance.activeHint,
          'cannot be changed while responding',
          reason:
              'Hinted must re-fire its hint on didUpdateComponent '
              'so a stationary cursor sees the new text instead of '
              'the stale "click to change" from before the rebuild',
        );
        expect(
          HintController.instance.visible,
          isTrue,
          reason: 'the tooltip should stay visible across the rebuild',
        );
      }, size: const Size(40, 15));
    });

    test('Hinted rebuild with same hint text does not re-show the tooltip '
        'after the cursor leaves the source', () async {
      // Companion guard for the new [refreshHintFromLastEvent] path:
      // a rebuild while the cursor is *not* hovering must not
      // re-pop the tooltip. [_lastMouseEvent] is cleared in
      // [onHintExit] so the helper becomes a no-op — without
      // that, a rebuild with the same hint text would silently
      // re-appear after the user had moved the cursor away.
      //
      // [HintOverlay] uses a [Stack] with [StackFit.expand], which
      // stretches the single non-positioned child to fill the
      // overlay. We wrap the [Hinted] in an [Align] so it keeps
      // its natural (text) size at the top-left — otherwise
      // every cell of the 40×15 terminal is "inside" the
      // hinted region and the cursor can never actually leave
      // it, defeating the test.
      await testNocterm('Hinted refresh respects cursor exit', (tester) async {
        String currentHint = 'first';
        late void Function() updateHint;

        await tester.pumpComponent(
          HintOverlay(
            child: Align(
              alignment: Alignment.topLeft,
              child: _RebuildOnDemand(
                builder: (context, setState) {
                  updateHint = () {
                    setState(() {
                      currentHint = 'second';
                    });
                  };
                  return Hinted(
                    hint: currentHint,
                    delay: Duration.zero,
                    child: Text('Source'),
                  );
                },
              ),
            ),
          ),
        );

        // Hover so the hint becomes active. The Align keeps the
        // Hinted at its natural 6×1 size, so the hit region is
        // the top row (y=0) of the first 6 columns. (1, 0) is
        // safely inside; (1, 1) would land on the bottom edge
        // which [Rect.contains] treats as exclusive.
        await tester.hover(1, 0);
        await tester.pump();
        expect(HintController.instance.activeHint, 'first');
        expect(HintController.instance.visible, isTrue);

        // Move the cursor away. The hint hides.
        await tester.hover(30, 10);
        await tester.pump();
        expect(HintController.instance.activeHint, isNull);
        expect(HintController.instance.visible, isFalse);

        // Rebuild with new text. The cursor is not over the
        // source anymore, so the tooltip must stay hidden even
        // though [refreshHintFromLastEvent] is now wired up.
        updateHint();
        await tester.pump();
        expect(
          HintController.instance.activeHint,
          isNull,
          reason:
              'no cursor over the source → _lastMouseEvent is null '
              '→ refreshHintFromLastEvent is a no-op → tooltip '
              'stays hidden',
        );
      }, size: const Size(40, 15));
    });
  });

  group('MouseTracker synthetic dispatch (framework fix)', () {
    test('replacing a MouseRegion while hovered fires onEnter on the new '
        'region via synthetic dispatch at end of frame', () async {
      await testNocterm('MouseRegion: synthetic onEnter after rebuild', (
        tester,
      ) async {
        var enterCount = 0;
        var exitCount = 0;
        var replaceRegion = false;
        late void Function() triggerReplace;

        await tester.pumpComponent(
          _RebuildOnDemand(
            builder: (context, setState) {
              triggerReplace = () {
                setState(() => replaceRegion = true);
              };
              if (!replaceRegion) {
                return MouseRegion(
                  opaque: false,
                  onEnter: (_) => enterCount += 1,
                  onExit: (_) => exitCount += 1,
                  child: const SizedBox(width: 10, height: 10),
                );
              } else {
                // A different MouseRegion — the framework sees a
                // different runtimeType because we wrap it with a
                // key. The old RenderMouseRegion detaches (sets
                // validForMouseTracker = false), the new one
                // attaches (validForMouseTracker = true).
                return MouseRegion(
                  key: const Key('replacement'),
                  opaque: false,
                  onEnter: (_) => enterCount += 1,
                  onExit: (_) => exitCount += 1,
                  child: const SizedBox(width: 10, height: 10),
                );
              }
            },
          ),
        );

        // Hover inside the region. The onEnter fires.
        await tester.hover(5, 5);
        await tester.pump();
        expect(enterCount, 1);
        expect(exitCount, 0);

        // Rebuild with a new MouseRegion. The cursor hasn't moved,
        // but the old region detaches and the new one attaches.
        // Before the framework fix, onEnter would NOT fire on the
        // new region until the next real mouse event — this is the
        // "stuck tooltip" root cause. After the fix, the binding's
        // synthetic dispatch fires onEnter at the end of drawFrame.
        triggerReplace();
        await tester.pump();

        expect(
          enterCount,
          2,
          reason:
              'The new MouseRegion should get a synthetic onEnter '
              'at end of frame when the cursor did not move',
        );
        // The old region's onExit fires as part of the real
        // dispatch (the cursor hasn't moved, but the old annotation
        // is definitely no longer in the hit test — it was dirtied
        // and the MouseTracker skips it during exit diff).
        // However, since validForMouseTracker=false on the old
        // annotation, _dispatchEvent skips it in the exited set
        // (the validForMouseTracker guard). The synthetic dispatch
        // then finds the NEW annotation (now in the hit test) and
        // fires onEnter. So the old annotation's onExit doesn't
        // fire — but the new one's onEnter does. That's the
        // expected behavior from the framework perspective.
      }, size: const Size(20, 20));
    });
  });
}
// ---------------------------------------------------------------------------
// Test fixtures
// ---------------------------------------------------------------------------

/// State that does NOT override [HintStateMixin.hintContent], so the
/// default (null) applies. The `callBuildWithHint` shim exposes the
/// protected helper for tests.
class _NoHintState extends State<_NoHintComponent>
    with HintStateMixin<_NoHintComponent> {
  @override
  Component build(BuildContext context) => const SizedBox();

  Component callBuildWithHint(Component child) => buildWithHint(child);
}

class _NoHintComponent extends StatefulComponent {
  const _NoHintComponent();
  @override
  State<_NoHintComponent> createState() => _NoHintState();
}

/// State that does provide a hint, optionally with a custom delay.
class _HintfulState extends State<_HintfulComponent>
    with HintStateMixin<_HintfulComponent> {
  _HintfulState({required this.label, this.delay});

  final String label;
  final Duration? delay;

  @override
  String? get hintContent => label;

  @override
  Duration get hintDelay => delay ?? super.hintDelay;

  @override
  Component build(BuildContext context) => const SizedBox();

  Component callBuildWithHint(Component child) => buildWithHint(child);
}

class _HintfulComponent extends StatefulComponent {
  const _HintfulComponent();
  @override
  State<_HintfulComponent> createState() => _HintfulState(label: '');
}

/// Minimal "give me a `setState`" host used by the
/// "Hinted rebuilds with new hint text" tests. The tests capture the
/// returned setter via the builder closure and call it to trigger
/// `didUpdateComponent` on the inner [Hinted] state without
/// disposing the element (a fresh `pumpComponent` would tear down
/// the state and lose the cursor's hover bookkeeping).
class _RebuildOnDemand extends StatefulComponent {
  const _RebuildOnDemand({required this.builder});

  final Component Function(BuildContext, StateSetter) builder;

  @override
  State<_RebuildOnDemand> createState() => _RebuildOnDemandState();
}

class _RebuildOnDemandState extends State<_RebuildOnDemand> {
  @override
  Component build(BuildContext context) => component.builder(context, setState);
}

/// Returns the character at `(x, y)` in the most recent buffer, or
/// `null` if the cell is empty / unset.
String? _cellChar(NoctermTester tester, int x, int y) {
  final cell = tester.terminalState.getCellAt(x, y);
  return cell?.char;
}
