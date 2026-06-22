import 'dart:async';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm/src/framework/terminal_canvas.dart';
import '../models/session_runtime_state.dart';
import '../theme/crux_theme.dart';
import '../utils/ticker_registry.dart';
import 'session_controller.dart';
import 'streaming_controller.dart';

/// Live tok/s and TTFT readout for the chat toolbar.
///
/// Has its own [State] and a 50ms [Timer] that recomputes the
/// displayed values from the runtime. Critical: the timer
/// ticks update the [RenderMetricsDisplay]'s data directly —
/// they do NOT call `setState`, do NOT trigger a chat-panel
/// rebuild, and do NOT even rebuild this widget's subtree.
/// The render object fires `markNeedsPaint()` on itself, which
/// propagates up to the root, and the next paint frame draws
/// the new values.
///
/// Why this matters: previously the chat panel rebuilt every
/// 50ms during streaming because [setState] on a parent
/// widget triggered a full chat-panel rebuild, costing
/// measurable per-frame work and creating layout churn on the
/// whole toolbar.
class MetricsDisplay extends StatefulComponent {
  final SessionController sessionController;
  final StreamingController streamingController;
  final int? currentSessionId;

  const MetricsDisplay({
    super.key,
    required this.sessionController,
    required this.streamingController,
    this.currentSessionId,
  });

  @override
  State<MetricsDisplay> createState() => _MetricsDisplayState();
}

class _MetricsDisplayState extends State<MetricsDisplay> {
  static const Duration _interval = Duration(milliseconds: 50);

  /// The session id whose metrics are being shown. We bind
  /// to a specific session id rather than "whatever the
  /// current session is right now" so a session switch
  /// cleanly tears down the old ticker and starts a new one
  /// for the new session (or stops it if the new session
  /// isn't responding).
  int? _activeSessionId;
  TickerToken? _ticker;

  /// Cached hover state. We push updates to the render
  /// object when this changes (no rebuild needed).
  bool _hovered = false;

  /// Direct reference to the render object. Set by the bridge
  /// widget during mount.
  RenderMetricsDisplay? _renderObject;

  void _syncTimer() {
    final sessionId = component.currentSessionId;
    if (sessionId == null) {
      _stopTimer();
      _pushToRenderObject();
      return;
    }
    // Always start the timer when we have an active session.
    // The chat panel does NOT rebuild on isResponding changes
    // (we removed `_refresh()` on chunks), so we can't rely on
    // build() to start the timer when streaming begins. The
    // timer is cheap (~0 idle CPU when isResponding is false
    // because updateLiveMetrics returns early), so we just keep
    // it running.
    _startTimer(sessionId);
    _pushToRenderObject();
  }

  void _startTimer(int sessionId) {
    if (_ticker != null && _activeSessionId == sessionId) return;
    _stopTimer();
    _activeSessionId = sessionId;
    _ticker = TickerRegistry.instance.subscribe(
      name: 'metricsTimer',
      interval: _interval,
      onTick: (elapsed) {
        // The metrics tick is read-only on the elapsed delta;
        // `updateLiveMetrics` recomputes from wall-clock anyway
        // (it reads DateTime.now() against the runtime's
        // response start). We still receive `elapsed` here for
        // API symmetry — it documents that this is a delta-time
        // callback and makes future conversions (e.g. moving the
        // metric to a true accumulator) cheap.
        component.streamingController.updateLiveMetrics(sessionId);
        _pushToRenderObject();
      },
    );
  }

  void _stopTimer() {
    _ticker?.cancel();
    _ticker = null;
    _activeSessionId = null;
  }

  @override
  void dispose() {
    _stopTimer();
    super.dispose();
  }

  String _cacheHitLabel(SessionRuntimeState rt) {
    if (rt.cacheHitPct != null) {
      return 'cache ${rt.cacheHitPct}%';
    }
    final session = component.sessionController.findSession(rt.sessionId);
    if (session == null) return '—';
    final hit = session.promptCacheHitTokens;
    final total = session.tokensIn;
    if (total > 0 && hit > 0) {
      return 'cache ${((hit / total) * 100).round()}%';
    }
    return '—';
  }

