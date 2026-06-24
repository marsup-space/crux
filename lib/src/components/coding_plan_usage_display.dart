// Renders progress bars directly on a TerminalCanvas for the coding-plan
// usage readout. TerminalCanvas is nocterm's internal paint surface and
// isn't re-exported by `package:nocterm/nocterm.dart`.
// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:math' as math;

import 'package:nocterm/nocterm.dart';
import 'package:nocterm/src/framework/terminal_canvas.dart';

import '../models/coding_plan_usage.dart';
import '../theme/crux_theme.dart';
import '../utils/ticker_registry.dart';

/// Display-only coding-plan (Token Plan) usage readout for the chat
/// toolbar.
///
/// Sits to the right of the [MetricsDisplay] and shows the active
/// provider's 5-hour and 1-week remaining percentages
/// (e.g. `5h 98% / 1w 73%`) or, on hover, the time-until-reset
/// countdowns (e.g. `5h 4h 32m / 1w 6d 4h`).
///
/// The widget is intentionally dumb: it takes a [Stream] of
/// [CodingPlanUsage] snapshots and a starting [initialUsage],
/// and renders the most recent value. The polling lifecycle
/// lives on the `CodingPlanProvider` mixin; the widget just
/// paints.
///
/// ## Hover countdown ticker
///
/// When the user hovers and at least one cell has a
/// countdown [Duration] (i.e. `intervalRemains` or
/// `weeklyRemains` is non-null), a separate
/// [_countdownTicker] starts running at
/// [_countdownTickInterval] (250ms) and the displayed
/// countdown is computed from an anchor captured at
/// hover-entry:
///
/// ```text
/// displayed = anchor - (now - anchorMs)
/// ```
///
/// where `anchor` is the snapshot's effective time-until-
/// reset at hover-entry (`intervalRemains - (now - fetchedAt)`,
/// clamped to `>= 0`). The 250ms cadence catches minute-
/// boundary transitions promptly and also handles the
/// final second digits naturally. Ticks yield to the
/// 3-second animation ticker when both fire in the same
/// frame, so the punchy red/green flash stays clean.
///
/// When either cell's displayed countdown hits zero, the
/// ticker reuses the click-to-refresh path ([_onTap]) so
/// the same flash-spinner / `onTap` plumbing kicks in.
/// The new snapshot the provider emits will replace the
/// ticker's value via [_onUsage], which also re-anchors
/// (or stops) the ticker.
///
/// ## Animation
///
/// When a new snapshot arrives and the value differs from the
/// previous one, the cell "dramatically" ticks to the new
/// value over [_animationDuration] (3 seconds):
///
///   * **Decrement** (user consumed quota — e.g. 98% → 97%):
///     the cell flashes red ([CruxThemeData.error]) at the
///     moment the new value lands, then lerps back to the
///     cell's normal color. The number itself ticks down
///     with two-decimal precision (`97.50` → `97.20` → …)
///     so the decrease is visible frame-by-frame, not just
///     at the endpoints. After the animation settles, the
///     number is shown as a rounded integer (`97%`).
///
///   * **Increment** (the 5h / 1w window just reset — e.g.
///     3% → 100%): the cell flashes green
///     ([CruxThemeData.success]) and lerps back. Same
///     precision treatment for the number.
///
/// The animation is driven by [TickerRegistry], which wraps
/// nocterm's frame scheduler. The ticker runs at 16ms (one
/// frame at 60fps) so the lerp is smooth; identical frames
/// are absorbed by [RenderCodingPlanUsage.update]'s dirty
/// check, so an animation that's already settled costs
/// nothing per frame.
///
/// The animation only fires when the value actually changed
/// (the stream sometimes delivers identical snapshots —
/// e.g. the 180s idle poll when no calls have been made).
class CodingPlanUsageDisplay extends StatefulComponent {
  /// Stream of usage snapshots. Emits a new [CodingPlanUsage]
  /// each time the provider's polling timer fires
  /// successfully. The widget subscribes for the lifetime of
  /// the state and unsubscribes on dispose.
  final Stream<CodingPlanUsage> stream;

  /// Snapshot to display before the first stream event
  /// arrives. Typically the provider's
  /// `latestCodingPlanUsage` at widget construction time.
  /// If null, the widget renders a "—" placeholder until
  /// the first event lands.
  final CodingPlanUsage? initialUsage;

  /// Called when the user clicks the display to force an
  /// immediate refresh of the coding-plan usage data.
  final VoidCallback? onTap;

  const CodingPlanUsageDisplay({
    super.key,
    required this.stream,
    this.initialUsage,
    this.onTap,
  });

  @override
  State<CodingPlanUsageDisplay> createState() =>
      _CodingPlanUsageDisplayState();
}

