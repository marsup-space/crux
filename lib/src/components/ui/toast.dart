import 'package:nocterm/nocterm.dart';
import '../../theme/crux_theme.dart';
import '../../utils/ticker_registry.dart';
import '../../utils/terminal_symbols.dart';
import 'button.dart';

/// The kind of toast notification, which controls the default duration
/// and the icon shown in the left gutter.
enum ToastMode {
  /// Informational toast (default 3 s).
  info,

  /// Error toast (default 5 s).
  error,

  /// Quick status-change toast (default 2 s).
  status,
}

/// Keywords that hint at which [ToastMode] to use when none is supplied
/// explicitly to [ToastHubState.show]. Matched case-insensitively as
/// substrings of the message. The mode key order in this map is the
/// precedence order: `error` beats `status` beats `info`.
const Map<ToastMode, List<String>> _toastKeywords = {
  ToastMode.error: [
    // English
    'error', 'err', 'failed', 'failure', 'fail', 'crash', 'crashed',
    'broken', 'denied', 'refused', 'cannot', "can't", 'exception',
    'fatal', 'invalid', 'missing', 'timeout', 'timed out', 'unable',
    'wrong', 'unsupported', 'unauthorized', 'forbidden', 'not found',
    // Chinese
    '错误', '失败', '异常', '出错', '不行', '崩溃', '无法', '无效',
    '拒绝', '找不到', '不允许', '不支持', '超时', '致命',
    '权限不足', '权限被拒绝', '无权限', '未授权', '未找到',
    '出错了', '发生错误', '出现异常',
  ],
  ToastMode.status: [
    // English
    'done', 'ok', 'okay', 'saved', 'copied', 'loaded', 'ready',
    'complete', 'completed', 'finished', 'success', 'succeeded',
    '✓', '✔', '✅',
    // Chinese
    '完成', '好了', '成功', '加载', '就绪', '完毕', '已保存', '已加载',
    '已复制', '已就绪', '完成啦', '搞定',
  ],
  ToastMode.info: [
    // English (the catch-all; matched last so error/status win when both apply)
    'info', 'information', 'note', 'notice', 'fyi', 'til', 'btw',
    'hint', 'tip', 'reminder',
    // Chinese
    '提示', '通知', '注意', '提醒', '信息', '提示一下', '请注意',
  ],
};

/// Returns the [ToastMode] best matching the given [message], or
/// [ToastMode.info] as a neutral fallback. Matched case-insensitively
/// against the keyword table above. The first matching mode wins, in
/// the precedence order: error → status → info, so more "urgent" modes
/// take precedence.
ToastMode detectToastMode(String message) {
  final lower = message.toLowerCase();
  for (final entry in _toastKeywords.entries) {
    for (final kw in entry.value) {
      if (kw.isEmpty) continue;
      if (lower.contains(kw.toLowerCase())) return entry.key;
    }
  }
  return ToastMode.info;
}

// ---------------------------------------------------------------------------
// ToastHub
// ---------------------------------------------------------------------------

/// A widget that manages a queue of toasts and renders them as overlays.
///
/// Call [ToastHubState.show] to enqueue a new toast.  When a toast is
/// currently visible its countdown is displayed on the right; additional
/// queued toasts are shown as a green "+N" badge next to the countdown.
/// Hovering the mouse over the toast pauses the countdown.
///
/// Example:
/// ```dart
/// final toastKey = GlobalKey<ToastHubState>();
/// // in build:
/// ToastHub(key: toastKey),
/// // later:
/// toastKey.currentState?.show('Something happened');           // auto mode
/// toastKey.currentState?.show('Loaded!', mode: ToastMode.status);
/// ```
class ToastHub extends StatefulComponent {
  const ToastHub({super.key});

  @override
  State<ToastHub> createState() => ToastHubState();
}

class ToastHubState extends State<ToastHub> {
  /// Singleton for uncaught-error routing. Set on [initState], cleared
  /// on [dispose]. Always null-check before calling — it's only live
  /// while a [ToastHub] is mounted in the tree.
  static ToastHubState? get globalInstance => _globalInstance;
  static ToastHubState? _globalInstance;

  final List<_ToastItem> _queue = [];
  _ToastItem? _current;

