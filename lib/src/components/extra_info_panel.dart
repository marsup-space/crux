import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:nocterm/nocterm.dart';
import '../theme/crux_theme.dart';
import '../models/session.dart';
import '../utils/terminal_symbols.dart';
import 'ui/multi_button.dart';

/// Time-based grouping for sessions in the sidebar.
enum _SessionGroup {
  yesterday('Yesterday'),
  threeDays('3 Days'),
  archived('Archived');

  const _SessionGroup(this.label);
  final String label;
}

/// Right-hand side panel showing the active and historical sessions,
/// plus a [MultiButton] pinned to the bottom that exposes the current
/// project path as two actions: `open` (reveal in the system file
/// explorer) and `switch` (seed the chat input with `/project `).
///
/// Sessions are grouped by recency:
/// - **Today** — no label, just the sessions at the top
/// - **Yesterday** — sessions from the previous calendar day
/// - **3 Days** — sessions from 2–3 days ago
///
/// Sessions older than 3 days are auto-archived by
/// [SessionController.initSessions] and don't appear in the list.
/// An "Archived" hint row at the bottom shows the count and reminds
/// the user about `/unarchive`.
class ExtraInfoPanel extends StatefulComponent {
  final List<Session> sessions;
  final int currentSessionId;
  final void Function(int) onSwitchSession;
  final VoidCallback? onSessionTitleTap;

  /// Number of archived sessions (not included in [sessions]).
  final int archivedCount;

  /// Invoked when the user clicks the `open` segment of the project
  /// path button. Should open the project directory in the system
  /// file explorer and surface any failure as a toast.
  final VoidCallback? onOpenProject;

  /// Invoked when the user clicks the `switch` segment of the project
  /// path button. Should populate the chat input with `/project ` so
  /// the user can type a new project path and submit it.
  final VoidCallback? onSwitchProject;

  const ExtraInfoPanel({
    required this.sessions,
    required this.currentSessionId,
    required this.onSwitchSession,
    required this.archivedCount,
    this.onSessionTitleTap,
    this.onOpenProject,
    this.onSwitchProject,
  });

  @override
  State<ExtraInfoPanel> createState() => _ExtraInfoPanelState();
}

class _ExtraInfoPanelState extends State<ExtraInfoPanel> {
  Timer? _animTimer;
  double _phase = 0.0;
  final Set<int> _hoveredIds = {};
  bool _titleHovered = false;

  static const int _maxTitleLen = 22;
  static const double _animStep = 0.3;
  static const Duration _animInterval = Duration(milliseconds: 50);

  Color get _prefixDim => CruxTheme.of(context).onSurfaceDim;
  Color get _prefixBright => CruxTheme.of(context).sessionPrefixRunning;

  /// Flattened row items for the list view. Each item is either a
  /// [_SessionGroup] header or a [Session] row. This avoids nested
  /// ListViews and lets [ListView.builder] handle everything in one
  /// flat list.
  List<Object> _rows = const [];
  List<Session> _prevSessions = const [];
  int _prevArchivedCount = 0;

  /// Build the flat row list from the sorted sessions, inserting
  /// group headers where appropriate.
  ///
  /// Layout:
  /// - Today's sessions first, **no header label**
  /// - "Yesterday" header + yesterday's sessions
  /// - "3 Days" header + sessions from 2–3 days ago
  /// - "N archived /unarchive #id" hint
  static List<Object> _buildRows(List<Session> sorted, int archivedCount) {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final yesterdayStart = todayStart.subtract(const Duration(days: 1));
    final threeDaysAgo = todayStart.subtract(const Duration(days: 3));

    // Bucket sessions into groups.
    final today = <Session>[];
    final yesterday = <Session>[];
    final threeDays = <Session>[];

    for (final s in sorted) {
      if (!s.updatedAt.isBefore(todayStart)) {
        today.add(s);
      } else if (!s.updatedAt.isBefore(yesterdayStart)) {
        yesterday.add(s);
      } else if (!s.updatedAt.isBefore(threeDaysAgo)) {
        threeDays.add(s);
      }
      // Older than 3 days: already auto-archived by
      // SessionController.initSessions; shouldn't appear here.
    }

    final rows = <Object>[];
    // Today: no header, just the sessions.
    rows.addAll(today);
    if (yesterday.isNotEmpty) {
      rows.add(_SessionGroup.yesterday);
      rows.addAll(yesterday);
    }
    if (threeDays.isNotEmpty) {
      rows.add(_SessionGroup.threeDays);
      rows.addAll(threeDays);
    }
    if (archivedCount > 0) {
      rows.add(_SessionGroup.archived);
    }
    return rows;
  }

