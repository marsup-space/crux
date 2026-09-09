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

/// Length in terminal columns above which a [MonitorToastData]
/// takeaway row is clamped with a leading ellipsis.
const int kMonitorToastTakeawayMaxCols = 120;

/// Everything the toast needs to render one auxiliary-shell-monitor
/// report. Fully formatted (i18n applied by the chat panel when it
/// builds this from a `ShellMonitorNotice`), so the toast component
/// stays presentation-only.
class MonitorToastData {
  /// Primary subject — the agent's phrase for WHY this shell is
  /// running (the tool call's intent), already localized.
  final String title;

  /// Optional secondary subject: the command line, shown only when
  /// the intent is missing.
  final String? subtitle;

  /// Verdict badge: `PROGRESS` / `STUCK` / `UNCERTAIN` /
  /// `EVAL_ERROR` / `FALLBACK` / `ARMED`. Drives the dedicated
  /// verdict row's color and glyph — a distinct line so the aux
  /// model's decision is the visually loudest thing on the toast.
  final String verdict;

  /// How the verdict reads in human terms, already localized
  /// (`looks healthy — next check in 30s` …).
  final String verdictText;

  /// Evidence line — the model's reason and/or the process's last
  /// meaningful output line. May be empty.
  final String takeaway;

  /// Kill action. Resolves to true when a live process was actually
  /// signalled — false means the process had already exited, which
  /// the toast still records as a terminal observation.
  final Future<bool> Function()? onKill;

  /// Invoked after the kill button resolves, so the panel can
  /// notify the main session about the manual kill.
  final VoidCallback? onKilled;

  const MonitorToastData({
    required this.title,
    this.subtitle,
    required this.verdict,
    required this.verdictText,
    this.takeaway = '',
    this.onKill,
    this.onKilled,
  });
}