  SchedulerHandle? _dismissTimer;
  TickerToken? _tickTicker;
  Duration _remaining = Duration.zero;
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _globalInstance = this;
  }

  /// Enqueue a toast.
  ///
  /// [message] is the text to display.
  /// [mode] controls the icon and default duration. When omitted (the
  /// default), [detectToastMode] is run on the message to pick a mode
  /// based on keyword heuristics — falling back to [ToastMode.info].
  ///   - [ToastMode.info]  → 3 s
  ///   - [ToastMode.error] → 5 s
  ///   - [ToastMode.status] → 2 s
  /// [duration] overrides the mode-default duration.
  void show(String message, {ToastMode? mode, Duration? duration}) {
    final effectiveMode = mode ?? detectToastMode(message);
    final effectiveDuration = duration ?? _defaultDuration(effectiveMode);
    final item = _ToastItem(
      message: message,
      mode: effectiveMode,
      duration: effectiveDuration,
    );

    if (_current == null) {
      _current = item;
      _remaining = item.duration;
      _startTimers();
    } else {
      _queue.add(item);
    }
    setState(() {});
  }

  /// Dismiss the current toast immediately and show the next queued one.
  void dismiss() {
    _stopTimers();
    _advance();
  }

  // -- internals -----------------------------------------------------------

  static Duration _defaultDuration(ToastMode mode) => switch (mode) {
    ToastMode.info => const Duration(seconds: 3),
    ToastMode.error => const Duration(seconds: 5),
    ToastMode.status => const Duration(seconds: 2),
  };

  void _startTimers() {
    _stopTimers();
    _dismissTimer = SchedulerBinding.instance.scheduler.once(
      (_) => _onDismiss(),
      delay: _remaining,
      owner: this,
      name: 'toastDismiss',
    );
    _tickTicker = TickerRegistry.instance.subscribe(
      name: 'toastTick',
      interval: const Duration(milliseconds: 50),
      onTick: () {
        if (!_hovered) {
          _remaining -= const Duration(milliseconds: 50);
          if (_remaining.isNegative) _remaining = Duration.zero;
          setState(() {});
        }
      },
    );
  }

  void _stopTimers() {
    _dismissTimer?.cancel();
    _dismissTimer = null;
    _tickTicker?.cancel();
    _tickTicker = null;
  }

  void _pauseTimers() {
    // _remaining is already up-to-date from the last tick.
    _stopTimers();
  }

  void _resumeTimers() {
    if (_remaining <= Duration.zero) {
      _onDismiss();
      return;
    }
    _startTimers();
  }

  void _onDismiss() {
    _stopTimers();
    _advance();
  }

  void _advance() {
    if (_queue.isNotEmpty) {
      _current = _queue.removeAt(0);
      _remaining = _current!.duration;
      _startTimers();
    } else {
      _current = null;
      _remaining = Duration.zero;
    }
    setState(() {});
  }

  // -- hover ---------------------------------------------------------------

  void _onHoverEnter() {
    _hovered = true;
    _pauseTimers();
  }

  void _onHoverExit() {
    _hovered = false;
    _resumeTimers();
  }

  @override
  void dispose() {
    _globalInstance = null;
    _stopTimers();
    super.dispose();
  }

  // -- build ---------------------------------------------------------------

  @override
  Component build(BuildContext context) {
    final cur = _current;
    if (cur == null) return const SizedBox();

    final mode = cur.mode;
    final (
      Color bgColor,
      Color borderColor,
      Color textColor,
      Color iconColor,
      String icon,
    ) = switch (mode) {
      ToastMode.info => (
        CruxTheme.of(context).toastBgInfo,
        CruxTheme.of(context).toastBorderInfo,
        CruxTheme.of(context).toastTextInfo,
        CruxTheme.of(context).toastTextInfo,
        terminalSymbol('\u26A1', 'i'), // ⚡
      ),
      ToastMode.error => (
        CruxTheme.of(context).toastBgError,
        CruxTheme.of(context).toastBorderError,
        CruxTheme.of(context).toastTextError,
        CruxTheme.of(context).toastTextError,
        terminalSymbol('\u2716', 'X'), // ✖
      ),
      ToastMode.status => (
        CruxTheme.of(context).toastBgStatus,
        CruxTheme.of(context).toastBorderStatus,
        CruxTheme.of(context).toastTextStatus,
        CruxTheme.of(context).toastTextStatus,
        terminalSymbol('\u2714', '+'), // ✔
      ),
    };

    final queueCount = _queue.length;
    final remainingSecs = (_remaining.inMilliseconds / 1000.0).clamp(
      0.0,
      cur.duration.inMilliseconds / 1000.0,
    );
    final countdown = remainingSecs.toStringAsFixed(2);
    final isError = mode == ToastMode.error;

    return MouseRegion(
      onEnter: (_) => _onHoverEnter(),
      onExit: (_) => _onHoverExit(),
      opaque: false,
      child: Container(
        decoration: BoxDecoration(
          color: bgColor,
          border: BoxBorder(
            top: BorderSide(color: borderColor, style: BoxBorderStyle.rounded),
            right: BorderSide(
              color: borderColor,
              style: BoxBorderStyle.rounded,
            ),
            bottom: BorderSide(
              color: borderColor,
              style: BoxBorderStyle.rounded,
            ),
            left: BorderSide(color: borderColor, style: BoxBorderStyle.rounded),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 1),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── main row: icon + message + countdown + queue badge + close ──
            Row(
              children: [
                Text(' $icon ', style: TextStyle(color: iconColor)),
                Expanded(
                  child: Text(
                    cur.message,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: textColor,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (_hovered)
                  Text(
                    '(paused) ',
                    style: TextStyle(color: CruxTheme.of(context).hintText),
                  ),
                Text(
                  countdown,
                  style: TextStyle(color: CruxTheme.of(context).hintText),
                ),
                if (queueCount > 0)
                  Text(
                    ' +$queueCount',
                    style: TextStyle(color: CruxTheme.of(context).successColor),
                  ),
                Text(' ', style: TextStyle(color: textColor)),
                Button(
                  label: '${terminalSymbol('\u2715', 'x')} ',
                  onPressed: _onDismiss,
                  color: CruxTheme.of(context).hintText,
                  hoverColor: textColor,
                  bgColor: bgColor,
                  hoverBgColor: bgColor,
                  padding: const EdgeInsets.all(0),
                ),
              ],
            ),
            // ── copy row: only for error toasts ──
            if (isError)
              Button(
                label: '\u2398 Copy error',
                onPressed: () => ClipboardManager.copy(cur.message),
                color: CruxTheme.of(context).hintText,
                hoverColor: textColor,
                bgColor: bgColor,
                hoverBgColor: bgColor,
                padding: EdgeInsets.zero,
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _ToastItem
// ---------------------------------------------------------------------------

class _ToastItem {
  final String message;
  final ToastMode mode;
  final Duration duration;

  const _ToastItem({
    required this.message,
    required this.mode,
    required this.duration,
  });
}
