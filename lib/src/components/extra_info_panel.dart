import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:nocterm/nocterm.dart';
import '../theme/crux_theme.dart';
import '../models/session.dart';
import 'ui/multi_button.dart';

/// Right-hand side panel showing the active and historical sessions,
/// plus a [MultiButton] pinned to the bottom that exposes the current
/// project path as two actions: `open` (reveal in the system file
/// explorer) and `switch` (seed the chat input with `/project `).
///
/// The panel is intentionally thin: it does not know how to open a
/// directory or how to drive the slash command pipeline. It just
/// surfaces the click events to its parent (the chat panel) via
/// [onOpenProject] and [onSwitchProject] callbacks. This keeps the
/// TUI widget tree decoupled from the chat panel's command state
/// machine, which is much easier to test in isolation.
class ExtraInfoPanel extends StatefulComponent {
  final List<Session> sessions;
  final int currentSessionId;
  final void Function(int) onSwitchSession;
  final VoidCallback? onSessionTitleTap;

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

  static const Color _prefixDim = CruxTheme.onSurfaceDim;
  static const Color _prefixBright = CruxTheme.sessionPrefixRunning;

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
      if (_animTimer == null) {
        _animTimer = Timer.periodic(_animInterval, (_) {
          _phase += _animStep;
          setState(() {});
        });
      }
    } else {
      _animTimer?.cancel();
      _animTimer = null;
      _phase = 0.0;
    }
  }

  /// Smooth fade intensity using sine wave, oscillating between 0.0 and 1.0
  double _fadeIntensity() {
    final raw = (sin(_phase) + 1.0) / 2.0;
    return raw;
  }

  String _statusPrefix(SessionStatus status) {
    switch (status) {
      case SessionStatus.idle:
        return '·';
      case SessionStatus.running:
        return '▶';
      case SessionStatus.needUserAction:
        return '?';
      case SessionStatus.done:
        return '✦';
    }
  }

  Color _prefixColor(SessionStatus status, bool isCurrent) {
    if (isCurrent) return CruxTheme.sessionPrefixActive;
    switch (status) {
      case SessionStatus.idle:
        return CruxTheme.sessionPrefixIdle;
      case SessionStatus.running:
        return Color.lerp(_prefixDim, _prefixBright, _fadeIntensity())!;
      case SessionStatus.needUserAction:
        return CruxTheme.sessionPrefixNeedsAction;
      case SessionStatus.done:
        return CruxTheme.sessionPrefixDone;
    }
  }

  Color _titleColor(SessionStatus status, bool isCurrent, bool isHovered) {
    if (isCurrent || isHovered) return CruxTheme.sessionPrefixActive;
    switch (status) {
      case SessionStatus.idle:
        return CruxTheme.sessionPrefixIdle;
      case SessionStatus.running:
        return CruxTheme.sessionPrefixRunning;
      case SessionStatus.needUserAction:
        return CruxTheme.sessionPrefixNeedsAction;
      case SessionStatus.done:
        return CruxTheme.sessionPrefixDone;
    }
  }

  Color _bgColor(bool isCurrent, bool isHovered) {
    if (isCurrent) return CruxTheme.wizardRowBgSelected;
    if (isHovered) return CruxTheme.wizardRowBgSelected;
    return CruxTheme.buttonBackground;
  }

  String _truncate(String text, int maxLen) {
    if (text.length <= maxLen) return text;
    return text.substring(0, maxLen - 1) + '~';
  }

  @override
  Component build(BuildContext context) {
    final panel = component;
    final topChildren = <Component>[];

    // Header
    topChildren.add(
      MouseRegion(
        onEnter: (_) => setState(() => _titleHovered = true),
        onExit: (_) => setState(() => _titleHovered = false),
        opaque: false,
        child: GestureDetector(
          onTap: () => component.onSessionTitleTap?.call(),
          behavior: HitTestBehavior.opaque,
          child: Container(
            decoration: BoxDecoration(
              color: _titleHovered
                  ? CruxTheme.wizardRowBgSelected
                  : CruxTheme.buttonBackground,
            ),
            child: Row(
              children: [
                Text(
                  'Sessions',
                  style: TextStyle(
                    color: _titleHovered
                        ? CruxTheme.wizardTextSelected
                        : CruxTheme.wizardTitle,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (component.onSessionTitleTap != null)
                  Text(
                    ' ⚙',
                    style: TextStyle(
                      color: _titleHovered
                          ? CruxTheme.buttonTextFocused
                          : CruxTheme.outline,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    topChildren.add(Divider(color: CruxTheme.outline, height: 1));

    // Sort sessions by latest activity (most recent first)
    final sorted = List<Session>.from(panel.sessions)
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    // Session rows — prefix and title rendered separately so only the
    // prefix icon fades for running sessions
    for (final session in sorted) {
      final isCurrent = session.id == panel.currentSessionId;
      final isHovered = _hoveredIds.contains(session.id);
      final prefix = _statusPrefix(session.status);
      final title = _truncate(session.title, _maxTitleLen);

      topChildren.add(
        MouseRegion(
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
                      fontWeight: isCurrent || isHovered
                          ? FontWeight.bold
                          : null,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final home = Platform.environment['HOME'] ?? '';
    final cwd = Directory.current.path;
    final displayPath = home.isNotEmpty && cwd.startsWith(home)
        ? '~${cwd.substring(home.length)}'
        : cwd;

    // The bottom path uses a [MultiButton] rather than a plain
    // [Text] so the user can both *see* the current project and
    // *act* on it without leaving the panel. Idle shows the path;
    // hover splits the same horizontal space into `open | switch`
    // segments, each clickable.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: topChildren,
          ),
        ),
        MultiButton(
          label: displayPath,
          color: CruxTheme.onSurfaceVariant,
          hoverColor: CruxTheme.foreground,
          segments: [
            MultiButtonSegment(
              label: 'open',
              onPressed: panel.onOpenProject,
            ),
            MultiButtonSegment(
              label: 'switch',
              onPressed: panel.onSwitchProject,
            ),
          ],
        ),
      ],
    );
  }
}
