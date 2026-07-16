// Context bar paints its progress fill directly on a TerminalCanvas for
// smooth lerp animation. TerminalCanvas is nocterm's internal paint surface.
// ignore_for_file: implementation_imports

import 'package:meta/meta.dart';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm/src/framework/terminal_canvas.dart';
import '../services/chat_service.dart';
import '../theme/crux_theme.dart';
import 'session_controller.dart';
import 'streaming_controller.dart';
import '../utils/ticker_registry.dart';

/// Context-window usage bar.
///
/// Has its own [State] and a 16ms lerp [TickerToken] that interpolates
/// from the runtime's `contextTargetTokens` (the "true" value
/// that jumps when a new chunk arrives) toward the displayed
/// value. Critical: the lerp ticks update this widget's
/// own render object directly — they do NOT call `setState`,
/// do NOT trigger a chat-panel rebuild, and do NOT even
/// rebuild this widget's subtree. The chat panel only needs
/// to know there's paint work; the [RenderContextBar] fires
/// `markNeedsPaint()` on itself, which propagates up to the
/// root, and the next paint frame draws the new bar.
///
/// Why this matters: previously the chat panel rebuilt every
/// 16ms during streaming because [setState] on a parent
/// widget triggered a full chat-panel rebuild, costing 80ms+
/// per frame and dropping the UI to ~12 FPS on sessions with
/// hundreds of messages. By isolating the repaint to just
/// the bar's render object, the cost drops to a single
/// `markNeedsPaint` propagation.
class ContextBar extends StatefulComponent {
  final SessionController sessionController;
  final StreamingController streamingController;
  final int contextMaxTokens;
  final VoidCallback? onTap;

  /// Pre-projected token counts for an in-place chat-log
  /// compaction. When non-null, the hover label shows
  /// `postTokens ← preTokens` (e.g. `56k ← 123k`) instead of
  /// the generic `Compact` action label, so the user sees the
  /// expected result of clicking the bar. Pass `null` to fall
  /// back to the bare `Compact` label.
  final ChatLogCompactionEstimate? compactEstimate;

  /// When true, the bar is rendered but not clickable — the
  /// [GestureDetector] gets `onTap: null` and hover effects
  /// are suppressed so the widget doesn't look interactive.
  /// Used to lock out manual compaction while the session is
  /// responding (the runtime guard in `compactCurrentSession`
  /// is a backstop; this is the UX-level gate).
  final bool disabled;

  /// When true, the hover label always shows the projected
  /// `pre → post` estimate instead of `X · skip`, even when
  /// compacting wouldn't save enough tokens to be worth it.
  /// Used by `/debug` mode so the user can see what every
  /// projection looks like — useful for diagnosing why a
  /// compact gate is firing (or not). Wired from
  /// [CommandRegistry.debugEnabled] by the chat panel; the
  /// toolbar / context bar don't import the registry
  /// themselves.
  final bool debugMode;

  const ContextBar({
    super.key,
    required this.sessionController,
    required this.streamingController,
    required this.contextMaxTokens,
    this.onTap,
    this.compactEstimate,
    this.disabled = false,
    this.debugMode = false,
  });

  @override
  State<ContextBar> createState() => ContextBarState();
}

/// Animation lifecycle for [ContextBar]'s state.
///
/// The bar goes `active` → `cooling` → `idle`:
/// - active: streaming is happening, timer is running, bar
///   lerps toward rt.contextTargetTokens.
/// - cooling: streaming just ended, timer keeps running for
///   a short grace period so the lerp can finish smoothly.
/// - idle: nothing happening, timer is stopped.
enum _AnimState { active, cooling, idle }

