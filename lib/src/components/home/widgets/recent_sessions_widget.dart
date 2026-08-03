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

  // ── Item selection ────────────────────────────────────────────────

  int _selectedIndex = 0;

  List<Session> get _shown => sessions().take(_maxRows).toList();

  @override
  int get itemCount => _shown.length;

  @override
  int get selectedIndex => _selectedIndex;

  @override
  void moveSelection(int delta) {
    final n = itemCount;
    if (n == 0) return;
    _selectedIndex = (_selectedIndex + delta) % n;
    if (_selectedIndex < 0) _selectedIndex += n;
  }

  @override
  bool selectItemAt(int index) {
    if (index < 0 || index >= itemCount) return false;
    _selectedIndex = index;
    return true;
  }

  @override
  void resetSelection() => _selectedIndex = 0;

  @override
  void Function()? activateItem(HomeContext ctx, int index) {
    final shown = _shown;
    if (index < 0 || index >= shown.length) return null;
    final session = shown[index];
    return () {
      if (onSwitch(session.id)) ctx.close();
    };
  }

  @override
  void Function()? activate(HomeContext ctx) {
    final n = itemCount;
    if (n == 0) return null; // empty: passive box
    return activateItem(ctx, _selectedIndex.clamp(0, n - 1));
  }

  @override
  Component build(
    BuildContext context,
    HomeContext ctx,
    int span, {
    bool focused = false,
  }) {
    final theme = CruxTheme.of(context);
    final shown = _shown;
    if (shown.isEmpty) {
      return Text(
        'no sessions yet — /new to start',
        style: TextStyle(color: theme.onSurfaceDim),
      );
    }

    final currentId = currentSessionId();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < shown.length; i++)
          _SessionLine(
            session: shown[i],
            isCurrent: shown[i].id == currentId,
            selected: focused && i == _selectedIndex,
            theme: theme,
            onTap: () {
              _selectedIndex = i;
              if (onSwitch(shown[i].id)) ctx.close();
            },
          ),
      ],
    );
  }
}

/// One session row: a current-marker, the title (or a fallback), and a
/// relative "how long ago" stamp. Highlighted when it's the box's
/// selected item and the box is focused; its own GestureDetector
/// switches to that session on click (per-row, not whole-box). Mouse-
/// hover selection is handled at the box level (home's box MouseRegion
/// computes the row from the cursor y), because a per-row MouseRegion
/// nested under the box region never receives hover in nocterm.
class _SessionLine extends StatelessComponent {
  final Session session;
  final bool isCurrent;
  final bool selected;
  final CruxThemeData theme;
  final VoidCallback onTap;

  const _SessionLine({
    required this.session,
    required this.isCurrent,
    required this.selected,
    required this.theme,
    required this.onTap,
  });

  @override
  Component build(BuildContext context) {
    final title = session.title.isEmpty ? session.displayId : session.title;
    final titleColor = selected
        ? theme.selectedText
        : (isCurrent ? theme.text : theme.onSurfaceVariant);
    final metaColor = selected ? theme.selectedText : theme.onSurfaceDim;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        color: selected ? theme.selection : null,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              isCurrent ? '▸ ' : '  ',
              style: TextStyle(color: selected ? theme.selectedText : theme.accent),
            ),
            Expanded(
              child: Text(
                title,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: titleColor,
                  fontWeight: isCurrent ? FontWeight.bold : null,
                ),
              ),
              ),
              Text(
                _relative(session.updatedAt),
                style: TextStyle(color: metaColor),
              ),
            ],
          ),
        ),
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
