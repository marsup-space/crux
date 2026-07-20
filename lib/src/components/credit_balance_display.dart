// Credit-balance display paints a progress bar directly on a TerminalCanvas.
// TerminalCanvas is nocterm's internal paint surface and isn't re-exported.
// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:math' as math;

import 'package:nocterm/nocterm.dart';
import 'package:nocterm/src/framework/terminal_canvas.dart';

import '../models/credit_balance.dart';
import '../theme/crux_theme.dart';
import '../utils/ticker_registry.dart';

/// Display-only credit balance readout for the chat toolbar.
///
/// Sits to the right of the metrics display and shows the
/// active provider's credit balance (e.g. `¥110.00`). On
/// hover, shows the breakdown: granted vs topped-up.
///
/// The widget is intentionally dumb: it takes a [Stream] of
/// [CreditBalance] snapshots and a starting [initialBalance],
/// and renders the most recent value. The polling lifecycle
/// lives on the `CreditBalanceProvider` mixin; the widget just
/// paints.
///
/// ## Animation
///
/// When a new snapshot arrives and the total balance differs
/// from the previous one, the cell "dramatically" ticks to
/// the new value over 3 seconds:
///
///   * **Decrement** (user spent credits — e.g. ¥110.00 →
///     ¥109.80): the cell flashes red ([CruxThemeData.error])
///     at the moment the new value lands, then lerps back to
///     the cell's normal color. The number ticks down with
///     two-decimal precision so the decrease is visible
///     frame-by-frame.
///
///   * **Increment** (user topped up — e.g. ¥10.00 →
///     ¥110.00): the cell flashes green
///     ([CruxThemeData.success]) and lerps back.
///
/// The animation is driven by [TickerRegistry], running at
/// 16ms (≈60fps). Identical frames are absorbed by
/// [RenderCreditBalance.update]'s dirty check.
class CreditBalanceDisplay extends StatefulComponent {
  /// Stream of balance snapshots. Emits a new [CreditBalance]
  /// each time the provider's polling timer fires
  /// successfully. The widget subscribes for the lifetime of
  /// the state and unsubscribes on dispose.
  final Stream<CreditBalance> stream;

  /// Snapshot to display before the first stream event
  /// arrives. Typically the provider's
  /// `latestCreditBalance` at widget construction time.
  /// If null, the widget renders a "—" placeholder until
  /// the first event lands.
  final CreditBalance? initialBalance;

  /// Called when the user clicks the display to force an
  /// immediate refresh of the credit balance data.
  final VoidCallback? onTap;

  const CreditBalanceDisplay({
    super.key,
    required this.stream,
    this.initialBalance,
    this.onTap,
  });

  @override
  State<CreditBalanceDisplay> createState() =>
      _CreditBalanceDisplayState();
}

