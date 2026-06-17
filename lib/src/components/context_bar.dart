import 'package:nocterm/nocterm.dart';
import 'package:nocterm/src/framework/terminal_canvas.dart';
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

  const ContextBar({
    super.key,
    required this.sessionController,
    required this.streamingController,
    required this.contextMaxTokens,
    this.onTap,
  });

  @override
  State<ContextBar> createState() => _ContextBarState();
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

class _ContextBarState extends State<ContextBar> {
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
  DateTime? _lastTick;

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

  /// After streaming ends, keep the lerp running for this
  /// long so the bar settles smoothly to its final value
  /// instead of freezing mid-flight.
  static const Duration _idleGrace = Duration(milliseconds: 100);

  /// Start the 16ms polling ticker if it isn't already running.
  void _startTimer() {
    if (_animTicker != null) return;
    _lastTick = DateTime.now();
    _animTicker = TickerRegistry.instance.subscribe(
      name: 'contextAnim',
      interval: const Duration(milliseconds: 16),
      onTick: _tick,
    );
  }

  void _stopTimer() {
    _animTicker?.cancel();
    _animTicker = null;
    _lastTick = null;
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
    if (hovered) return 'Compact';
    return '${_fmtNum(displayTokens)} / ${_fmtCtx(maxTokens)}';
  }

  String _fmtNum(int n) => n.toString().replaceAllMapped(
        RegExp(r'\B(?=(\d{3})+(?!\d))'),
        (m) => ',',
      );

  String _fmtCtx(int n) {
    final k = n ~/ 1024;
    return '${k.toString().replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'),
      (m) => ',',
    )}k';
  }

  void _tick() {
    final sessionId = component.sessionController.currentSessionId;
    if (sessionId == null) {
      _stopTimer();
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
        _displayTokens = rt.contextTargetTokens.toDouble();
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

    final target = rt.contextTargetTokens;
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

    final now = DateTime.now();
    final dt = _lastTick == null
        ? 0.016
        : now.difference(_lastTick!).inMilliseconds / 1000.0;
    _lastTick = now;
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

    final rt = component.sessionController.runtime(sessionId);

    // Detect session switch — snap to the new session's
    // target without animating. Otherwise the bar would lerp
    // from session A's final value to session B's, which is
    // visually misleading (it implies session B is consuming
    // those tokens).
    if (_currentSessionId != sessionId) {
      _currentSessionId = sessionId;
      _displayTokens = rt.contextTargetTokens.toDouble();
      _stopTimer();
      _pushToRenderObject();
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
    final fillColor =
        _hovered ? theme.metricsActive : theme.progressFill;
    final emptyColor = theme.progressEmpty;
    final labelFillFg =
        _hovered ? theme.outlineDim : theme.buttonBackground;
    final labelEmptyFg =
        _hovered ? theme.metricsActive : theme.progressLabelEmpty;

    return MouseRegion(
      onEnter: (_) {
        component.streamingController.contextBarHovered = true;
        _hovered = true;
        _pushToRenderObject();
      },
      onExit: (_) {
        component.streamingController.contextBarHovered = false;
        _hovered = false;
        _pushToRenderObject();
      },
      opaque: false,
      child: GestureDetector(
        onTap: component.onTap,
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
  Color _fillColor;
  Color _emptyColor;
  Color _labelFillFg;
  Color _labelEmptyFg;

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
    final filledCount = (_fillRatio * _width).floor();
    final labelLen = _label.length;
    final labelStart = (_width - labelLen) ~/ 2;

    for (var i = 0; i < _width; i++) {
      final isFilled = i < filledCount;
      final bg = isFilled ? _fillColor : _emptyColor;
      final labelIndex = i - labelStart;
      if (labelLen > 0 && labelIndex >= 0 && labelIndex < labelLen) {
        final fg = isFilled ? _labelFillFg : _labelEmptyFg;
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
