import 'package:nocterm/nocterm.dart';
import '../theme/crux_theme.dart';

/// Small header row at the top of a session that was created via
/// compaction, linking back to the source session.
///
/// The clickable region shows the **source session's title** (so
/// the link reads like a breadcrumb — "← Compacted from Home
/// 界面开发计划" rather than a bare id). When the title is empty
/// or the source session was deleted, the link falls back to
/// `ses://<id>` so it's always recognisable.
///
/// Stateful so the link can swap to a hover style and back. The
/// mouse region + gesture detector are wired with the same shape
/// as the session-link hit-testing in
/// [HighlightedMarkdownText.onSessionLinkTap], so a click lands
/// on [onSessionLinkTap] with the source session's id.
class CompactedSessionHeader extends StatefulComponent {
  final int sourceSessionId;

  /// Title of the source session, when known. `null` or empty
  /// means "fall back to `ses://<id>`".
  final String? sourceTitle;

  /// Callback when the link is tapped. Same shape as the
  /// assistant-message callback — `ChatPanel._handleSessionLinkTap`
  /// switches to the referenced session (or toasts "not found").
  final void Function(int sessionId)? onSessionLinkTap;

  const CompactedSessionHeader({
    super.key,
    required this.sourceSessionId,
    this.sourceTitle,
    this.onSessionLinkTap,
  });

  @override
  State<CompactedSessionHeader> createState() => _CompactedSessionHeaderState();
}

class _CompactedSessionHeaderState extends State<CompactedSessionHeader> {
  bool _hovered = false;

  /// Display text for the link region: the source title when
  /// known, otherwise the `ses://<id>` scheme as a last-ditch
  /// recognisable reference (the title-lookup can fail when the
  /// source session has been deleted or its title hasn't been
  /// populated yet).
  String get _displayText {
    final title = component.sourceTitle;
    if (title != null && title.isNotEmpty) return title;
    return 'ses://${component.sourceSessionId}';
  }

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final canTap = component.onSessionLinkTap != null;

    final linkStyle = canTap && _hovered
        ? TextStyle(
            color: theme.onColor(theme.tldrLink),
            backgroundColor: theme.tldrLink,
            fontWeight: FontWeight.bold,
          )
        : TextStyle(
            color: canTap ? theme.tldrLink : theme.onSurfaceDim,
            decoration: TextDecoration.underline,
          );

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ' ← ',
            style: TextStyle(
              color: theme.onSurfaceDim,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text('Compacted from ', style: TextStyle(color: theme.onSurfaceDim)),
          if (canTap)
            MouseRegion(
              onEnter: (_) => setState(() => _hovered = true),
              onExit: (_) {
                if (_hovered) setState(() => _hovered = false);
              },
              opaque: false,
              child: GestureDetector(
                onTap: () =>
                    component.onSessionLinkTap!(component.sourceSessionId),
                behavior: HitTestBehavior.opaque,
                child: Text(_displayText, style: linkStyle),
              ),
            )
          else
            Text(_displayText, style: linkStyle),
        ],
      ),
    );
  }
}
