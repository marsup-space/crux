import 'dart:async';

import 'package:nocterm/nocterm.dart';

import '../services/shell_live_registry.dart';
import '../theme/crux_theme.dart';
import '../i18n/strings.dart';
import 'ui/multi_button.dart';

/// One executing-shell row in the vibe tools box.
///
/// Idle state shows the agent's `intent` phrase (falling back to a
/// truncated command) plus a live elapsed timer; hovering morphs the
/// row into a single `detail` segment (size-stable, same [MultiButton]
/// pattern as the files box's `open | diff` rows) that opens the
/// shell live fullpane.
///
/// The timer ticks via the row's own [TickerRegistry] subscription —
/// the row is only alive while the shell is executing, so the tick
/// dies with the row and costs nothing after the run finishes.
class VibeShellRow extends StatefulComponent {
  /// The executing tool call's id — the live registry's key.
  final String callId;

  /// The owning session id — the live registry's other key.
  final int sessionId;

  /// The agent's `intent` phrase for the run; empty falls back to a
  /// truncated command.
  final String intent;

  /// Fired when the user activates `detail` (open the live fullpane).
  final VoidCallback? onDetail;

  final Strings strings;

  const VibeShellRow({
    required this.callId,
    required this.sessionId,
    required this.intent,
    this.onDetail,
    this.strings = kEnglishStrings,
    super.key,
  });

  @override
  State<VibeShellRow> createState() => _VibeShellRowState();
}

class _VibeShellRowState extends State<VibeShellRow> {
  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateComponent(VibeShellRow old) {
    super.didUpdateComponent(old);
    if (old.callId != component.callId ||
        old.sessionId != component.sessionId) {
      _subscribe();
    }
  }

  Timer? _tickTimer;

  void _subscribe() {
    _tickTimer?.cancel();
    _tickTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    super.dispose();
  }

  String _formatElapsed(Duration d) {
    final total = d.inSeconds;
    if (total < 60) return '${total}s';
    final m = d.inMinutes;
    final s = total % 60;
    if (m < 60) return '${m}m ${s}s';
    return '${d.inHours}h ${m % 60}m';
  }

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final entry = ShellLiveRegistry.instance.entryFor(
      component.sessionId,
      component.callId,
    );

    // Elapsed clock: from the live entry when registered (its
    // startedAt matches the spawn), else from the entry's absence —
    // the row shows a running timer either way because the
    // surrounding bubble re-renders every frame while streaming.
    final elapsed = entry == null
        ? null
        : DateTime.now().difference(entry.startedAt);

    var label = component.intent.trim();
    if (label.isEmpty) {
      label = entry?.command ?? '';
    }
    if (label.isEmpty) {
      label = component.callId;
    }
    if (label.length > 60) label = '${label.substring(0, 60)}…';
    final timerText = elapsed == null ? '' : ' ${_formatElapsed(elapsed)}';

    return MultiButton(
      key: ValueKey('vibe-shell-${component.callId}'),
      label: '$label$timerText',
      segments: [
        MultiButtonSegment(
          label: component.strings.t('shell.live.detail'),
          onPressed: component.onDetail,
        ),
      ],
      color: theme.text,
      hoverColor: theme.accent,
      dimHoverColor: theme.onSurfaceDim,
      disabledColor: theme.onSurfaceDim,
      separatorColor: theme.onSurfaceDim,
      bgColor: null,
      hoverBgColor: null,
      hoverSegmentBgColor: theme.buttonBackgroundHover,
      padding: EdgeInsets.zero,
    );
  }
}