class ContextBarState extends State<ContextBar>
    with HintStateMixin<ContextBar> {
  static const double _lerpSpeed = 6.0;

  /// The currently displayed token count, lerped from the
  /// runtime's `contextTargetTokens`. Updated on every timer
  /// tick; only the [ContextBar]'s render object marks itself
  /// for repaint — the widget tree is NOT rebuilt.
  double _displayTokens = 0.0;

  /// The session id we last rendered for. Used to detect a
  /// session switch in [build] so we can snap (not lerp) the
  /// bar to the new session's value.
  int? _currentSessionId;

  TickerToken? _animTicker;

  /// Direct reference to the render object. Set by the bridge
  /// widget during mount. We update this object in-place from
  /// the timer — no setState, no _refresh, no rebuild.
  RenderContextBar? _renderObject;

  /// Cached hover state, kept in sync with the streaming
  /// controller. We push updates to the render object when
  /// this changes (no rebuild needed).
  bool _hovered = false;

  /// Whether the animation is active, cooling down, or idle.
  ///
  /// - [active]: streaming is in progress (or we just think it
  ///   is). Timer is running.
  /// - [cooling]: streaming just ended. Timer is still running
  ///   for [_idleGrace] ms so the lerp can finish smoothly to
  ///   the final target value.
  /// - [idle]: nothing happening. Timer is stopped.
  _AnimState _animState = _AnimState.idle;

  /// When [_animState] entered [cooling]. Used by [_tick] to
  /// decide when to transition to [idle] and stop the timer.
  DateTime? _coolingStartedAt;

  /// Last value of `rt.contextTargetTokens` observed in [build].
  /// When the runtime's target changes outside of streaming
  /// (e.g. `/compact` rewrites it while the session is idle),
  /// the diff against [_displayTokens] tells the bar to either
  /// snap (small diff) or kick the lerp timer back on (big diff)
  /// so the visible bar catches up.
  int? _lastSeenTarget;

  /// After streaming ends, keep the lerp running for this
  /// long so the bar settles smoothly to its final value
  /// instead of freezing mid-flight.
  static const Duration _idleGrace = Duration(milliseconds: 100);

  /// Read `contextTargetTokens` for [sessionId] from MetricsCubit.
  ///
  /// The bar's 16ms lerp ticker calls into this on every frame, so
  /// it goes through a direct cubit-state getter instead of a
  /// `BlocSelector` subscription — the ticker itself drives the
  /// repaint and only needs the latest value at this tick.
  /// `contextTargetTokens` is the first runtime field fully cubit-
  /// driven; future slices will move the rest of the bar's runtime
  /// reads (e.g. `isResponding`, `btwMode`, `temperatureOverride`)
  /// onto MetricsCubit the same way.
  int _contextTargetFor(int sessionId) {
    return component.sessionController.metricsCubit.state
        .sessionState(sessionId)
        .contextTargetTokens;
  }

  /// Start the 16ms polling ticker if it isn't already running.
  void _startTimer() {
    if (_animTicker != null) return;
    _animTicker = TickerRegistry.instance.subscribe(
      name: 'contextAnim',
      interval: const Duration(milliseconds: 16),
      onTick: _tick,
    );
  }

  void _stopTimer() {
    _animTicker?.cancel();
    _animTicker = null;
    _animState = _AnimState.idle;
    _coolingStartedAt = null;
  }

  /// Sync the timer with the runtime's streaming state. Runs
  /// while `rt.isResponding` is true OR while we're in the
  /// post-stream grace period. The chat panel rebuilds on
  /// turn start/end (via `_refresh`), which re-runs [build]
  /// and re-evaluates this.
  void _syncTimer() {
    final sessionId = component.sessionController.currentSessionId;
    if (sessionId == null) {
      _stopTimer();
      return;
    }
    final rt = component.sessionController.runtime(sessionId);
    if (rt.isResponding) {
      _animState = _AnimState.active;
      _coolingStartedAt = null;
      _startTimer();
    } else if (_animState == _AnimState.cooling) {
      // In grace period — keep ticking so [_tick] can finish
      // the lerp and time out the grace.
      _startTimer();
    } else {
      _stopTimer();
    }
  }

  String _formatLabel(int displayTokens, int maxTokens, bool hovered) {
    // Hover swap to "Compact" is an affordance — it tells the
    // user what the click does. When the chat panel has a
    // pre-projected compaction estimate, swap the action label
    // for the actual `Y ← X` result so the user can see what
    // they'd get from clicking — e.g. `56k ← 123k`. Only show
    // it when the bar is actually clickable; otherwise the
    // hover label would advertise an action that's been
    // disabled.
    if (hovered && !component.disabled) {
      final est = component.compactEstimate;
      if (est != null) {
        return formatCompactHoverLabel(
          est.preTokens,
          est.postEstimateTokens,
          debugMode: component.debugMode,
        );
      }
      return 'Compact';
    }
    return '${_fmtNum(displayTokens)} / ${_fmtCtx(maxTokens)}';
  }

  /// Render the hover label from a pre→post projection.
  ///
  /// Worth-it case (savings ≥ 5%): `Y ← X` — the arrow points
  /// left because the context bar fills right-to-left as it
  /// shrinks: post (Y) on the left, pre (X) on the right. The
  /// direction matches the bar's visual movement so the user
  /// can read the label and the bar as the same transition.
  ///
  /// Skip case (savings < 5%): `X · skip` — a short verb that
  /// tells the user the click won't save enough to be worth it.
  /// The arrow would mislead (it implies "after, the size
  /// becomes" — but the size barely budges). The 5% threshold
  /// (not just "post ≤ pre") avoids firing compactions that
  /// save only a handful of tokens: those writes would churn
  /// the DB and reset the chat log without delivering real
  /// headroom.
  ///
  /// Debug mode: when [debugMode] is true, always render the
  /// projection as `Y ← X` — even sub-5% savings show up. Used
  /// by `/debug` so the user can see the projection itself and
  /// diagnose why the skip gate fired.
  @visibleForTesting
  static String formatCompactHoverLabel(
    int preTokens,
    int postEstimateTokens, {
    bool debugMode = false,
  }) {
    if (debugMode || isCompactWorthwhile(preTokens, postEstimateTokens)) {
      return '${_fmtCtx(postEstimateTokens)} ← ${_fmtCtx(preTokens)}';
    }
    return '${_fmtCtx(preTokens)} · skip';
  }

  /// True when a compact would not save enough tokens to be
  /// worth firing. Uses a 5% threshold: any savings below that
  /// (`post >= pre * 0.95`) is treated as "skip" because the
  /// churn (DB write, chat log re-render, history re-read on
  /// next launch) outweighs the headroom gained. Drives both:
  ///
  ///   * [formatCompactHoverLabel] → renders `X · skip`
  ///   * the bar's `onTap: null` and the chat panel's
  ///     `_executeCommand` / `createChatLogCompaction` gates
  ///
  /// ...so every entry point (hover, click, `/compact`, auto)
  /// agrees on the same rule.
  ///
  /// `null` estimate (cache miss / pre-hydration) is treated as
  /// "not counterproductive" — let the real projection decide.
  /// `pre <= 0` (fresh session, no AI tokens reported yet) is
  /// also treated as "not counterproductive" — there's nothing
  /// meaningful to compare against, and the upstream
  /// `toCompress.isEmpty` check catches the empty-history case
  /// before this gate fires anyway.
  static bool isCompactCounterproductive(ChatLogCompactionEstimate? est) {
    if (est == null) return false;
    final pre = est.preTokens;
    if (pre <= 0) return false;
    return !isCompactWorthwhile(pre, est.postEstimateTokens);
  }

  /// Companion predicate to [isCompactCounterproductive]: returns
  /// true when the projected savings clear the 5% bar. Pure
  /// integer math (`post * 100 < pre * 95`) avoids floating-point
  /// rounding at the boundary.
  static bool isCompactWorthwhile(int preTokens, int postEstimateTokens) {
    if (preTokens <= 0) return false;
    return postEstimateTokens * 100 < preTokens * 95;
  }

  String _fmtNum(int n) => n.toString().replaceAllMapped(
        RegExp(r'\B(?=(\d{3})+(?!\d))'),
        (m) => ',',
      );

  /// Format a token count for the context bar's label. Token
  /// counts are decimal (1k = 1000), not binary (1Ki = 1024) —
  /// the latter is a memory-size convention and the LLM token
  /// numbers in the rest of the UI (e.g. the chat panel's
  /// `356k / 1M` display, the `/compact` toast's `56k ← 123k`)
  /// all use 1000-based grouping. Using 1024 here would make
  /// the bar's `369,096 / 976k` disagree with the hover's
  /// `62k ← 360k` by ~10k (the binary-vs-decimal ratio on a
  /// value in the 100k–1M range) — same number, two different
  /// read-outs. ≥ 1M collapses to a single-letter `M` suffix
  /// so a 1M model doesn't render the bar as `369,096 / 1,000k`.
  ///
  /// Static so [formatCompactHoverLabel] can reuse it without
  /// needing a state instance to render the hover label.
  static String _fmtCtx(int n) {
    if (n >= 1000000) {
      // 1.2M, 12M — one decimal when the millions digit isn't
      // already crowded, none when it is.
      final m = n / 1000000;
      final fractionDigits = m >= 10 ? 0 : 1;
      return '${m.toStringAsFixed(fractionDigits)}M';
    }
    final k = n ~/ 1000;
    return '${k.toString().replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'),
      (m) => ',',
    )}k';
  }

  // =====================================================================
  // HintStateMixin — hover tooltip with context-window summary +
  // loaded-skill list
  // =====================================================================
  //
  // The bar's in-bar label only has room for the token count (or the
  // compact projection), so the "what does this bar do / what's
  // loaded into my context" questions get answered via a hover
  // tooltip instead. Two pieces of info share one tooltip so the
  // user doesn't have to remember to hover two separate widgets.
  //
  // The tooltip is *always* shown — even when no skills are loaded,
  // in which case the loaded-skills line reads `Loaded skills :
  // none` so the user has a clear "feature works, just empty"
  // signal rather than a missing section they have to wonder about.

  /// Tooltip content. Always returns a non-empty string so the
  /// mixin doesn't auto-hide. Composed of two sections:
  ///
  ///   1. The context-window summary — what the bar represents and
  ///      what the click does (or doesn't, when the session is
  ///      running and compaction is gated).
  ///   2. The loaded-skills list — `Loaded skills : <comma list>`
  ///      or `Loaded skills : none` when the set is empty.
  ///
  /// A blank line separates the two so the overlay's word wrap
  /// doesn't run them together visually.
  @override
  String? get hintContent {
    final sessionId = component.sessionController.currentSessionId;
    final names = sessionId == null
        ? const <String>{}
        : component.sessionController.runtime(sessionId).loadedSkillNames;
    final skillsLine = names.isEmpty
        ? 'Loaded skills : none'
        : 'Loaded skills : ${(names.toList()..sort()).join(', ')}';
    final usageBlock = component.disabled
        ? 'Context window usage.\n'
            'Compaction unavailable while the agent is responding.'
        : 'Context window usage.\n'
            'Click to compact the session history.';
    return '$usageBlock\n\n$skillsLine';
  }

    /// Tooltip placement: prefer *below* the bar rather than above.
  /// The bar lives at the very top of the chat panel, so the
  /// overlay's preferred-side attempt of "above" would run off
  /// the top edge of the terminal. Declaring "below" lands
  /// directly on the side that fits without the failed-first
  /// fallback round-trip. The merged hint (usage + skills list)
  /// is 3 lines + a blank separator, so a 4-line tooltip max would
  /// truncate — the placement doesn't change that, but the overlay
  /// still fits it under the bar on a typical terminal.
  @override
  HintPlacement get hintPlacement => HintPlacement.below;

  /// Tooltip height in lines. The hint is 2 lines of usage block +
  /// 1 blank separator + 1 line per ceil(skillChars/tooltipMaxWidth)
  /// of the comma-joined skills list. The overlay's default of 4
  /// lines caps a single skills line to ~38 cells of names, which
  /// truncates any session with more than ~3-4 loaded skills. We
  /// size the tooltip to the actual content so the full inventory
  /// always fits — for a session with 20 skills the hint grows to
  /// ~8 lines, which still fits between the bar and the chat input
  /// on a typical terminal.
  ///
  /// Floor of 4 preserves the overlay's "minimum useful" size for
  /// the no-skills case (so the empty hint still has the same
  /// visual weight as a default 4-line tooltip).
  @override
  int get hintMaxLines {
    final sessionId = component.sessionController.currentSessionId;
    final names = sessionId == null
        ? const <String>{}
        : component.sessionController.runtime(sessionId).loadedSkillNames;
    if (names.isEmpty) {
      // Usage block (2) + blank (1) + 'Loaded skills : none' (1).
      return 4;
    }
    // The skills line is one logical line; the overlay's
    // `_HintTooltip` word-wraps it to fit `tooltipMaxWidth` (40 by
    // default, configurable on the overlay). Each wrap adds a
    // line, so the height is 3 (fixed) + ceil(nameChars / width).
    // We estimate the joined string's character count — the
    // overlay's word-wrap considers spaces, but for a
    // comma-separated list the dominant wrap point is the width
    // boundary, not individual words, so character-count is a
    // good upper bound.
    final joined = (names.toList()..sort()).join(', ');
    // 40 is the overlay's default `tooltipMaxWidth`; if the
    // app's overlay was configured wider, the same logic still
    // holds — we just need a per-cell count. The character /
    // width math is an upper bound (the actual wrap is one less
    // when the line ends on a space), so we add +1 to cover that
    // edge.
    const width = 40;
    return 3 + (joined.length / width).ceil() + 1;
  }

  /// Override the mixin's default enter handler so the existing
  /// hover-driven in-bar label swap still runs. The
  /// `super.onHintEnter(event)` at the bottom delegates the
  /// tooltip update to the mixin so the loaded-skills hint
  /// still appears.
  @override
  void onHintEnter(MouseEvent event) {
    component.streamingController.contextBarHovered = true;
    _hovered = true;
    // Snap the displayed value to the runtime's current target so
    // the bar's number matches the `post ← pre` shown on hover.
    // Resets the timer to `idle` so the just-snap doesn't get
    // immediately re-driven toward the (now-equal) target by a
    // leftover cooling tick.
    final sessionId = component.sessionController.currentSessionId;
    if (sessionId != null) {
      final target = _contextTargetFor(sessionId).toDouble();
      if ((target - _displayTokens).abs() >= 0.5) {
        _displayTokens = target;
        _animState = _AnimState.idle;
        _coolingStartedAt = null;
        _stopTimer();
      }
    }
    _pushToRenderObject();
    super.onHintEnter(event);
  }

  /// Mirror of [onHintEnter] for the exit side — clears the
  /// hover flag the bar's render path reads, then delegates to
  /// the mixin so the tooltip gets dismissed.
  @override
  void onHintExit(MouseEvent event) {
    component.streamingController.contextBarHovered = false;
    _hovered = false;
    _pushToRenderObject();
    super.onHintExit(event);
  }

  /// When the host rebuilds with a new `ContextBar` instance
  /// (which happens on every chat-panel `_refresh()` — including
  /// the ones fired by `SkillTool.execute` mutations), re-push
  /// the current `hintContent` to the controller. Without this
  /// hook the tooltip would keep stale text painted on screen
  /// until the user moves the mouse, defeating the whole point
  /// of the live loaded-skills list while a tool call is in
  /// flight.
  @override
  void didUpdateComponent(covariant ContextBar oldComponent) {
    super.didUpdateComponent(oldComponent);
    refreshHintFromLastEvent();
  }

  void _tick(Duration elapsed) {
    final sessionId = component.sessionController.currentSessionId;
    if (sessionId == null) {
      _stopTimer();
      return;
    }

    // Session-switch guard. `build()` has the same check, but
    // it only fires on the next chat-panel rebuild (next frame
    // at earliest). This tick path fires every 16ms, so it's
    // the one that actually delivers the "immediate snap" the
    // user expects on session switch. Without it, a tick that
    // lands between `switchSession` updating `currentSessionId`
    // and the next rebuild would lerp from the old session's
    // final value toward the new one for one or more frames
    // before the rebuild's snap corrected it.
    if (_currentSessionId != sessionId) {
      _snapToSession(sessionId);
      return;
    }

    final rt = component.sessionController.runtime(sessionId);

    // If we're in the post-stream grace period, check whether
    // it's expired. Once it has, the bar settles and the
    // timer stops.
    if (_animState == _AnimState.cooling) {
      final started = _coolingStartedAt;
      if (started != null &&
          DateTime.now().difference(started) >= _idleGrace) {
        _displayTokens = _contextTargetFor(sessionId).toDouble();
        _pushToRenderObject();
        _stopTimer();
        return;
      }
    } else if (!rt.isResponding && _animState == _AnimState.active) {
      // Streaming just ended (between the last [_syncTimer]
      // call and this tick, or because the chat panel hasn't
      // rebuilt yet). Enter the cooling phase so the lerp can
      // settle.
      _animState = _AnimState.cooling;
      _coolingStartedAt = DateTime.now();
    }

    final target = _contextTargetFor(sessionId);
    final targetDouble = target.toDouble();
    final diff = targetDouble - _displayTokens;

    if (diff.abs() < 0.5) {
      // Close enough to the target. If we were cooling, this
      // is the natural end — stop the timer now (don't wait
      // for the full grace period).
      _displayTokens = targetDouble;
      _pushToRenderObject();
      if (_animState == _AnimState.cooling) {
        _stopTimer();
      }
      return;
    }

    // Delta-time lerp: advance `_displayTokens` by an amount
    // proportional to the actual wall-clock time since the
    // previous tick, not a fixed 16 ms step. On a slow frame
    // the lerp moves further; on a fast frame less. `_lerpSpeed`
    // is the per-second rate of convergence, so multiplying by
    // `dt` (seconds) keeps the unit math consistent.
    final dt = elapsed == Duration.zero
        ? 0.016
        : elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    _displayTokens += diff * (dt * _lerpSpeed);
    _pushToRenderObject();
  }

  /// Push the current [_displayTokens] and hover state to the
  /// render object. The setters fire `markNeedsPaint()` so the
  /// visual update is scheduled without a single rebuild.
  void _pushToRenderObject() {
    final ro = _renderObject;
    if (ro == null) return;
    final display = _displayTokens.round();
    final fillRatio =
        (display / component.contextMaxTokens).clamp(0.0, 1.0);
    ro.update(
      fillRatio: fillRatio,
      label: _formatLabel(display, component.contextMaxTokens, _hovered),
    );
  }

  /// Snap the bar to [sessionId]'s current context target and
  /// stop the animation timer. Called from two places:
  ///
  /// 1. `build()` when the widget is rebuilt for a new session
  ///    (next-frame path).
  /// 2. `_tick()` when the 16ms timer fires after a session
  ///    switch but before the rebuild (fast path — this is
  ///    what delivers the "immediate snap" UX).
  ///
  /// Both paths converge on this helper so the snap behavior
  /// can't drift: the displayed value becomes the new session's
  /// `contextTargetTokens` exactly, and the lerp timer is
  /// stopped so we don't continue animating toward the new
  /// target (which would be visually misleading — it would
  /// imply the new session is consuming those tokens).
  void _snapToSession(int sessionId) {
    _currentSessionId = sessionId;
    final target = _contextTargetFor(sessionId);
    _displayTokens = target.toDouble();
    _lastSeenTarget = target;
    _pushToRenderObject();
    _stopTimer();
  }

  @override
  void dispose() {
    _stopTimer();
    super.dispose();
  }

  @override
  Component build(BuildContext context) {
    final sessionId = component.sessionController.currentSessionId;
    if (sessionId == null) {
      _stopTimer();
      _currentSessionId = null;
      return const SizedBox();
    }

    // Detect session switch — snap to the new session's
    // target without animating. Otherwise the bar would lerp
    // from session A's final value to session B's, which is
    // visually misleading (it implies session B is consuming
    // those tokens). The fast path of this same check lives
    // in [_tick] so a 16ms timer tick between `switchSession`
    // and the next rebuild also snaps immediately rather
    // than animating from the old session's value.
    if (_currentSessionId != sessionId) {
      _snapToSession(sessionId);
    } else {
      // Same session but the target changed under us (e.g.
      // `/compact` just rewrote `rt.contextTargetTokens` to
      // the post-compaction size while the session is idle).
      // The lerp timer is only running while `isResponding`
      // (see [_syncTimer]), so without this check the bar
      // would stay stuck on its pre-compaction displayed
      // value forever — the chat panel rebuilds, the new
      // target is sitting on `rt`, but `_displayTokens` only
      // advances inside `_tick`. Spin up the lerp timer for
      // a brief settling window so the bar animates to the
      // new value instead of jumping instantly (matching the
      // streaming-end settle behaviour) and then stops.
      final target = _contextTargetFor(sessionId);
      if (target != _lastSeenTarget) {
        _lastSeenTarget = target;
        if ((target - _displayTokens).abs() >= 0.5) {
          _animState = _AnimState.cooling;
          _coolingStartedAt = DateTime.now();
          _startTimer();
        } else {
          _displayTokens = target.toDouble();
          _pushToRenderObject();
        }
      }
    }

    // Sync the timer with the streaming state. Runs only
    // while `isResponding` — otherwise the bar would tick
    // pointlessly forever. On end-of-turn the chat panel
    // rebuilds, build() sees isResponding=false, and the
    // timer stops.
    _syncTimer();

    // Sync hover state in case the streaming controller
    // changed it between builds.
    _hovered = component.streamingController.contextBarHovered;

    final theme = CruxTheme.of(context);
    // Hover-driven color swap advertises "this is clickable".
    // When the bar is disabled (session is running), force the
    // non-hover palette so the widget doesn't visually pretend
    // to be a button.
    final showHovered = _hovered && !component.disabled;
    final fillColor =
        showHovered ? theme.metricsActive : theme.progressFill;
    final emptyColor = theme.progressEmpty;
    final labelFillFg =
        showHovered ? theme.outlineDim : theme.buttonBackground;
    final labelEmptyFg =
        showHovered ? theme.metricsActive : theme.progressLabelEmpty;

    return buildWithHint(
      GestureDetector(
        // `onTap: null` makes the GestureDetector a no-op for
        // taps — the runtime guard in `compactCurrentSession`
        // remains as a backstop, but the UX-level gate lives
        // here so the click never reaches the orchestrator
        // while the session is running.
        onTap: component.disabled ? null : component.onTap,
        behavior: HitTestBehavior.opaque,
        child: _ContextBarBridge(
          width: 20,
          initialFillRatio:
              (_displayTokens / component.contextMaxTokens).clamp(0.0, 1.0),
          initialLabel: _formatLabel(
            _displayTokens.round(),
            component.contextMaxTokens,
            _hovered,
          ),
          fillColor: fillColor,
          emptyColor: emptyColor,
          labelFillFg: labelFillFg,
          labelEmptyFg: labelEmptyFg,
          onRenderObject: (ro) {
            _renderObject = ro;
            // Push the current state to the freshly-mounted
            // render object so it doesn't render stale initial
            // values.
            _pushToRenderObject();
          },
        ),
      ),
    );
  }
}

