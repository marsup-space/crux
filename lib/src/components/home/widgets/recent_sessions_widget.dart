import 'package:nocterm/nocterm.dart';

import '../../../models/session.dart';
import '../../../theme/crux_theme.dart';
import '../home_widgets.dart';

/// The `recent-sessions` box — the most recently active sessions, tap to
/// jump back into one.
///
/// Data source: the session/chat lists already in memory on the panel
/// (from `ChatPanelBootState` / `SessionController.sessions`). Sessions
/// and chats are merged and ordered by `updatedAt` descending — the same
/// ordering `SessionManagementPanel` uses. The list is a snapshot at
/// open; the widget doesn't re-listen for changes (the design's "data
/// already in memory" reading — the box answers "what was I doing" at
/// open, and switching sessions closes home anyway).
///
/// Activation switches to the most recent session (or is a passive box
/// when the list is empty). Switching is session-mutating, so it goes
/// through the [_onSwitch] callback the panel wires — which applies the
/// same mid-stream guard as `HomeContext.runCommand`. Home closes after
/// a successful switch.
class RecentSessionsHomeWidget extends HomeWidget {
  /// Sessions + chats, merged by the caller, ordered by updatedAt desc.
  final List<Session> Function() sessions;

  /// The currently-active session id, so its row is marked.
  final int? Function() currentSessionId;

  /// Switch to a session by id. Returns false if refused (mid-stream);
  /// the widget then keeps home open so the user sees the refusal.
  final bool Function(int sessionId) onSwitch;

  RecentSessionsHomeWidget({
    required this.sessions,
    required this.currentSessionId,
    required this.onSwitch,
  });

  @override
  String get id => 'recent-sessions';

  @override
  String get title => 'Recent';

  @override
  Set<int> get supportedSpans => const {1, 2};

  /// How many rows to show. At span 2 there's room for a couple more.
  static const int _maxRows = 5;

  @override
  int heightFor(int span) => _maxRows;

  @override
  void Function()? activate(HomeContext ctx) {
    final recent = _top();
    if (recent == null) return null; // empty: passive box
    return () {
      if (onSwitch(recent.id)) ctx.close();
    };
  }

  Session? _top() {
    final list = sessions();
    return list.isEmpty ? null : list.first;
  }

  @override
  Component build(BuildContext context, HomeContext ctx, int span) {
    final theme = CruxTheme.of(context);
    final list = sessions();
    if (list.isEmpty) {
      return Text(
        'no sessions yet — /new to start',
        style: TextStyle(color: theme.onSurfaceDim),
      );
    }

    final currentId = currentSessionId();
    final shown = list.take(_maxRows).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final s in shown)
          _SessionLine(
            session: s,
            isCurrent: s.id == currentId,
            theme: theme,
          ),
      ],
    );
  }
}

/// One session row: a current-marker, the title (or a fallback), and a
/// relative "how long ago" stamp. The row is mouse-tappable via the box's
/// own gesture handling; individual row taps land on the box's activate.
class _SessionLine extends StatelessComponent {
  final Session session;
  final bool isCurrent;
  final CruxThemeData theme;

  const _SessionLine({
    required this.session,
    required this.isCurrent,
    required this.theme,
  });

  @override
  Component build(BuildContext context) {
    final title = session.title.isEmpty ? session.displayId : session.title;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          isCurrent ? '▸ ' : '  ',
          style: TextStyle(color: theme.accent),
        ),
        Expanded(
          child: Text(
            title,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: isCurrent ? theme.text : theme.onSurfaceVariant,
              fontWeight: isCurrent ? FontWeight.bold : null,
            ),
          ),
        ),
        Text(
          _relative(session.updatedAt),
          style: TextStyle(color: theme.onSurfaceDim),
        ),
      ],
    );
  }

  static String _relative(DateTime when) {
    final diff = DateTime.now().difference(when);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inHours < 1) return '${diff.inMinutes}m';
    if (diff.inDays < 1) return '${diff.inHours}h';
    if (diff.inDays < 30) return '${diff.inDays}d';
    return '${(diff.inDays / 30).floor()}mo';
  }
}