  /// Read the current metrics and push them to the render
  /// object. Called on every timer tick and on every build.
  void _pushToRenderObject() {
    final ro = _renderObject;
    if (ro == null) return;

    final sessionId = component.currentSessionId;
    if (sessionId == null) {
      ro.update(tokText: '— tok/s', ttftText: '—', fg: null, hovered: _hovered);
      return;
    }
    final rt = component.sessionController.runtime(sessionId);
    final tokText = rt.isResponding
        ? '${rt.tokPerSec.toStringAsFixed(1)} tok/s'
        : rt.tokPerSec > 0
            ? '${rt.tokPerSec.toStringAsFixed(1)} tok/s'
            : '— tok/s';
    final ttftText = rt.isResponding
        ? component.streamingController.formatTtft(rt.ttftMs)
        : rt.ttftMs > 0
            ? component.streamingController.formatTtft(rt.ttftMs)
            : '—';
    final fg = rt.isResponding
        ? CruxTheme.of(ro.context!).metricsActive
        : CruxTheme.of(ro.context!).metricsIdle;
    ro.update(
      tokText: _hovered ? _cacheHitLabel(rt) : tokText,
      ttftText: ttftText,
      fg: fg,
      hovered: _hovered,
    );
  }

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);

    // Ensure the metrics timer is synced with the current session
    // state. This must be called here (not just in onRenderObject)
    // because onRenderObject only fires on createRenderObject (first
    // mount). On subsequent rebuilds (e.g. when isResponding becomes
    // true at turn start), updateRenderObject is called instead, so
    // _syncTimer() would never re-run if it were only in onRenderObject.
    _syncTimer();

    return MouseRegion(
      onEnter: (_) {
        _hovered = true;
        _pushToRenderObject();
      },
      onExit: (_) {
        _hovered = false;
        _pushToRenderObject();
      },
      opaque: false,
      child: _MetricsDisplayBridge(
        initialTokText: '— tok/s',
        initialTtftText: '—',
        initialFg: theme.metricsIdle,
        onRenderObject: (ro) {
          ro.context = context;
          _renderObject = ro;
          _pushToRenderObject();
        },
      ),
    );
  }
}

/// Single-child render object component that owns the
/// [RenderMetricsDisplay]. Captures the render object via a
/// callback so the [State] can update it directly without
/// rebuilding.
class _MetricsDisplayBridge extends SingleChildRenderObjectComponent {
  final String initialTokText;
  final String initialTtftText;
  final Color initialFg;
  final void Function(RenderMetricsDisplay) onRenderObject;

  const _MetricsDisplayBridge({
    required this.initialTokText,
    required this.initialTtftText,
    required this.initialFg,
    required this.onRenderObject,
  });

  @override
  RenderObject createRenderObject(BuildContext context) {
    final ro = RenderMetricsDisplay(
      tokText: initialTokText,
      ttftText: initialTtftText,
      fg: initialFg,
    );
    onRenderObject(ro);
    return ro;
  }
}

/// Custom render object that paints the metrics row. Holds
/// the data directly and updates it via setters that fire
/// `markNeedsPaint()`. This is the entire point of the
/// refactor: data updates skip the rebuild path entirely.
class RenderMetricsDisplay extends RenderObject {
  String _tokText;
  String _ttftText;
  Color _fg;
  bool _hovered;

  /// The build context of the widget that owns this render
  /// object. Set by the bridge widget so the [State] can
  /// read theme colors when pushing updates without
  /// rebuilding.
  BuildContext? context;

  RenderMetricsDisplay({
    required String tokText,
    required String ttftText,
    required Color fg,
    bool hovered = false,
  })  : _tokText = tokText,
        _ttftText = ttftText,
        _fg = fg,
        _hovered = hovered;

  /// Setter that the [State] calls on every timer tick and
  /// on every build. No-ops if the values haven't changed,
  /// and otherwise calls `markNeedsPaint()` (not
  /// `markNeedsLayout` — the rendered cell count is stable).
  void update({
    required String tokText,
    required String ttftText,
    required Color? fg,
    required bool hovered,
  }) {
    var dirty = false;
    if (_tokText != tokText) {
      _tokText = tokText;
      dirty = true;
    }
    if (_ttftText != ttftText) {
      _ttftText = ttftText;
      dirty = true;
    }
    if (fg != null && _fg != fg) {
      _fg = fg;
      dirty = true;
    }
    if (_hovered != hovered) {
      _hovered = hovered;
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
    // Fixed size estimate; the actual width depends on the
    // text content, but the toolbar's LayoutBuilder handles
    // the budget. We declare the worst-case width so the
    // layout pass reserves room — over-estimating is harmless
    // (it just means the area gets reserved when it could
    // be hidden).
    final tokW = '999.9 tok/s'.length;
    final ttftW = '999.99s'.length;
    size = Size((tokW + ttftW + 3).toDouble(), 1.0);
  }

  @override
  void paint(TerminalCanvas canvas, Offset offset) {
    super.paint(canvas, offset);
    var x = 0.0;
    canvas.drawText(
      offset + Offset(x, 0),
      '  ',
      style: const TextStyle(color: Color.defaultColor),
    );
    x += 2;
    canvas.drawText(
      offset + Offset(x, 0),
      _tokText,
      style: TextStyle(color: _fg),
    );
    x += _tokText.length + 1;
    canvas.drawText(
      offset + Offset(x, 0),
      ' ',
      style: const TextStyle(color: Color.defaultColor),
    );
    x += 1;
    canvas.drawText(
      offset + Offset(x, 0),
      _ttftText,
      style: TextStyle(color: _fg),
    );
  }
}