  List<Object> get _ensureRows {
    final sessions = component.sessions;
    final archived = component.archivedCount;
    if (!identical(_prevSessions, sessions) || _prevArchivedCount != archived) {
      _prevSessions = sessions;
      _prevArchivedCount = archived;
      final sorted = List<Session>.from(sessions)
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      _rows = _buildRows(sorted, archived);
    }
    return _rows;
  }

  @override
  void initState() {
    super.initState();
    _startAnimIfNeeded();
  }

  @override
  void didUpdateComponent(ExtraInfoPanel old) {
    super.didUpdateComponent(old);
    _startAnimIfNeeded();
  }

  @override
  void dispose() {
    _animTimer?.cancel();
    super.dispose();
  }

  bool _hasRunningSession() {
    return component.sessions.any((s) => s.status == SessionStatus.running);
  }

  void _startAnimIfNeeded() {
    if (_hasRunningSession()) {
      _animTimer ??= Timer.periodic(_animInterval, (_) {
        _phase += _animStep;
        setState(() {});
      });
    } else {
      _animTimer?.cancel();
      _animTimer = null;
      _phase = 0.0;
    }
  }

  double _fadeIntensity() {
    final raw = (sin(_phase) + 1.0) / 2.0;
    return raw;
  }

  String _statusPrefix(SessionStatus status) {
    switch (status) {
      case SessionStatus.idle:
        return terminalSymbol('·', '.');
      case SessionStatus.running:
        return terminalSymbol('▶', '>');
      case SessionStatus.needUserAction:
        return '?';
      case SessionStatus.done:
        return terminalSymbol('✦', '*');
    }
  }

  Color _prefixColor(SessionStatus status, bool isCurrent) {
    if (isCurrent) return CruxTheme.of(context).sessionPrefixActive;
    switch (status) {
      case SessionStatus.idle:
        return CruxTheme.of(context).sessionPrefixIdle;
      case SessionStatus.running:
        return Color.lerp(_prefixDim, _prefixBright, _fadeIntensity())!;
      case SessionStatus.needUserAction:
        return CruxTheme.of(context).sessionPrefixNeedsAction;
      case SessionStatus.done:
        return CruxTheme.of(context).sessionPrefixDone;
    }
  }

  Color _titleColor(SessionStatus status, bool isCurrent, bool isHovered) {
    if (isCurrent || isHovered)
      return CruxTheme.of(context).sessionPrefixActive;
    switch (status) {
      case SessionStatus.idle:
        return CruxTheme.of(context).sessionPrefixIdle;
      case SessionStatus.running:
        return CruxTheme.of(context).sessionPrefixRunning;
      case SessionStatus.needUserAction:
        return CruxTheme.of(context).sessionPrefixNeedsAction;
      case SessionStatus.done:
        return CruxTheme.of(context).sessionPrefixDone;
    }
  }

  Color _bgColor(bool isCurrent, bool isHovered) {
    if (isCurrent) return CruxTheme.of(context).wizardRowBgSelected;
    if (isHovered) return CruxTheme.of(context).wizardRowBgSelected;
    return CruxTheme.of(context).buttonBackground;
  }

  String _truncate(String text, int maxLen) {
    if (text.length <= maxLen) return text;
    return text.substring(0, maxLen - 1) + '~';
  }

