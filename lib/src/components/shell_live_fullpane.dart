import 'dart:async';

import 'package:nocterm/nocterm.dart';

import '../services/shell_live_registry.dart';
import '../theme/crux_theme.dart';
import '../i18n/strings.dart';
import 'ui/button.dart';
import 'ui/fullpane.dart';

/// Live shell run fullpane — "a terminal for this one command".
///
/// Opened from an executing shell row's `detail` action. Shows:
///
///   * the command (header),
///   * the rolling raw output tail (stdout+stderr interleaved, up to
///     64KB) in a scrollable terminal-styled view that follows the
///     tail while the process runs,
///   * the aux monitor's check timeline (CONFIGURED / verdicts /
///     EVAL_ERROR / FALLBACK) with reasons — the transparency the
///     toast channel used to carry, but persistent and scoped to
///     this run,
///   * a kill button bound to this run's process group (via
///     [ShellLiveRegistry.kill], same agent-visible kill-note path
///     as the monitor toast).
///
/// Polls [ShellLiveRegistry] on a 250ms tick so output and new
/// monitor checks stream in live. The pane stays meaningful after
/// the run finishes (the entry lingers for the registry's TTL) and
/// shows the final state: exit code or killed.
class ShellLiveFullpane extends StatefulComponent {
  final int sessionId;
  final String callId;
  final Strings strings;
  final VoidCallback onClose;

  const ShellLiveFullpane({
    required this.sessionId,
    required this.callId,
    required this.onClose,
    this.strings = kEnglishStrings,
    super.key,
  });

  @override
  State<ShellLiveFullpane> createState() => _ShellLiveFullpaneState();
}

class _ShellLiveFullpaneState extends State<ShellLiveFullpane> {
  static const _pollInterval = Duration(milliseconds: 250);

  Timer? _pollTimer;

  /// Rolling-tail length and notice count at the last rebuild — the
  /// rebuild gate: idle ticks (no new output, no new checks) don't
  /// rebuild, so scroll position never jumps on a quiet pane.
  int _lastTailLen = -1;
  int _lastNoticeCount = -1;
  bool? _lastFinished;

