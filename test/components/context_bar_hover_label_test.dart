// Regression tests for the context bar's hover label and the
// skip-gate predicate.
//
// The bar shows a projected `pre → post` token count when the
// user hovers it. When the projection says compacting wouldn't
// save enough tokens to be worth the churn (the 5% threshold),
// the arrow form `X → Y` would mislead — it implies a real
// reduction that's barely there. The fix renders `X · skip`
// instead, so the user sees a short verb and knows the click
// would be near-pointless.
//
// Two knobs:
//   * `formatCompactHoverLabel(pre, post, debugMode: …)` renders
//     the hover label.
//   * `isCompactCounterproductive(estimate)` is the gate that
//     every entry point (hover, click, /compact, auto-compact)
//     reads. Same `>` boundary everywhere keeps the four
//     surfaces consistent — if a future refactor tries to
//     differentiate ("click is silent but /compact shows a
//     warning toast"), this single rule is the one to argue
//     against.
//
// Debug mode (`/debug on`) flips the hover label to always
// show the projection, even below the threshold. The click
// gate still honors the threshold — debug mode is for
// inspection, not override.

import 'package:test/test.dart';

import 'package:crux/src/components/context_bar.dart';
import 'package:crux/src/services/chat_service.dart';

ChatLogCompactionEstimate _est({
  required int pre,
  required int post,
}) =>
    ChatLogCompactionEstimate(
      preTokens: pre,
      postEstimateTokens: post,
      messageCount: 0,
    );