/// Single-child render object component that owns the
/// [RenderContextBar]. Captures the render object via a
/// callback so the [State] can update it directly without
/// rebuilding.
class _ContextBarBridge extends SingleChildRenderObjectComponent {
  final int width;
  final double initialFillRatio;
  final String initialLabel;
  final Color fillColor;
  final Color emptyColor;
  final Color labelFillFg;
  final Color labelEmptyFg;
  final void Function(RenderContextBar) onRenderObject;

  const _ContextBarBridge({
    required this.width,
    required this.initialFillRatio,
    required this.initialLabel,
    required this.fillColor,
    required this.emptyColor,
    required this.labelFillFg,
    required this.labelEmptyFg,
    required this.onRenderObject,
  });

  @override
  RenderObject createRenderObject(BuildContext context) {
    final ro = RenderContextBar(
      width: width,
      fillRatio: initialFillRatio,
      label: initialLabel,
      fillColor: fillColor,
      emptyColor: emptyColor,
      labelFillFg: labelFillFg,
      labelEmptyFg: labelEmptyFg,
    );
    onRenderObject(ro);
    return ro;
  }
}

/// Custom render object that paints the progress bar. Holds
/// the data directly and updates it via setters that fire
/// `markNeedsPaint()`. This is the entire point of the
/// refactor: data updates skip the rebuild path entirely.
class RenderContextBar extends RenderObject {
  final int _width;
  double _fillRatio;
  String _label;
  final Color _fillColor;
  final Color _emptyColor;
  final Color _labelFillFg;
  final Color _labelEmptyFg;