  @override
  void initState() {
    super.initState();
    _pollTimer = Timer.periodic(_pollInterval, (_) {
      if (!mounted) return;
      final entry = ShellLiveRegistry.instance.entryFor(
        component.sessionId,
        component.callId,
      );
      final tailLen = entry?.outputTail.length ?? -1;
      final noticeCount = entry?.monitorNotices.length ?? -1;
      final finished = entry?.finished;
      if (tailLen != _lastTailLen ||
          noticeCount != _lastNoticeCount ||
          finished != _lastFinished) {
        _lastTailLen = tailLen;
        _lastNoticeCount = noticeCount;
        _lastFinished = finished;
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final entry = ShellLiveRegistry.instance.entryFor(
      component.sessionId,
      component.callId,
    );

    final running = entry != null && !entry.finished;

    return Fullpane(
      title: _title(entry),
      onClose: component.onClose,
      strings: component.strings,
      contentBuilder: (context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Command header ──
          _commandHeader(entry, theme),
          Divider(color: theme.outline, height: 1),

          // ── Output tail (terminal view) ──
          Expanded(
            child: _TerminalTailView(
              entry: entry,
              rebuildTick: _lastTailLen,
              emptyText: component.strings.t('shell.live.noOutput'),
            ),
          ),

          Divider(color: theme.outline, height: 1),

          // ── Monitor timeline ──
          _monitorTimeline(entry, theme),

          Divider(color: theme.outline, height: 1),

          // ── Action row: kill while running, close when done ──
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Row(
              children: [
                Button(
                  label: running
                      ? component.strings.t('shell.live.kill')
                      : component.strings.t('shell.live.close'),
                  onPressed: running
                      ? () => ShellLiveRegistry.instance.kill(
                          component.sessionId,
                          component.callId,
                        )
                      : component.onClose,
                  color: running ? theme.error : theme.hintText,
                  hoverColor: theme.foreground,
                  bgColor: theme.surface,
                  hoverBgColor: theme.buttonBackgroundHover,
                ),
                const Spacer(),
                Text(
                  running
                      ? component.strings.t('shell.live.running')
                      : _finalLine(entry),
                  style: TextStyle(
                    color: running ? theme.success : theme.onSurfaceDim,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _title(ShellLiveEntry? entry) {
    if (entry == null) return component.strings.t('shell.live.title');
    final intent = entry.intent.trim();
    if (intent.isNotEmpty) return intent;
    final cmd = entry.command.trim().split('\n').first;
    return cmd.length <= 50 ? cmd : '${cmd.substring(0, 50)}…';
  }

  Component _commandHeader(ShellLiveEntry? entry, CruxThemeData theme) {
    if (entry == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Text(
          component.strings.t('shell.live.gone'),
          style: TextStyle(color: theme.onSurfaceDim),
        ),
      );
    }
    final cmd = entry.command.trim().split('\n').first;
    final cmdLine = cmd.length <= 120 ? cmd : '${cmd.substring(0, 120)}…';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Text(
        cmdLine,
        style: TextStyle(color: theme.text, fontWeight: FontWeight.bold),
      ),
    );
  }

  Component _monitorTimeline(ShellLiveEntry? entry, CruxThemeData theme) {
    final notices = entry?.monitorNotices ?? const [];
    if (notices.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Text(
          component.strings.t('shell.live.noChecks'),
          style: TextStyle(color: theme.onSurfaceDim),
        ),
      );
    }
    // One compact line per check, capped to the last 6 so the pane's
    // vertical budget goes to the output tail.
    final rows = <Component>[];
    final visible = notices.length <= 6
        ? notices
        : notices.sublist(notices.length - 6);
    for (final n in visible) {
      final color = switch (n.kind) {
        'PROGRESS' => theme.success,
        'STUCK' => theme.error,
        'UNCERTAIN' => theme.warning,
        'EVAL_ERROR' || 'FALLBACK' => theme.warning,
        _ => theme.onSurfaceDim,
      };
      final buf = StringBuffer(n.kind);
      if (n.elapsedSeconds > 0) buf.write(' · ${_fmtSecs(n.elapsedSeconds)}');
      if (n.newOutputBytes != null) {
        buf.write(' · +${_fmtBytes(n.newOutputBytes!)}');
      }
      final next = n.nextCheckSeconds;
      if (next != null) {
        buf.write(
          ' · ${component.strings.t('shell.live.nextCheck', {'secs': '$next'})}',
        );
      }
      final reason = n.reason?.trim();
      if (reason != null && reason.isNotEmpty) {
        var r = reason.split('\n').first;
        if (r.length > 60) r = '${r.substring(0, 60)}…';
        buf.write(' — $r');
      }
      rows.add(Text(buf.toString(), style: TextStyle(color: color)));
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      ),
    );
  }

  String _finalLine(ShellLiveEntry? entry) {
    if (entry == null) return component.strings.t('shell.live.gone');
    if (entry.killed) return component.strings.t('shell.live.killed');
    final code = entry.exitCode;
    if (code == null) return component.strings.t('shell.live.gone');
    return component.strings.t('shell.live.exit', {'code': '$code'});
  }

  static String _fmtSecs(int total) {
    if (total < 60) return '${total}s';
    final m = total ~/ 60;
    final s = total % 60;
    return '${m}m ${s}s';
  }

  static String _fmtBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }
}

/// The scrollable terminal-style output view. Renders the entry's
/// rolling tail as monospace text; scrolls to the bottom whenever
/// the tail grows (follow-tail). Keyboard scrolling and mouse wheel
/// come free via `keyboardScrollable`.
class _TerminalTailView extends StatefulComponent {
  final ShellLiveEntry? entry;

  /// The tail length the pane last rendered at — the follow trigger.
  final int rebuildTick;

  /// The empty-tail placeholder (localized by the host).
  final String emptyText;

  const _TerminalTailView({
    required this.entry,
    required this.rebuildTick,
    required this.emptyText,
  });

  @override
  State<_TerminalTailView> createState() => _TerminalTailViewState();
}

class _TerminalTailViewState extends State<_TerminalTailView> {
  final ScrollController _controller = ScrollController();
  @override
  void initState() {
    super.initState();
    _scheduleFollow();
  }

  @override
  void didUpdateComponent(_TerminalTailView old) {
    super.didUpdateComponent(old);
    if (old.rebuildTick != component.rebuildTick) {
      _scheduleFollow();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _scheduleFollow() {
    // Post-frame: the new text lays out before we jump, so
    // maxScrollExtent is already the fresh value.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.scrollToEnd();
    });
  }

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final tail = component.entry?.outputTail ?? '';
    final body = tail.isEmpty
        ? Text(
            component.emptyText,
            style: TextStyle(color: theme.onSurfaceDim),
          )
        // Plain text in the default color — deliberately NO syntax
        // highlighting, NO markdown parsing. The tail is the process's
        // raw output; any color it appears in is the host's, not an
        // interpretation of the bytes. (ANSI escapes are stripped in
        // the registry's append path, not here.)
        : Text(tail, style: TextStyle(color: theme.text));

    return SingleChildScrollView(
      controller: _controller,
      keyboardScrollable: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 1),
        child: body,
      ),
    );
  }
}