/// Verdict color policy for the monitor toast's verdict row. STUCK
/// reads as an error (it kills the process), PROGRESS as status, and
/// everything else as info: the verdict is the toast's loudest row
/// and the color carries the meaning at a glance.
ToastMode monitorVerdictMode(String verdict) {
  switch (verdict) {
    case 'STUCK':
      return ToastMode.error;
    case 'PROGRESS':
      return ToastMode.status;
    default:
      return ToastMode.info;
  }
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

  /// Enqueue or REPLACE the standing shell-monitor toast.
  ///
  /// The monitor reports once at arm time and then after every
  /// auxiliary-model evaluation; showing each report as a separate
  /// timed toast would stack indistinguishable copies. Instead there
  /// is AT MOST ONE standing monitor toast: the in-flight one is
  /// cancelled and replaced, the queue is drained of stale monitor
  /// items, and the new one restarts its full display window.
  ///
  /// An item whose user has already killed via the button is
  /// frozen — its report already became history, and a newer
  /// monitor report belongs to a process that no longer exists.
  void showMonitorToast(MonitorToastData data, {Duration? duration}) {
    if (_current is _MonitorToastItem && _current!.killed) return;
    _queue.removeWhere((i) => i is _MonitorToastItem);
    // The verdict drives the toast mode (icon + palette). Currently
    // unused by the info fallback below but kept as the single mode
    // authority if plain-toast mode handling unifies later.
    final mode = monitorVerdictMode(data.verdict);
    final item = _MonitorToastItem(
      message: data.title,
      title: data.title,
      subtitle: data.subtitle,
      data: data,
      mode: mode,
      duration: duration ?? const Duration(seconds: 8),
    );
    if (_current == null) {
      _current = item;
      _remaining = item.duration;
      _startTimers();
    } else if (identical(_current, item)) {
      // Unreachable (fresh item), kept for exhaustiveness.
      _startTimers();
    } else if (_current is _MonitorToastItem) {
      // Replace the in-flight monitor toast in place.
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

  /// Semantic/keyboard entry point for the standing monitor toast's
  /// kill action — mirrors clicking the kill button. Returns whether
  /// a monitor toast was present (and the action ran); false means
  /// no monitor toast is showing.
  Future<bool> pressMonitorKill() async {
    final cur = _current;
    if (cur is! _MonitorToastItem) return false;
    await _handleMonitorKill(cur);
    return true;
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
      onTick: (elapsed) {
        if (!_hovered) {
          // Delta-time countdown: subtract the actual wall-clock
          // delta, not a fixed 50 ms. On a slow frame the
          // countdown ticks down faster; on a fast frame less —
          // total elapsed time still matches the configured
          // toast duration regardless of frame rate.
          _remaining -= elapsed == Duration.zero
              ? const Duration(milliseconds: 50)
              : elapsed;
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
    if (_current?.killed ?? false) return; // frozen incident record
    if (_remaining <= Duration.zero) {
      _onDismiss();
      return;
    }
    _startTimers();
  }

  void _onDismiss() {
    _stopTimers();
    if (_current?.killed ?? false) {
      // A killed monitor toast is an incident record — the countdown
      // timer must not retire it. (The ✕ button force-closes via
      // [_forceAdvance] instead.)
      return;
    }
    _advance();
  }

  /// Close (or queue-advance) ignoring the killed-toast freeze — used
  /// by the ✕ button so the user can always dismiss manually.
  void _forceAdvance() {
    _stopTimers();
    _advance();
  }

  void _advance() {
    if (_queue.isNotEmpty) {
      final next = _queue.removeAt(0);
      next.killed = _current?.killed ?? false; // inherit kill state
      _current = next;
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
    // Always wrap in [MouseRegion] so the render object attached to the
    // parent [Stack] stays stable across rebuilds.
    //
    // Without this, the empty state returned a plain `SizedBox`, then the
    // active state returns `MouseRegion(...)`. The `Positioned` wrapper's
    // parentData (left/right/bottom) is applied once — to the initial
    // SizedBox. When `MouseRegion` later replaces it as the Stack's
    // child render object, the parentData isn't reapplied, so the Stack
    // treats the new render object as non-positioned and gives it tight
    // height constraints (because we use `StackFit.expand`). The toast's
    // [Container] then expands to fill the full stack height and the
    // rounded border paints across every row of the screen.
    //
    // Keeping the [MouseRegion] mounted the whole time means the same
    // render object stays attached, so the parentData stays correct.
    final cur = _current;
    if (cur == null) {
      // No callbacks → no MouseTracker annotation; this MouseRegion is
      // effectively inert and only exists to keep the render tree stable.
      return const MouseRegion(opaque: false, child: SizedBox.shrink());
    }

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
    final isMonitor = cur is _MonitorToastItem;
    final _MonitorToastItem? monitorItem = isMonitor ? cur : null;
    final killed = cur.killed;
    final theme = CruxTheme.of(context);

    // Evidence row for monitor toasts — the model's reason and/or the
    // process's last output line, dimmed so it reads as context.
    final takeaway = monitorItem?.data.takeaway ?? '';
    final takeawayText = takeaway.length > kMonitorToastTakeawayMaxCols
        ? '…${takeaway.substring(takeaway.length - kMonitorToastTakeawayMaxCols)}'
        : takeaway;

    // Monitor toast layout: the verdict is its own colored row so the
    // aux model's decision is the loudest thing on the toast.
    final verdictText = monitorItem?.data.verdictText ?? '';
    final verdictIcon = switch (monitorItem?.data.verdict) {
      'STUCK' => terminalSymbol('\u2716', 'x'), // ✖
      'PROGRESS' => terminalSymbol('\u2714', '+'), // ✔
      'UNCERTAIN' => terminalSymbol('?', '?'),
      _ => terminalSymbol('\u26A1', 'i'), // ⚡
    };
    final verdictColor = switch (monitorVerdictMode(
      monitorItem?.data.verdict ?? '',
    )) {
      ToastMode.error => theme.errorColor,
      ToastMode.status => theme.successColor,
      ToastMode.info => theme.warningColor,
    };

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
                      color: killed ? theme.warningColor : textColor,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (!killed) ...[
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
                      style: TextStyle(
                        color: CruxTheme.of(context).successColor,
                      ),
                    ),
                ],
                Text(' ', style: TextStyle(color: textColor)),
                Button(
                  label: '${terminalSymbol('\u2715', 'x')} ',
                  onPressed: _forceAdvance,
                  color: CruxTheme.of(context).hintText,
                  hoverColor: textColor,
                  bgColor: bgColor,
                  hoverBgColor: bgColor,
                  padding: const EdgeInsets.all(0),
                ),
              ],
            ),
            // ── monitor rows: verdict (loud) → evidence (dim) → kill ──
            if (isMonitor) ...[
              // Verdict row — the aux model's decision, colored + glyph.
              Row(
                children: [
                  Text(
                    '  $verdictIcon ',
                    style: TextStyle(color: verdictColor),
                  ),
                  Text(
                    verdictText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: verdictColor,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              // Evidence row — reason and/or last output line.
              if (takeawayText.isNotEmpty)
                Text(
                  '     $takeawayText',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: theme.hintText),
                ),
              // Kill action row — an unmistakable bracket button.
              Row(
                children: [
                  Text('  ', style: TextStyle(color: textColor)),
                  if (killed)
                    Text(
                      terminalSymbol('✓ killed', '✓ killed'),
                      style: TextStyle(color: theme.successColor),
                    )
                  else if (monitorItem != null)
                    Button(
                      label:
                          '[ ${terminalSymbol('click to kill', 'click to kill')} ]',
                      onPressed: monitorItem.killArmed
                          ? () => _handleMonitorKill(monitorItem)
                          : null,
                      color: theme.errorColor,
                      hoverColor: theme.errorColor,
                      bgColor: bgColor,
                      hoverBgColor: bgColor,
                      padding: const EdgeInsets.all(0),
                    ),
                ],
              ),
            ],
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

  /// Kill button handler: run the shell kill first, then flip state.
  ///
  /// `killArmed` flips synchronously BEFORE any await so double-taps
  /// and the render tick can't fire the callback twice. A kill that
  /// raced an exit (button reports "nothing left to kill") is still a
  /// terminal, verified observation — the frozen record and
  /// `onKilled` still happen, keeping the promise that after every
  /// kill the monitor toast becomes a standing killed-record.
  Future<void> _handleMonitorKill(_MonitorToastItem item) async {
    if (item.killed || !item.killArmed) return;
    item.killArmed = false;
    setState(() {});
    final data = item.data;
    try {
      await data.onKill?.call();
    } catch (_) {
      // The kill action owns its error paths; the toast records the
      // user's decision either way.
    }
    item.killed = true;
    _stopTimers();
    _remaining = item.duration;
    setState(() {});
    data.onKilled?.call();
  }
}

// ---------------------------------------------------------------------------
// _ToastItem
// ---------------------------------------------------------------------------

class _ToastItem {
  final String message;
  final ToastMode mode;
  final Duration duration;

  /// Set once the user kills the monitored process from this toast.
  /// A killed monitor toast (a) never auto-dismisses (its report has
  /// become an incident record) and (b) is not replaced or superseded
  /// by later `showMonitorToast` calls.
  bool killed = false;

  _ToastItem({
    required this.message,
    required this.mode,
    required this.duration,
  });
}

/// A standing shell-monitor toast (see [ToastHubState.showMonitorToast]).
/// The verdict is the star on its own colored row; [title] is the
/// agent's intent phrase.
class _MonitorToastItem extends _ToastItem {
  final MonitorToastData data;

  /// Primary subject line (the intent phrase).
  final String title;

  /// Optional secondary line (the command) for intent-less runs.
  final String? subtitle;

  /// Live flag flipped by the toast's kill handler the instant the
  /// process dies (or is found already dead). Drives the kill button's
  /// enabled state without rebuilding the hub.
  bool killArmed = true;

  _MonitorToastItem({
    required super.message,
    required this.title,
    this.subtitle,
    required this.data,
    required super.mode,
    required super.duration,
  });
}