class _CodingPlanUsageDisplayState
    extends State<CodingPlanUsageDisplay> {
  /// The latest snapshot received. Used to detect deltas
  /// (which direction did the value move?) and as the
  /// settled target after the animation finishes.
  CodingPlanUsage? _usage;

  /// Hover state. Mirrors [MetricsDisplay]. When true, the
  /// cell shows the time-until-reset countdown; when false,
  /// it shows the percentage.
  bool _hovered = false;

  /// Subscription to the provider's stream. Created in
  /// [initState], cancelled in [dispose].
  StreamSubscription<CodingPlanUsage>? _subscription;

  /// Direct reference to the render object. Captured by
  /// the bridge widget's `onRenderObject` callback during
  /// first mount. The animation ticker pushes to this
  /// directly every frame so it can run without
  /// [setState].
  RenderCodingPlanUsage? _renderObject;

  // ─── Animation state ──────────────────────────────────────

  /// How long the dramatic lerp takes. Three seconds is
  /// long enough to read the tick-down frame-by-frame but
  /// short enough to not feel sluggish on the next poll.
  static const Duration _animationDuration =
      Duration(milliseconds: 3000);

  /// Per-frame tick. Driven by the nocterm frame scheduler
  /// (16ms ≈ 60fps), so the lerp is smooth without
  /// burning CPU on a tight `Timer.periodic` loop.
  TickerToken? _animationTicker;

  /// Monotonic start time in ms, captured when the
  /// animation is kicked off.
  int _animationStartMs = 0;

  /// Value endpoints (as doubles, so the per-frame
  /// `toStringAsFixed(1)` ticks smoothly).
  double _fromInterval = 0;
  double _toInterval = 0;
  double _fromWeekly = 0;
  double _toWeekly = 0;

  /// Flash colors for the two cells. Red on decrement,
  /// green on increment. The ticker lerps from these
  /// back to the cell's target (settled) color
  /// ([_targetIntervalColor] / [_targetWeeklyColor]),
  /// precomputed when the animation starts.
  Color _flashInterval = Color.defaultColor;
  Color _flashWeekly = Color.defaultColor;

  /// Target (settled) color for the interval cell,
  /// precomputed at the start of the animation so each
  /// per-frame tick just lerps between
  /// [_flashInterval] and this value. Defaults to
  /// the terminal default until [_startAnimation]
  /// populates it.
  Color _targetIntervalColor = Color.defaultColor;
  Color _targetWeeklyColor = Color.defaultColor;

  // ─── Refresh-flash state ───────────────────────────────────

  /// Whether a user-triggered refresh is in flight. While
  /// true the cell shows `⟳` to give immediate feedback
  /// that the click did something. Cleared when the
  /// stream delivers the next snapshot (or the flash
  /// animation times out).
  bool _refreshing = false;

  /// Monotonic start time for the refresh flash.
  int _refreshStartMs = 0;

  /// Duration of the refresh-flash spinner. Short so it
  /// feels responsive.
  static const Duration _refreshFlashDuration =
      Duration(milliseconds: 600);

  // ─── Hover-countdown ticker state ──────────────────────────

  /// Cadence for the hover countdown ticker. 250ms is a
  /// good balance: faster than the 1-second wall clock
  /// (so the displayed second digit changes within ~250ms
  /// of the actual transition), and cheap because each
  /// tick just decrements a [Duration] and pushes one
  /// paint — the render object's dirty check absorbs
  /// no-op frames where the formatted string didn't
  /// change (e.g. within the same second).
  static const Duration _countdownTickInterval =
      Duration(milliseconds: 250);

  /// Ticker for the hover countdown. Started by
  /// [_syncCountdownTicker] when the user hovers and at
  /// least one cell has a countdown [Duration].
  /// Stopped on hover-exit, when a new snapshot lands
  /// whose countdown fields are all null, or when the
  /// displayed countdown hits zero (in which case
  /// [_onTap] is invoked to trigger a refresh).
  TickerToken? _countdownTicker;

  /// Wall-clock time captured when the countdown anchor
  /// was last (re-)set. The displayed countdown is
  /// computed as `_anchor*Remains - (now - _countdownAnchorMs)`,
  /// so this is the "t=0" of the visible countdown.
  int _countdownAnchorMs = 0;

  /// Effective time-until-reset for the 5h window at the
  /// moment [_syncCountdownTicker] captured the anchor.
  /// Computed from the snapshot's `intervalRemains`
  /// minus the elapsed time since `fetchedAt`, so the
  /// countdown starts from the actual remaining time
  /// (not the API's stale value) the instant the user
  /// hovers.
  Duration? _anchorIntervalRemains;

  /// Same as [_anchorIntervalRemains] but for the weekly
  /// window.
  Duration? _anchorWeeklyRemains;

  @override
  void initState() {
    super.initState();
    _usage = component.initialUsage;
    _subscription = component.stream.listen(_onUsage);
  }

  @override
  void didUpdateComponent(CodingPlanUsageDisplay oldComponent) {
    super.didUpdateComponent(oldComponent);
    // If the parent swapped our stream (e.g. user switched
    // from a coding-plan provider to a non-coding-plan one
    // and back), rebind the subscription. The new stream
    // will deliver its first event soon; the old
    // subscription is cancelled to avoid leaks.
    if (oldComponent.stream != component.stream) {
      _subscription?.cancel();
      _subscription = component.stream.listen(_onUsage);
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _animationTicker?.cancel();
    _animationTicker = null;
    _countdownTicker?.cancel();
    _countdownTicker = null;
    super.dispose();
  }

  // ─── Stream / animation lifecycle ────────────────────────

  /// Called on every successful poll from the mixin.
  void _onUsage(CodingPlanUsage usage) {
    if (!mounted) return;
    final prev = _usage;
    _usage = usage;
    // When the stream delivers fresh data, clear the
    // refresh-flash state so normal rendering resumes.
    _refreshing = false;
    if (prev != null) {
      _startAnimation(prev, usage);
    }
    // Push the current frame (settled or first frame of
    // animation). The ticker, if running, will overwrite
    // this on its next fire — but a push here means the
    // user never sees a stale "previous value" while
    // waiting for the first tick.
    _pushCurrentFrame();
    // Trigger a rebuild so hover-aware paths and any
    // consumer of `_usage` see the new value. Cheap:
    // build is trivial, the bridge component is
    // structurally identical, and the render object
    // dirty-check absorbs no-op updates.
    setState(() {});
    // Re-evaluate the hover countdown ticker. A new
    // snapshot might:
    //   * have reset the window (new intervalRemains
    //     farther out → re-anchor so the countdown
    //     snaps to the new value);
    //   * have a different remaining value mid-window
    //     (same — re-anchor to avoid drift);
    //   * leave the countdown fields all null
    //     (stop ticking — nothing to display);
    //   * leave the countdown in the same regime
    //     (no-op, ticker keeps running).
    // We call this *after* setState so the render
    // object is freshly attached (defensive — the
    // bridge's createRenderObject runs during the
    // first build, and the countdown ticker only
    // starts after that on first hover anyway).
    _syncCountdownTicker();
  }

  /// Begin a 3-second lerp from [from] to [to]. Picks the
  /// flash color (red for decrement, green for increment)
  /// for each cell independently — the 5h window can
  /// reset (increment) while the 1w window keeps
  /// decreasing, for example. Also precomputes the
  /// target (settled) color for each cell so the
  /// per-frame tick is a single lerp.
  void _startAnimation(CodingPlanUsage from, CodingPlanUsage to) {
    // No change → no animation. The 30s/180s idle polls
    // deliver identical snapshots when no calls have
    // been made; we want the cell to stay stable
    // (no flash, no ticker, no colour change), not
    // animate "green" every poll. The previous value
    // is still in _usage, so the settled frame stays
    // painted.
    if (from.intervalRemainingPct == to.intervalRemainingPct &&
        from.weeklyRemainingPct == to.weeklyRemainingPct) {
      return;
    }
    final theme = CruxTheme.of(context);
    _animationStartMs = DateTime.now().millisecondsSinceEpoch;
    _fromInterval = from.intervalRemainingPct.toDouble();
    _toInterval = to.intervalRemainingPct.toDouble();
    _fromWeekly = from.weeklyRemainingPct.toDouble();
    _toWeekly = to.weeklyRemainingPct.toDouble();
    _flashInterval = _toInterval < _fromInterval
        ? theme.error
        : theme.success;
    _flashWeekly = _toWeekly < _fromWeekly
        ? theme.error
        : theme.success;
    // Precompute the target (post-flash) color for
    // each cell. This is the ratio-based steady-state
    // color of the new value — [_ratio] gives the
    // remaining/timeremaining ratio, [_ratioColor]
    // maps it to the right zone (afluent / middleground
    // / scarce).
    _targetIntervalColor = _ratioColor(
      theme,
      _ratio(to.intervalRemainingPct, to.intervalRemains,
          _kIntervalWindow),
    );
    _targetWeeklyColor = _ratioColor(
      theme,
      _ratio(to.weeklyRemainingPct, to.weeklyRemains,
          _kWeeklyWindow),
    );
    // Start ticker (idempotent — if a previous animation
    // is still running, its next tick will pick up the
    // new from/to and continue with the new colour). The
    // scheduler-backed ticker is ~free when the app is
    // idle (no frames to drive), so leaving the
    // subscription between polls is fine; we cancel it
    // when the animation finishes.
    _animationTicker ??= TickerRegistry.instance.subscribe(
      name: 'codingPlanAnimation',
      interval: const Duration(milliseconds: 16),
      onTick: _tickAnimation,
    );
  }

  /// Per-frame animation callback. Lerps the displayed
  /// value (with 2-decimal precision) and the colour
  /// (flash → normal, eased) for both cells, pushes the
  /// result into the render object. Stops the ticker
  /// when the animation completes; the final push is
  /// the settled value.
  ///
  /// The [elapsed] parameter is the wall-clock delta from
  /// the scheduler; this animation drives progress off the
  /// captured start time (so duration is wall-clock-correct
  /// even if the frame interval drifts). It's plumbed through
  /// for symmetry with the other tick callbacks and to make
  /// it obvious where the time input comes from.
  void _tickAnimation(Duration elapsed) {
    final ro = _renderObject;
    if (ro == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final elapsed = now - _animationStartMs;
    final t = (elapsed / _animationDuration.inMilliseconds)
        .clamp(0.0, 1.0);

    if (t >= 1.0) {
      _animationTicker?.cancel();
      _animationTicker = null;
      // Settled frame — no animation noise, normal colour.
      _pushSettledFrame();
      return;
    }

    // Value: linear lerp on the raw double. Linear is
    // correct for a "consumed quota" feel — the user
    // should perceive the number as ticking down at a
    // roughly constant rate.
    final intervalValue = _lerp(_fromInterval, _toInterval, t);
    final weeklyValue = _lerp(_fromWeekly, _toWeekly, t);

    // Colour: cubic ease-out from flash → target. The
    // snappy-at-start, gentle-settle shape makes the
    // decrement feel "punchy" — the red hits hard then
    // fades — rather than a flat linear blend that
    // looks washed-out throughout. The target is the
    // ratio-based steady-state colour (afluent /
    // middleground / scarce), precomputed in
    // [_startAnimation] so we don't recompute the ratio
    // every frame.
    final colorT = 1.0 - math.pow(1.0 - t, 3).toDouble();
    final intervalColor = Color.lerp(
      _flashInterval,
      _targetIntervalColor,
      colorT,
    )!;
    final weeklyColor = Color.lerp(
      _flashWeekly,
      _targetWeeklyColor,
      colorT,
    )!;

    ro.update(
      intervalText: '5h ${intervalValue.toStringAsFixed(1)}%',
      weeklyText: '1w ${weeklyValue.toStringAsFixed(1)}%',
      intervalFg: intervalColor,
      weeklyFg: weeklyColor,
      hovered: _hovered,
    );
  }

  /// Push either the current animation frame (if the
  /// ticker is mid-animation, the next tick will
  /// overwrite this) or the hover countdown frame, or
  /// the settled frame. The unified "current frame"
  /// computation keeps hover-aware rendering consistent
  /// across both paths.
  void _pushCurrentFrame() {
    final animTicker = _animationTicker;
    if (animTicker != null && animTicker.isActive) {
      _tickAnimation(Duration.zero);
    } else if (_countdownTicker?.isActive ?? false) {
      _tickCountdown(Duration.zero);
    } else if (_refreshing) {
      _pushRefreshFrame();
    } else {
      _pushSettledFrame();
    }
  }

  /// Push the post-animation value: integer percentage
  /// (or countdown on hover), normal colour. Called
  /// after a tick reaches t=1, on the initial mount,
  /// and on hover changes when no animation is running.
  void _pushSettledFrame() {
    final ro = _renderObject;
    if (ro == null) return;
    final usage = _usage;
    if (usage == null) {
      final theme = CruxTheme.of(context);
      ro.update(
        intervalText: '5h —',
        weeklyText: '1w —',
        intervalFg: theme.metricsIdle,
        weeklyFg: theme.metricsIdle,
        hovered: _hovered,
      );
      return;
    }
    final theme = CruxTheme.of(context);
    // 1-decimal-place display across the board: settled
    // state, animation, and (where possible) hover. The
    // hover fallback to the formatRemains() countdown is
    // unchanged (it shows "4h 32m", not a percentage).
    // The animation also uses toStringAsFixed(1) below
    // so the user sees a consistent precision — the
    // value ticks by 0.1 per frame, which is plenty of
    // resolution for a 3-second drop without producing
    // "97.50" / "97.40" / ... frames that read as
    // visual noise.
    final intervalInner = _hovered
        ? (usage.formatIntervalRemains() ??
            '${usage.intervalRemainingPct.toStringAsFixed(1)}%')
        : '${usage.intervalRemainingPct.toStringAsFixed(1)}%';
    final weeklyInner = _hovered
        ? (usage.formatWeeklyRemains() ??
            '${usage.weeklyRemainingPct.toStringAsFixed(1)}%')
        : '${usage.weeklyRemainingPct.toStringAsFixed(1)}%';

    // The "normal" colour after a flash settles comes
    // from the ratio of usage to time elapsed, not the
    // raw remaining percentage. This lets the cell
    // distinguish three regimes (afluent / middleground
    // / scarce) — see [_ratioColor] for the full spec.
    final intervalColor = _ratioColor(
      theme,
      _ratio(
        usage.intervalRemainingPct,
        usage.intervalRemains,
        _kIntervalWindow,
      ),
    );
    final weeklyColor = _ratioColor(
      theme,
      _ratio(
        usage.weeklyRemainingPct,
        usage.weeklyRemains,
        _kWeeklyWindow,
      ),
    );

    ro.update(
      intervalText: '5h $intervalInner',
      weeklyText: '1w $weeklyInner',
      intervalFg: intervalColor,
      weeklyFg: weeklyColor,
      hovered: _hovered,
    );
  }

  // ─── Refresh-flash lifecycle ──────────────────────────────

  /// Called from [build] when the user taps the display.
  /// Kicks off the refresh-flash spinner and delegates
  /// to [component.onTap] for the actual fetch. Also
  /// invoked from [_tickCountdown] when the displayed
  /// countdown reaches zero — same refresh path either
  /// way.
  void _onTap() {
    if (_refreshing) return; // double-click guard
    _refreshing = true;
    _refreshStartMs = DateTime.now().millisecondsSinceEpoch;
    // Stop the hover countdown ticker — the refresh
    // flash takes over the display, and the new
    // snapshot the stream delivers will restart (or
    // leave stopped) the ticker via [_onUsage]. Without
    // this, the countdown could tick down to zero
    // mid-refresh and re-enter [_onTap], which would
    // be silently dropped by the `_refreshing` guard
    // but still wastes a tick.
    _countdownTicker?.cancel();
    _countdownTicker = null;
    // Push the spinner frame immediately so the user
    // sees feedback on the very next paint.
    _pushCurrentFrame();
    // Fire the provider's refresh (invokes _tick(), which
    // calls getCodingPlanUsage(), which feeds the stream).
    component.onTap?.call();
  }

  /// Render the refresh-flash spinner: `⟳` in the accent
  /// colour, fading back to the settled colours over
  /// [_refreshFlashDuration]. Called from
  /// [_pushCurrentFrame] while [_refreshing] is true.
  void _pushRefreshFrame() {
    final ro = _renderObject;
    if (ro == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final elapsed = now - _refreshStartMs;
    final t = (elapsed / _refreshFlashDuration.inMilliseconds)
        .clamp(0.0, 1.0);
    final theme = CruxTheme.of(context);

    if (t >= 1.0) {
      // Flash timed out — revert to settled. The stream
      // might deliver data on the next poll tick but
      // the spinner shouldn't stay forever.
      _refreshing = false;
      _pushSettledFrame();
      return;
    }

    // Fade from accent (cyan) back to the cell's normal
    // colour. Linear fade looks clean for this tiny span.
    final settledInterval = _ratioColor(
      theme,
      _ratio(
        _usage?.intervalRemainingPct ?? 100,
        _usage?.intervalRemains,
        _kIntervalWindow,
      ),
    );
    final settledWeekly = _ratioColor(
      theme,
      _ratio(
        _usage?.weeklyRemainingPct ?? 100,
        _usage?.weeklyRemains,
        _kWeeklyWindow,
      ),
    );
    final color = Color.lerp(theme.cyan, settledInterval, t)!;

    ro.update(
      intervalText: '5h  \u{27F3}',
      weeklyText: '1w  \u{27F3}',
      intervalFg: color,
      weeklyFg: Color.lerp(theme.cyan, settledWeekly, t)!,
      hovered: _hovered,
    );
  }

  // ─── Hover-countdown ticker lifecycle ───────────────────────

  /// Decide whether the hover countdown ticker should be
  /// running and start/stop it accordingly. Called from
  /// hover-enter, hover-exit, and every [_onUsage] so the
  /// ticker stays in sync with the latest snapshot and
  /// hover state.
  ///
  /// The ticker is started whenever the user is hovering
  /// and at least one cell has a countdown [Duration]
  /// — regardless of magnitude. The formatted label
  /// changes only at boundary transitions (e.g. `4h 32m`
  /// → `4h 31m`), and the render object's dirty-check
  /// absorbs no-op frames where the string is identical
  /// to the previous one, so the ticker is cheap even for
  /// long-duration countdowns.
  void _syncCountdownTicker() {
    final usage = _usage;
    final shouldTick = _hovered && usage != null &&
        _hasCountdownData(usage);
    if (shouldTick) {
      // Re-anchor every time: even if the ticker is
      // already running, a fresh anchor captures the
      // current effective remaining (which may have
      // changed since the last snapshot or hover
      // entry) so the displayed countdown doesn't
      // drift from the true value.
      _countdownAnchorMs = DateTime.now().millisecondsSinceEpoch;
      _anchorIntervalRemains = _effectiveIntervalRemains(usage);
      _anchorWeeklyRemains = _effectiveWeeklyRemains(usage);
      _countdownTicker ??= TickerRegistry.instance.subscribe(
        name: 'codingPlanCountdown',
        interval: _countdownTickInterval,
        onTick: _tickCountdown,
      );
    } else {
      _countdownTicker?.cancel();
      _countdownTicker = null;
    }
  }

  /// True iff at least one cell has countdown data
  /// (non-null [CodingPlanUsage.intervalRemains] or
  /// [CodingPlanUsage.weeklyRemains]). When true, the
  /// hover countdown ticker can actively decrement the
  /// remaining time.
  bool _hasCountdownData(CodingPlanUsage usage) {
    return usage.intervalRemains != null ||
        usage.weeklyRemains != null;
  }

  /// Effective time-until-reset for the 5h window, i.e.
  /// `intervalRemains - (now - fetchedAt)`, clamped to
  /// `>= 0`. The snapshot's `intervalRemains` is the
  /// value the API reported at `fetchedAt`; any time
  /// between then and now has already elapsed, so the
  /// true remaining is that much smaller. The clamp
  /// protects against the (rare) case where the API
  /// over-reports and `fetchedAt` is already past the
  /// window's reset.
  Duration? _effectiveIntervalRemains(CodingPlanUsage usage) {
    final r = usage.intervalRemains;
    if (r == null) return null;
    final effective = r - DateTime.now().difference(usage.fetchedAt);
    return effective.isNegative ? Duration.zero : effective;
  }

  /// Same as [_effectiveIntervalRemains] but for the
  /// weekly window.
  Duration? _effectiveWeeklyRemains(CodingPlanUsage usage) {
    final r = usage.weeklyRemains;
    if (r == null) return null;
    final effective = r - DateTime.now().difference(usage.fetchedAt);
    return effective.isNegative ? Duration.zero : effective;
  }

  /// Per-tick countdown callback. Decrements the anchor-
  /// based countdown and pushes a fresh frame. Yields to
  /// the animation ticker when both fire in the same
  /// window so the 3-second percentage lerp isn't
  /// interrupted by a seconds-tick flash. Fires the
  /// refresh path when either cell's countdown reaches
  /// zero. The [elapsed] is unused for the countdown
  /// (it's anchored to wall-clock hover entry) but is
  /// plumbed through for symmetry with the ticker
  /// callback signature.
  void _tickCountdown(Duration elapsed) {
    final ro = _renderObject;
    final usage = _usage;
    if (ro == null || usage == null) return;
    // Defensive: hover-exit should have cancelled the
    // ticker, but a late tick in the same frame is
    // possible if the cancellation is racy.
    if (!_hovered) {
      _countdownTicker?.cancel();
      _countdownTicker = null;
      return;
    }
    // Yield to the 3-second animation ticker. The
    // animation pushes percentage-based text
    // (`5h 98.5%`) for its duration; letting the
    // countdown also push `5h 4h 32m 14s` would make
    // the cell flip between forms and read as
    // flicker. The next tick (≤ 250ms later) will
    // resume once the animation finishes.
    if (_animationTicker?.isActive ?? false) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final elapsed = Duration(milliseconds: now - _countdownAnchorMs);

    Duration? intervalRemains = _anchorIntervalRemains == null
        ? null
        : _anchorIntervalRemains! - elapsed;
    Duration? weeklyRemains = _anchorWeeklyRemains == null
        ? null
        : _anchorWeeklyRemains! - elapsed;

    // Clamp to zero. Negative durations would format
    // as `"<1s"` which is technically a valid label
    // but reads as confusing — better to clamp and
    // let the zero check below trigger the refresh.
    if (intervalRemains != null && intervalRemains.isNegative) {
      intervalRemains = Duration.zero;
    }
    if (weeklyRemains != null && weeklyRemains.isNegative) {
      weeklyRemains = Duration.zero;
    }

    _pushHoverCountdownFrame(intervalRemains, weeklyRemains);

    // Refresh when either window's countdown hits
    // zero. [_onTap] handles the refresh-flash
    // spinner + the provider's `refreshNow` call. The
    // new snapshot the stream delivers will restart
    // (or leave stopped) the ticker via [_onUsage].
    final intervalHitZero = _anchorIntervalRemains != null &&
        intervalRemains!.inMilliseconds <= 0;
    final weeklyHitZero = _anchorWeeklyRemains != null &&
        weeklyRemains!.inMilliseconds <= 0;
    if (intervalHitZero || weeklyHitZero) {
      _countdownTicker?.cancel();
      _countdownTicker = null;
      _onTap();
    }
  }

  /// Push a hover frame whose countdown is the
  /// anchor-based value rather than the raw
  /// `usage.formatIntervalRemains()` value. The colour
  /// stays the same ratio-based steady-state colour
  /// ([_ratioColor]) — a cell that was "scarce"
  /// before the countdown shouldn't drift into
  /// "middleground" just because the seconds ticked
  /// down. The render object's dirty check absorbs
  /// frames where the formatted string is identical
  /// to the previous one.
  void _pushHoverCountdownFrame(
    Duration? intervalRemains,
    Duration? weeklyRemains,
  ) {
    final ro = _renderObject;
    final usage = _usage;
    if (ro == null || usage == null) return;
    final theme = CruxTheme.of(context);

    // Build the countdown label for each cell. If the
    // snapshot didn't supply a countdown (null) we
    // fall back to the percentage so the cell never
    // goes blank — same fallback the settled frame
    // uses on hover.
    final intervalInner = intervalRemains != null
        ? formatCodingPlanRemains(intervalRemains)
        : (usage.formatIntervalRemains() ??
            '${usage.intervalRemainingPct.toStringAsFixed(1)}%');
    final weeklyInner = weeklyRemains != null
        ? formatCodingPlanRemains(weeklyRemains)
        : (usage.formatWeeklyRemains() ??
            '${usage.weeklyRemainingPct.toStringAsFixed(1)}%');

    // Same ratio-based colour as the settled frame
    // (afluent / middleground / scarce) but computed
    // against the tick-derived remaining time so the
    // colour follows the countdown — useful when the
    // remaining time approaches the scarce landmark
    // even though the API's percentage hasn't moved.
    final intervalColor = _ratioColor(
      theme,
      _ratio(
        usage.intervalRemainingPct,
        intervalRemains ?? usage.intervalRemains,
        _kIntervalWindow,
      ),
    );
    final weeklyColor = _ratioColor(
      theme,
      _ratio(
        usage.weeklyRemainingPct,
        weeklyRemains ?? usage.weeklyRemains,
        _kWeeklyWindow,
      ),
    );

    ro.update(
      intervalText: '5h $intervalInner',
      weeklyText: '1w $weeklyInner',
      intervalFg: intervalColor,
      weeklyFg: weeklyColor,
      hovered: _hovered,
    );
  }

  /// Total duration of the 5-hour window. Used to
  /// compute the time-elapsed ratio.
  static const Duration _kIntervalWindow = Duration(hours: 5);

  /// Total duration of the 1-week window.
  static const Duration _kWeeklyWindow = Duration(days: 7);

  /// Compute the "quota vs time" ratio for one window.
  ///
  /// The ratio is **`remainingPct / timeRemainingPct`** — how
  /// much quota you have left, divided by how much time
  /// you have left. Three landmarks from the user's spec:
  ///
  ///   * `>= 2.0` → **afluent** (cyan / `theme.accent`).
  ///     "50% quota over 25% time left" — you have a
  ///     comfortable headroom; the cell can spend freely.
  ///   * `1.0` → **middleground** (grey /
  ///     `theme.metricsIdle`). 50% left with 50% time
  ///     left — exactly on pace.
  ///   * `<= 0.5` → **scarce** (yellow / `theme.warning`).
  ///     "Half usage of time left" — running out of
  ///     quota before the window resets.
  ///
  ///   * `remainingPct`: 0–100, the API's
  ///     `current_*_remaining_percent`.
  ///   * `remainingTime`: how long until the window
  ///     resets (Duration, nullable when the API
  ///     omitted it).
  ///   * `totalWindow`: 5h for the short window, 7d
  ///     for the weekly window.
  ///
  /// Example: 26% remaining, 3h to go (5h window).
  /// `timeRemainingPct = 60%`, so `ratio = 26/60 = 0.43`
  /// — just below the scarce landmark, so the cell
  /// renders in the warning colour.
  ///
  /// Returns:
  ///   * `1.0` when the API gave us no countdown (we
  ///     fall back to the raw remaining percentage
  ///     normalised to 0–1).
  ///   * `1.0` when the window just reset (`timeRemaining
  ///     ≈ totalWindow`) — the on-pace midpoint.
  ///   * Otherwise `remainingPct / timeRemainingPct`,
  ///     clamped to `[0, ∞)`.
  double _ratio(
    int remainingPct,
    Duration? remainingTime,
    Duration totalWindow,
  ) {
    if (remainingTime == null) {
      // No countdown from the API — fall back to the
      // raw remaining percentage normalised to 0–1.
      // With no time axis, the ratio degenerates to
      // "how much quota do you have left".
      return remainingPct / 100.0;
    }
    final timeRemainingMs = remainingTime.inMilliseconds;
    if (timeRemainingMs <= 0) {
      // Window has fully elapsed (or the API gave a
      // non-positive value). We have no time left
      // but we still have some quota. ratio = 0 →
      // pure scarce.
      return 0.0;
    }
    // Note: we don't clamp timeRemainingPct at 100%.
    // The API *should* return remainingTime ≤
    // totalWindow, but if it doesn't (e.g. a future
    // window length change), the ratio will correctly
    // trend toward scarce — "you have more time than
    // expected" is exactly the situation the user
    // meant by that zone.
    final timeRemainingPct = (timeRemainingMs /
            totalWindow.inMilliseconds *
            100);
    if (timeRemainingPct <= 0) {
      // Defensive: totalWindow is zero or some other
      // pathological state. Fall back to the worst
      // scarce rather than dividing by zero.
      return 0.0;
    }
    return remainingPct / timeRemainingPct;
  }

  /// Map a usage-vs-time ratio to a cell colour.
  ///
  /// The three landmarks — 0.5 (scarce), 1.0
  /// (middleground), 2.0 (afluent) — and the linear
  /// lerps between them come from the user's spec.
  /// Outside the outer landmarks we saturate (pure
  /// warning below 0.5, pure accent above 2.0).
  ///
  /// `CruxThemeData.cyan` is the existing `accent`
  /// field — already theme-defined, already exposed,
  /// already cyan in the dracula default. The user
  /// wanted the colour to separate from the flash
  /// colours (red/green) and the steady warning
  /// (yellow), and the existing accent fits that role
  /// without adding a new theme field.
  Color _ratioColor(CruxThemeData theme, double ratio) {
    if (ratio >= 2.0) return theme.cyan;
    if (ratio >= 1.0) {
      // Lerp middleground (grey) → cyan as ratio goes
      // 1 → 2. Linear lerp on colour is fine here — the
      // ratio axis is the meaningful dimension.
      final t = (ratio - 1.0).clamp(0.0, 1.0);
      return Color.lerp(theme.metricsIdle, theme.cyan, t)!;
    }
    if (ratio >= 0.5) {
      // Lerp warning (yellow) → middleground (grey) as
      // ratio goes 0.5 → 1.
      final t = ((ratio - 0.5) * 2.0).clamp(0.0, 1.0);
      return Color.lerp(theme.warning, theme.metricsIdle, t)!;
    }
    return theme.warning;
  }

  double _lerp(double from, double to, double t) =>
      from + (to - from) * t;

  @override
  Component build(BuildContext context) {
    final canTap = component.onTap != null;
    final theme = CruxTheme.of(context);

    // Button-style container: when clickable, show hover bg
    // and bold on hover, same as the [Button] component.
    final deco = _hovered && canTap
        ? BoxDecoration(color: theme.buttonBackgroundHover)
        : null;

    return GestureDetector(
      onTap: canTap ? _onTap : null,
      behavior: HitTestBehavior.opaque,
      child: MouseRegion(
        onEnter: (_) {
          if (canTap) setState(() => _hovered = true);
          // Start the countdown ticker (if applicable)
          // immediately on hover-enter. Anchor first so
          // the push below uses the live anchored value.
          _syncCountdownTicker();
          _pushCurrentFrame();
        },
        onExit: (_) {
          setState(() => _hovered = false);
          _pushCurrentFrame();
          // Stop ticking on hover-exit. The settled
          // frame above uses the raw snapshot values
          // (no anchor), so un-hovering snaps back to
          // the unmodified countdown.
          _syncCountdownTicker();
        },
        opaque: false,
        child: Container(
          decoration: deco,
          padding: EdgeInsets.zero,
          child: _CodingPlanUsageBridge(
            onRenderObject: (ro) {
              ro.context = context;
              _renderObject = ro;
              // First mount: paint the initial frame.
              _pushCurrentFrame();
            },
          ),
        ),
      ),
    );
  }
}

/// Single-child render object component that exists to
/// give [RenderCodingPlanUsage] a slot in the widget tree
/// and to capture the render-object reference for the
/// widget state to push to. The animation is driven
/// directly from the state via [_pushCurrentFrame] /
/// [_pushSettledFrame] / [_tickAnimation], so this bridge
/// intentionally has no `updateRenderObject` — there's
/// nothing for the framework's reconcile path to push
/// that the state doesn't already handle.
class _CodingPlanUsageBridge
    extends SingleChildRenderObjectComponent {
  final void Function(RenderCodingPlanUsage) onRenderObject;

  const _CodingPlanUsageBridge({required this.onRenderObject});

  @override
  RenderObject createRenderObject(BuildContext context) {
    final ro = RenderCodingPlanUsage(
      intervalText: '',
      weeklyText: '',
      intervalFg: CruxTheme.of(context).metricsIdle,
      weeklyFg: CruxTheme.of(context).metricsIdle,
    );
    onRenderObject(ro);
    return ro;
  }
}

/// Custom render object that paints the coding-plan usage row.
///
/// Holds the data directly, and `update()` only fires
/// `markNeedsPaint()` (not `markNeedsLayout`) when a value
/// actually changes. So an animation frame that delivers
/// identical text/colour to the previous one is a no-op
/// — important for the late-anim frames where the
/// settle-into-equilibrium produces very small deltas.
class RenderCodingPlanUsage extends RenderObject {
  String _intervalText;
  String _weeklyText;
  Color _intervalFg;
  Color _weeklyFg;
  bool _hovered;

  /// Build context of the widget that owns this render
  /// object. Set by the bridge widget so the [State] can
  /// read theme colors when pushing updates without
  /// rebuilding.
  BuildContext? context;

  RenderCodingPlanUsage({
    required String intervalText,
    required String weeklyText,
    required Color intervalFg,
    required Color weeklyFg,
    bool hovered = false,
  })  : _intervalText = intervalText,
        _weeklyText = weeklyText,
        _intervalFg = intervalFg,
        _weeklyFg = weeklyFg,
        _hovered = hovered;

  void update({
    required String intervalText,
    required String weeklyText,
    required Color? intervalFg,
    required Color? weeklyFg,
    required bool hovered,
  }) {
    var dirty = false;
    if (_intervalText != intervalText) {
      _intervalText = intervalText;
      dirty = true;
    }
    if (_weeklyText != weeklyText) {
      _weeklyText = weeklyText;
      dirty = true;
    }
    if (intervalFg != null && _intervalFg != intervalFg) {
      _intervalFg = intervalFg;
      dirty = true;
    }
    if (weeklyFg != null && _weeklyFg != weeklyFg) {
      _weeklyFg = weeklyFg;
      dirty = true;
    }
    if (_hovered != hovered) {
      _hovered = hovered;
      dirty = true;
    }
    // Only repaint when something visible actually
    // changed. The animation's late frames (t close to
    // 1.0) produce very small lerp deltas — when the
    // string representation of the 2-decimal value
    // stops changing (e.g. "97.01%" and "97.00%"), the
    // dirty check absorbs the push without scheduling
    // a paint pass. Cheap idle.
    if (dirty) markNeedsPaint();
  }

  @override
  void setupParentData(RenderObject child) {
    if (child.parentData is! BoxParentData) {
      child.parentData = BoxParentData();
    }
  }

  @override
  void performLayout() {
    // Worst-case width: "  5h 4h 32m / 1w 6d 4h" — the
    // hover-countdown shape is the longest form this
    // widget ever produces. The toolbar's LayoutBuilder
    // budgets 27 cells to match; over-estimating here
    // would just mean the area gets reserved when it
    // could be smaller.
    const worstCaseLen = 27;
    size = Size(worstCaseLen.toDouble(), 1.0);
  }

  @override
  void paint(TerminalCanvas canvas, Offset offset) {
    super.paint(canvas, offset);

    var x = 0.0;
    canvas.drawText(
      offset + Offset(x, 0),
      '  ',
      style: TextStyle(color: Color.defaultColor),
    );
    x += 2;

    canvas.drawText(
      offset + Offset(x, 0),
      _intervalText,
      style: TextStyle(color: _intervalFg),
    );
    x += _intervalText.length;

    canvas.drawText(
      offset + Offset(x, 0),
      ' / ',
      style: TextStyle(color: Color.defaultColor),
    );
    x += 3;

    canvas.drawText(
      offset + Offset(x, 0),
      _weeklyText,
      style: TextStyle(color: _weeklyFg),
    );
  }
}