  @override
  Component build(BuildContext context) {
    final panel = component;
    final rows = _ensureRows;

    final header = MouseRegion(
      onEnter: (_) => setState(() => _titleHovered = true),
      onExit: (_) => setState(() => _titleHovered = false),
      opaque: false,
      child: GestureDetector(
        onTap: () => component.onSessionTitleTap?.call(),
        behavior: HitTestBehavior.opaque,
        child: Container(
          decoration: BoxDecoration(
            color: _titleHovered
                ? CruxTheme.of(context).wizardRowBgSelected
                : CruxTheme.of(context).buttonBackground,
          ),
          child: Row(
            children: [
              Text(
                'Sessions',
                style: TextStyle(
                  color: _titleHovered
                      ? CruxTheme.of(context).wizardTextSelected
                      : CruxTheme.of(context).wizardTitle,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (component.onSessionTitleTap != null)
                Text(
                  ' ⚙',
                  style: TextStyle(
                    color: _titleHovered
                        ? CruxTheme.of(context).buttonTextFocused
                        : CruxTheme.of(context).outline,
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    final home = Platform.environment['HOME'] ?? '';
    final cwd = Directory.current.path;
    final displayPath = home.isNotEmpty && cwd.startsWith(home)
        ? '~${cwd.substring(home.length)}'
        : cwd;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 1),
        header,
        Divider(color: CruxTheme.of(context).outline, height: 1),
        Expanded(
          child: ListView.builder(
            lazy: true,
            itemCount: rows.length,
            itemBuilder: (context, index) {
              final item = rows[index];
              if (item is _SessionGroup) {
                return _buildGroupHeader(item);
              }
              return _buildSessionRow(item as Session, panel);
            },
          ),
        ),
        MultiButton(
          label: displayPath,
          color: CruxTheme.of(context).onSurfaceVariant,
          hoverColor: CruxTheme.of(context).foreground,
          segments: [
            MultiButtonSegment(label: 'open', onPressed: panel.onOpenProject),
            MultiButtonSegment(
              label: 'switch',
              onPressed: panel.onSwitchProject,
            ),
          ],
        ),
        const SizedBox(height: 1),
      ],
    );
  }

  /// Build a group header row (Yesterday / 3 Days / Archived).
  Component _buildGroupHeader(_SessionGroup group) {
    if (group == _SessionGroup.archived) {
      final count = component.archivedCount;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
        child: Row(
          children: [
            Text(
              '$count archived',
              style: TextStyle(
                color: CruxTheme.of(context).onSurfaceDim,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              ' /unarchive #id',
              style: TextStyle(color: CruxTheme.of(context).hintText),
            ),
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
      child: Text(
        group.label,
        style: TextStyle(
          color: CruxTheme.of(context).onSurfaceDim,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  /// Build a single session row widget.
  Component _buildSessionRow(Session session, ExtraInfoPanel panel) {
    final isCurrent = session.id == panel.currentSessionId;
    final isHovered = _hoveredIds.contains(session.id);
    final prefix = _statusPrefix(session.status);
    final title = _truncate(session.title, _maxTitleLen);

    return MouseRegion(
      onEnter: (_) => setState(() => _hoveredIds.add(session.id)),
      onExit: (_) => setState(() => _hoveredIds.remove(session.id)),
      opaque: false,
      child: GestureDetector(
        onTap: () => panel.onSwitchSession(session.id),
        behavior: HitTestBehavior.opaque,
        child: Container(
          decoration: BoxDecoration(color: _bgColor(isCurrent, isHovered)),
          child: Row(
            children: [
              Text(
                prefix,
                style: TextStyle(
                  color: _prefixColor(session.status, isCurrent),
                  fontWeight: isCurrent ? FontWeight.bold : null,
                ),
              ),
              Text(
                ' $title',
                style: TextStyle(
                  color: _titleColor(session.status, isCurrent, isHovered),
                  fontWeight: isCurrent || isHovered ? FontWeight.bold : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