void main() {
  group('ContextBar.formatCompactHoverLabel', () {
    test('big savings: pre > post by >5% renders as `X → Y`', () {
      // Normal case: compacting reduces size well past the
      // 5% threshold. The arrow reads naturally — savings,
      // so "after, the result is" is meaningful.
      expect(
        ContextBarState.formatCompactHoverLabel(123_000, 56_000),
        equals('123k → 56k'),
      );
    });

    test('counter-productive (post > pre) renders as `X · skip`', () {
      // Regression: this used to render as `68k → 71k`, which
      // suggested compacting would save tokens when in fact it
      // would grow the context. The fix surfaces the no-op
      // nature as a short verb instead.
      expect(
        ContextBarState.formatCompactHoverLabel(68_718, 71_000),
        equals('68k · skip'),
      );
    });

    test('equal: pre == post renders as `X · skip` (0% < 5%)', () {
      // Zero savings falls under the 5% threshold — same skip
      // rendering as counter-productive. Avoids the misleading
      // `X → X` arrow form that we used to render here.
      expect(
        ContextBarState.formatCompactHoverLabel(50_000, 50_000),
        equals('50k · skip'),
      );
    });

    test('boundary: post = pre * 95 / 100 (5% savings) triggers skip', () {
      // Off-by-one boundary on the threshold. The user spec is
      // "save at least 5%" → equal-to-5% does NOT clear the bar.
      // 10000 * 95 / 100 = 9500; `9500 * 100 = 950000`, which is
      // NOT `< 10000 * 95 = 950000`, so skip. Catches a buggy
      // `<` that would let the equal boundary through.
      expect(
        ContextBarState.formatCompactHoverLabel(10_000, 9_500),
        equals('10k · skip'),
      );
    });

    test('boundary: just past 5% renders the arrow form', () {
      // 10000 → 9490 saves 5.1% — clears the bar.
      // `9490 * 100 = 949000 < 10000 * 95 = 950000` → worthwhile.
      expect(
        ContextBarState.formatCompactHoverLabel(10_000, 9_490),
        equals('10k → 9k'),
      );
    });

    test('M-scale: large counts use M suffix', () {
      // The format helper collapses ≥ 1M to a single-letter M
      // suffix (no thousands grouping). This is inherited from
      // `_fmtCtx` — pinning the behavior so a future switch to
      // binary (KiB) doesn't desync the hover label from the
      // bar's main display.
      expect(
        ContextBarState.formatCompactHoverLabel(1_500_000, 800_000),
        equals('1.5M → 800k'),
      );
      // Counter-productive at M scale still uses the same
      // `· skip` rendering.
      expect(
        ContextBarState.formatCompactHoverLabel(1_500_000, 2_000_000),
        equals('1.5M · skip'),
      );
    });

    test('skipped rendering does not show a misleading arrow', () {
      // The arrow `→` is the bug surface — it implies savings.
      // When we render `skip`, the arrow MUST be absent. Catches
      // a future regression that re-adds `→` for clarity.
      final rendered =
          ContextBarState.formatCompactHoverLabel(68_718, 71_000);
      expect(rendered, isNot(contains('→')));
      expect(rendered, contains('skip'));
    });

    test('debug mode: counter-productive still shows the arrow', () {
      // `/debug on` reveals the projection itself so the user
      // can see what the gate is reading. `68k → 71k` is
      // misleading for a click action but informative for
      // debugging — the user knows the gate fired because the
      // session would grow, not because the label is hidden.
      expect(
        ContextBarState.formatCompactHoverLabel(
          68_718,
          71_000,
          debugMode: true,
        ),
        equals('68k → 71k'),
      );
    });

    test('debug mode: sub-5% savings still shows the arrow', () {
      // The whole point of debug mode — let the user see the
      // projection even when it's not "worth it". A 2% saving
      // renders as `10k → 9k` in debug (9800 truncates to 9k),
      // `10k · skip` in normal.
      expect(
        ContextBarState.formatCompactHoverLabel(10_000, 9_800),
        equals('10k · skip'),
      );
      expect(
        ContextBarState.formatCompactHoverLabel(
          10_000,
          9_800,
          debugMode: true,
        ),
        equals('10k → 9k'),
      );
    });

    test('debug mode: big savings still shows the arrow', () {
      // Debug mode is purely additive — it can reveal
      // projections that the threshold hides, but it never
      // hides projections that the threshold shows.
      expect(
        ContextBarState.formatCompactHoverLabel(
          123_000,
          56_000,
          debugMode: true,
        ),
        equals('123k → 56k'),
      );
    });
  });

  group('ContextBar.isCompactCounterproductive', () {
    test('null estimate is not counterproductive', () {
      // No projection yet (cache miss / pre-hydration). The
      // click should still work — let `_buildCompactionPreview`
      // in the orchestrator make the real decision if there's
      // no cached estimate to skip against.
      expect(ContextBarState.isCompactCounterproductive(null), isFalse);
    });

    test('pre == 0 is not counterproductive (defensive)', () {
      // A session that hasn't run an AI turn yet has no
      // meaningful `pre` to compare against. The upstream
      // `toCompress.isEmpty` check catches the actual
      // nothing-to-compact case; this gate just refuses to
      // trip on a 0 denominator.
      expect(
        ContextBarState.isCompactCounterproductive(_est(pre: 0, post: 100)),
        isFalse,
      );
    });

    test('counter-productive (post > pre) is counterproductive', () {
      // Drives the `onTap: null` decision in the toolbar and
      // the no-op return in `_onCompactButtonPressed`.
      expect(
        ContextBarState.isCompactCounterproductive(
            _est(pre: 68_718, post: 71_000)),
        isTrue,
      );
    });

    test('equal sizes are counterproductive (0% savings)', () {
      // `pre == post` would render as the misleading `X → X`
      // arrow — fall under the 5% skip gate so the click is
      // blocked too.
      expect(
        ContextBarState.isCompactCounterproductive(
            _est(pre: 50_000, post: 50_000)),
        isTrue,
      );
    });

    test('sub-5% savings are counterproductive', () {
      // The new threshold: `post >= pre * 0.95` → skip. Saves
      // only 2% (10000 → 9800) is too small to justify the DB
      // write and chat log re-render.
      expect(
        ContextBarState.isCompactCounterproductive(
            _est(pre: 10_000, post: 9_800)),
        isTrue,
      );
    });

    test('savings just over 5% are NOT counterproductive', () {
      // `10000 → 9490` saves 5.1% — clears the bar. The integer
      // math (`9490 * 100 = 949000 < 10000 * 95 = 950000`)
      // decides this; float rounding at the boundary would be
      // wrong.
      expect(
        ContextBarState.isCompactCounterproductive(
            _est(pre: 10_000, post: 9_490)),
        isFalse,
      );
    });

    test('big savings (pre > post by >>5%) is NOT counterproductive', () {
      // Normal savings case — the click should fire everywhere
      // (hover label shows arrow, toolbar keeps onTap, /compact
      // proceeds, auto-compact fires).
      expect(
        ContextBarState.isCompactCounterproductive(
            _est(pre: 123_000, post: 56_000)),
        isFalse,
      );
    });

    test('gate is honored across all entry points (click, /compact, auto)',
        () {
      // The same `isCompactCounterproductive` predicate is now
      // used at every layer:
      //   * hover label → renders `X · skip` (formatCompactHoverLabel)
      //   * bar click   → toolbar sets `onTap: null`
      //   * /compact    → chat_panel `_executeCommand` early-returns
      //   * auto-compact → `createChatLogCompaction` returns null
      // This test pins the rule itself: a single boolean
      // (post >= pre * 0.95) decides skip everywhere. If a
      // future refactor tries to differentiate (e.g. "click is
      // silent but /compact shows a warning toast"), this single
      // rule is the one to argue against.
      final projection = _est(pre: 68_718, post: 71_000);
      expect(
        ContextBarState.isCompactCounterproductive(projection),
        isTrue,
        reason: 'the projection that triggered the user-facing fix',
      );
      // Sanity: a savings case is NOT counterproductive, so all
      // paths should fire normally.
      final saving = _est(pre: 123_000, post: 56_000);
      expect(ContextBarState.isCompactCounterproductive(saving), isFalse);
    });
  });

  group('ContextBar.isCompactWorthwhile', () {
    test('pure helper: same boundary as isCompactCounterproductive', () {
      // `isCompactWorthwhile` is the inner predicate — its
      // truth is the opposite of `isCompactCounterproductive`
      // for normal `pre > 0` cases. Pin both directions so a
      // future tweak to the formula can't desync them.
      expect(
        ContextBarState.isCompactWorthwhile(10_000, 9_490),
        isTrue,
        reason: '5.1% savings clears the bar',
      );
      expect(
        ContextBarState.isCompactWorthwhile(10_000, 9_500),
        isFalse,
        reason: '5% savings does NOT clear the bar (user spec)',
      );
      expect(
        ContextBarState.isCompactWorthwhile(10_000, 10_000),
        isFalse,
        reason: '0% savings',
      );
      expect(
        ContextBarState.isCompactWorthwhile(10_000, 10_001),
        isFalse,
        reason: 'negative savings',
      );
      expect(
        ContextBarState.isCompactWorthwhile(0, 100),
        isFalse,
        reason: 'pre <= 0 — let upstream handle',
      );
    });
  });
}