  RenderContextBar({
    required int width,
    required double fillRatio,
    required String label,
    required Color fillColor,
    required Color emptyColor,
    required Color labelFillFg,
    required Color labelEmptyFg,
  })  : _width = width,
        _fillRatio = fillRatio,
        _label = label,
        _fillColor = fillColor,
        _emptyColor = emptyColor,
        _labelFillFg = labelFillFg,
        _labelEmptyFg = labelEmptyFg;

  /// Setter that the [State] calls on every timer tick.
  /// No-ops if the value hasn't changed, and otherwise
  /// calls `markNeedsPaint()` (not `markNeedsLayout` —
  /// size is fixed at [_width] × 1).
  void update({required double fillRatio, required String label}) {
    var dirty = false;
    if (_fillRatio != fillRatio) {
      _fillRatio = fillRatio;
      dirty = true;
    }
    if (_label != label) {
      _label = label;
      dirty = true;
    }
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
    // Fixed size: the bar is always `_width` cells wide and
    // 1 row tall. No need to ask the parent for constraints.
    size = Size(_width.toDouble(), 1.0);
  }

  @override
  void paint(TerminalCanvas canvas, Offset offset) {
    super.paint(canvas, offset);

    // The bar is `_width` discrete cells, so a raw fill ratio of 0.37
    // on a 20-cell bar is "7 full cells + 0.4 of the next cell". Rather
    // than hard-snapping to 7 cells (which loses 40% of the partial
    // cell's worth of resolution and makes 1–5% usage all look empty),
    // we lerp the *leading-edge* cell's background between
    // [_emptyColor] and [_fillColor]. This gives smooth, continuous
    // resolution at the cost of one cell being a blended color.
    final rawFill = _fillRatio * _width;
    final filledCount = rawFill.floor();
    final partial = rawFill - filledCount; // 0..1, weight of the edge cell
    // Only one cell gets the interpolated bg, and only if there's a
    // non-zero partial AND there's still a cell to place it in (avoids
    // an out-of-bounds boundary when fillRatio is exactly 1.0).
    final boundaryIdx =
        (partial > 0.0 && filledCount < _width) ? filledCount : -1;

    final labelLen = _label.length;
    final labelStart = (_width - labelLen) ~/ 2;

    for (var i = 0; i < _width; i++) {
      final Color bg;
      if (i < filledCount) {
        bg = _fillColor;
      } else if (i == boundaryIdx) {
        bg = Color.lerp(_emptyColor, _fillColor, partial)!;
      } else {
        bg = _emptyColor;
      }

      final labelIndex = i - labelStart;
      if (labelLen > 0 && labelIndex >= 0 && labelIndex < labelLen) {
        // For the boundary cell, pick the label fg for whichever side
        // dominates — a 50/50 blend would be muddy against either pure
        // fg. Fully-filled and fully-empty cells use their dedicated
        // fg as before.
        final Color fg;
        if (i < filledCount) {
          fg = _labelFillFg;
        } else if (i == boundaryIdx && partial >= 0.5) {
          fg = _labelFillFg;
        } else {
          fg = _labelEmptyFg;
        }
        canvas.drawText(
          offset + Offset(i.toDouble(), 0),
          _label[labelIndex],
          style: TextStyle(color: fg, backgroundColor: bg),
        );
      } else {
        canvas.drawText(
          offset + Offset(i.toDouble(), 0),
          ' ',
          style: TextStyle(backgroundColor: bg),
        );
      }
    }
  }
}