class _CreditBalanceDisplayState
    extends State<CreditBalanceDisplay> {
  /// The latest snapshot received.
  CreditBalance? _balance;

  /// Hover state. When true, the cell shows the granted /
  /// topped-up breakdown; when false, it shows the total
  /// balance.
  bool _hovered = false;

  /// Subscription to the provider's stream. Created in
  /// [initState], cancelled in [dispose].
  StreamSubscription<CreditBalance>? _subscription;

  /// Direct reference to the render object.
  RenderCreditBalance? _renderObject;

  // ─── Animation state ──────────────────────────────────────

  /// How long the dramatic lerp takes. Same 3s as the
  /// coding-plan display.
  static const Duration _animationDuration =
      Duration(milliseconds: 3000);

  /// Per-frame tick. Driven by the nocterm frame scheduler
  /// (16ms ≈ 60fps).
  TickerToken? _animationTicker;

  /// Monotonic start time in ms.
  int _animationStartMs = 0;

  /// Value endpoints as doubles (parsed from the total
  /// balance string).
  double _fromValue = 0;
  double _toValue = 0;

  /// Currency symbol for the current balance (e.g. `¥`).
  String _currencySymbol = '¥';

  /// Flash color. Red on decrement, green on increment.
  /// The ticker lerps from this back to the target color.
  Color _flashColor = Color.defaultColor;

  /// Target (settled) color, precomputed when the animation
  /// starts so each per-frame tick just lerps.
  Color _targetColor = Color.defaultColor;

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

  @override
  void initState() {
    super.initState();
    _balance = component.initialBalance;
    _subscription = component.stream.listen(_onBalance);
  }

  @override
  void didUpdateComponent(CreditBalanceDisplay oldComponent) {
    super.didUpdateComponent(oldComponent);
    // Stream identity changed → the active provider/session
    // switched. The running lerp animation (if any) was tied
    // to the *previous* provider's balance; letting it run
    // would cross-fade from one provider's credits into
    // another's with a red/green flash, which is not a
    // meaningful animation. Cancel the animation, reset
    // `_balance` to the new provider's initial snapshot, and
    // paint the settled frame. See the matching comment in
    // CodingPlanUsageDisplay.didUpdateComponent for the full
    // rationale.
    if (oldComponent.stream != component.stream) {
      _subscription?.cancel();
      _subscription = component.stream.listen(_onBalance);
      _animationTicker?.cancel();
      _animationTicker = null;
      _refreshing = false;
      _balance = component.initialBalance;
      _pushCurrentFrame();
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _animationTicker?.cancel();
    _animationTicker = null;
    super.dispose();
  }

  // ─── Stream / animation lifecycle ────────────────────────

  void _onBalance(CreditBalance balance) {
    if (!mounted) return;
    final prev = _balance;
    _balance = balance;
    // When the stream delivers fresh data, clear the
    // refresh-flash state so normal rendering resumes.
    _refreshing = false;
    if (prev != null) {
      _startAnimation(prev, balance);
    }
    _pushCurrentFrame();
    setState(() {});
  }

  /// Begin a 3-second lerp from [from] to [to]. Picks the
  /// flash color (red for decrement, green for increment).
  void _startAnimation(CreditBalance from, CreditBalance to) {
    final prevTotal = _parseTotal(from);
    final nextTotal = _parseTotal(to);
    if (prevTotal == null || nextTotal == null) return;
    // No change → no animation.
    if ((prevTotal - nextTotal).abs() < 0.001) return;

    final theme = CruxTheme.of(context);
    _animationStartMs = DateTime.now().millisecondsSinceEpoch;
    _fromValue = prevTotal;
    _toValue = nextTotal;
    _flashColor = nextTotal < prevTotal ? theme.error : theme.success;
    _currencySymbol = to.primaryBalance?.symbol ?? '¥';
    _targetColor = to.isAvailable ? theme.cyan : theme.warning;

    _animationTicker ??= TickerRegistry.instance.subscribe(
      name: 'creditBalanceAnimation',
      interval: const Duration(milliseconds: 16),
      onTick: _tickAnimation,
    );
  }

  /// Per-frame animation callback. Lerps the displayed value
  /// (2-decimal precision) and the colour (flash → target,
  /// cubic eased). The [elapsed] is the wall-clock delta from
  /// the scheduler; we still compute progress against the
  /// animation's wall-clock start time (so the animation
  /// duration is preserved), but receiving the delta lets us
  /// verify the timeline advances in real time rather than
  /// assuming 16 ms per tick.
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
      _pushSettledFrame();
      return;
    }

    // Value: linear lerp on the raw double.
    final value = _fromValue + (_toValue - _fromValue) * t;

    // Colour: cubic ease-out from flash → target.
    final colorT = 1.0 - math.pow(1.0 - t, 3).toDouble();
    final fg = Color.lerp(_flashColor, _targetColor, colorT)!;

    final text = _hovered
        ? _buildHoverText(value)
        : '$_currencySymbol${value.toStringAsFixed(2)}';

    ro.update(text: text, fg: fg);
  }

  /// Push either the current animation frame or the settled
  /// frame.
  void _pushCurrentFrame() {
    final ticker = _animationTicker;
    if (ticker != null && ticker.isActive) {
      _tickAnimation(Duration.zero);
    } else if (_refreshing) {
      _pushRefreshFrame();
    } else {
      _pushSettledFrame();
    }
  }

  /// Push the post-animation value: integer-like display
  /// (or countdown on hover), normal colour.
  void _pushSettledFrame() {
    final ro = _renderObject;
    if (ro == null) return;
    final balance = _balance;
    if (balance == null) {
      final theme = CruxTheme.of(context);
      ro.update(text: 'Bal —', fg: theme.metricsIdle);
      return;
    }
    final theme = CruxTheme.of(context);
    final fg = balance.isAvailable ? theme.cyan : theme.warning;
    if (_hovered) {
      final b = balance.primaryBalance;
      if (b != null) {
        ro.update(
          text: '${b.symbol}${b.totalBalance} '
              '(${b.symbol}${b.toppedUpBalance})',
          fg: fg,
        );
      } else {
        ro.update(text: 'Bal —', fg: theme.metricsIdle);
      }
    } else {
      final formatted = balance.formatPrimary();
      if (formatted != null) {
        ro.update(text: formatted, fg: fg);
      } else {
        ro.update(text: 'Bal —', fg: theme.metricsIdle);
      }
    }
  }

  // ─── Refresh-flash lifecycle ──────────────────────────────

  /// Called from [build] when the user taps the display.
  /// Kicks off the refresh-flash spinner and delegates
  /// to [component.onTap] for the actual fetch.
  void _onTap() {
    if (_refreshing) return; // double-click guard
    _refreshing = true;
    _refreshStartMs = DateTime.now().millisecondsSinceEpoch;
    // Push the spinner frame immediately so the user
    // sees feedback on the very next paint.
    _pushCurrentFrame();
    // Fire the provider's refresh (invokes _tick(), which
    // calls getCreditBalance(), which feeds the stream).
    component.onTap?.call();
  }

  /// Render the refresh-flash spinner: `⟳` in the accent
  /// colour, fading back to the settled colour over
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
      // Flash timed out — revert to settled.
      _refreshing = false;
      _pushSettledFrame();
      return;
    }

    // Fade from accent (cyan) back to the normal balance
    // colour. Linear fade works for a ~600ms span.
    final settledFg = _balance?.isAvailable == true
        ? theme.cyan
        : theme.warning;
    final fg = Color.lerp(theme.cyan, settledFg, t)!;

    ro.update(text: '$_currencySymbol \u{27F3}', fg: fg);
  }

  /// Build hover text for an intermediate animation value.
  /// Shows the ticking total plus a static topped-up
  /// breakdown from the latest snapshot.
  String _buildHoverText(double animTotal) {
    final b = _balance?.primaryBalance;
    if (b == null) {
      return '$_currencySymbol${animTotal.toStringAsFixed(2)}';
    }
    return '$_currencySymbol${animTotal.toStringAsFixed(2)} '
        '(${b.symbol}${b.toppedUpBalance})';
  }

  /// Parse the total balance string from a snapshot's primary
  /// balance as a double. Returns null on parse failure.
  static double? _parseTotal(CreditBalance balance) {
    final b = balance.primaryBalance;
    if (b == null) return null;
    return double.tryParse(b.totalBalance);
  }

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
          _pushCurrentFrame();
        },
        onExit: (_) {
          setState(() => _hovered = false);
          _pushCurrentFrame();
        },
        opaque: false,
        child: Container(
          decoration: deco,
          padding: EdgeInsets.zero,
          child: _CreditBalanceBridge(
            onRenderObject: (ro) {
              ro.context = context;
              _renderObject = ro;
              _pushCurrentFrame();
            },
          ),
        ),
      ),
    );
  }
}

