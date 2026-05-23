import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:nocterm/nocterm.dart';
import '../models/session.dart';

class ExtraInfoPanel extends StatefulComponent {
  final List<Session> sessions;
  final int currentSessionId;
  final void Function(int) onSwitchSession;

  const ExtraInfoPanel({
    required this.sessions,
    required this.currentSessionId,
    required this.onSwitchSession,
  });

  @override
  State<ExtraInfoPanel> createState() => _ExtraInfoPanelState();
}

class _ExtraInfoPanelState extends State<ExtraInfoPanel> {
  Timer? _animTimer;
  double _phase = 0.0;
  final Set<int> _hoveredIds = {};

  static const int _maxTitleLen = 22;
  static const double _animStep = 0.3;
  static const Duration _animInterval = Duration(milliseconds: 50);

  static const Color _prefixDim = Color.fromRGB(60, 60, 80);
  static const Color _prefixBright = Color.fromRGB(100, 200, 255);

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
    if (isCurrent) return Colors.brightCyan;
    switch (status) {
      case SessionStatus.idle:
        return Color.fromRGB(120, 100, 160);
      case SessionStatus.running:
        return Color.lerp(_prefixDim, _prefixBright, _fadeIntensity())!;
      case SessionStatus.needUserAction:
        return Color.fromRGB(255, 200, 50);
      case SessionStatus.done:
        return Color.fromRGB(200, 150, 255);
    }
  }

  Color _titleColor(SessionStatus status, bool isCurrent, bool isHovered) {
    if (isCurrent || isHovered) return Colors.brightCyan;
    switch (status) {
      case SessionStatus.idle:
        return Color.fromRGB(120, 100, 160);
      case SessionStatus.running:
        return Color.fromRGB(100, 200, 255);
      case SessionStatus.needUserAction:
        return Color.fromRGB(255, 200, 50);
      case SessionStatus.done:
        return Color.fromRGB(200, 150, 255);
    }
  }

  Color _bgColor(bool isCurrent, bool isHovered) {
    if (isCurrent) return Color.fromRGB(40, 30, 80);
    if (isHovered) return Color.fromRGB(40, 30, 80);
    return Color.fromRGB(25, 20, 45);
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
    topChildren.add(Text(
      'Sessions',
      style: TextStyle(
        color: Colors.brightMagenta,
        fontWeight: FontWeight.bold,
      ),
    ));
    topChildren.add(Divider(color: Color.fromRGB(80, 60, 120), height: 1));

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
                      fontWeight: isCurrent || isHovered ? FontWeight.bold : null,
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: topChildren,
        )),
        Text(
          displayPath,
          style: TextStyle(color: Color.fromRGB(120, 100, 160)),
        ),
      ],
    );
  }
}
