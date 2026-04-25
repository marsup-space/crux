import 'package:nocterm/nocterm.dart';
import '../models/session.dart';
import 'ui/button.dart';

class ExtraInfoPanel extends StatelessComponent {
  final List<Session> sessions;
  final int currentSessionId;
  final void Function(int) onSwitchSession;

  const ExtraInfoPanel({
    required this.sessions,
    required this.currentSessionId,
    required this.onSwitchSession,
  });

  static const int _maxTitleLen = 22;

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

  Color _statusColor(SessionStatus status, bool isCurrent) {
    if (isCurrent) return Colors.brightCyan;
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

  Color _statusBgColor(bool isCurrent) {
    return isCurrent
        ? Color.fromRGB(40, 30, 80)
        : Color.fromRGB(25, 20, 45);
  }

  String _truncate(String text, int maxLen) {
    if (text.length <= maxLen) return text;
    return text.substring(0, maxLen - 1) + '~';
  }

  @override
  Component build(BuildContext context) {
    final children = <Component>[];

    // Header showing current session
    children.add(Text(
      'Sessions #$currentSessionId',
      style: TextStyle(
        color: Colors.brightMagenta,
        fontWeight: FontWeight.bold,
      ),
    ));
    children.add(SizedBox(height: 1));
    children.add(Divider(color: Color.fromRGB(80, 60, 120), height: 1));

    // Session buttons
    for (final session in sessions) {
      final isCurrent = session.id == currentSessionId;
      final prefix = _statusPrefix(session.status);
      final title = _truncate(session.title, _maxTitleLen);
      final label = '$prefix $title';

      children.add(Button(
        label: label,
        onPressed: () => onSwitchSession(session.id),
        color: _statusColor(session.status, isCurrent),
        hoverColor: Colors.brightCyan,
        bgColor: _statusBgColor(isCurrent),
        hoverBgColor: Color.fromRGB(40, 30, 80),
        padding: EdgeInsets.symmetric(horizontal: 0, vertical: 0),
      ));
    }

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 1, vertical: 1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}