/// Single-child render object component that gives
/// [RenderCreditBalance] a slot in the widget tree.
class _CreditBalanceBridge
    extends SingleChildRenderObjectComponent {
  final void Function(RenderCreditBalance) onRenderObject;

  const _CreditBalanceBridge({required this.onRenderObject});

  @override
  RenderObject createRenderObject(BuildContext context) {
    final ro = RenderCreditBalance(
      text: '',
      fg: CruxTheme.of(context).metricsIdle,
    );
    onRenderObject(ro);
    return ro;
  }
}

/// Custom render object that paints the credit balance row.
class RenderCreditBalance extends RenderObject {
  String _text;
  Color _fg;

  /// Build context of the widget that owns this render
  /// object. Set by the bridge widget so the [State] can
  /// read theme colors when pushing updates without
  /// rebuilding.
  BuildContext? context;

  RenderCreditBalance({
    required String text,
    required Color fg,
  })  : _text = text,
        _fg = fg;

  void update({
    required String text,
    required Color fg,
  }) {
    var dirty = false;
    if (_text != text) {
      _text = text;
      dirty = true;
    }
    if (_fg != fg) {
      _fg = fg;
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
    // Worst-case width: "  ¥110.00 (¥100.00)" — the hover
    // breakdown shape showing total + topped-up.
    const worstCaseLen = 22;
    size = Size(worstCaseLen.toDouble(), 1.0);
  }

  @override
  void paint(TerminalCanvas canvas, Offset offset) {
    super.paint(canvas, offset);

    canvas.drawText(
      offset + const Offset(0, 0),
      '  ',
      style: TextStyle(color: Color.defaultColor),
    );

    canvas.drawText(
      offset + const Offset(2, 0),
      _text,
      style: TextStyle(color: _fg),
    );
  }
}
