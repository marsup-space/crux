import 'package:nocterm/nocterm.dart';
import '../theme/crux_theme.dart';
import 'ui/highlighted_markdown_text.dart';

/// Small header row at the top of a session that was created via
/// compaction, linking back to the source session.
///
/// The link uses the same `ses://<id>` scheme the rest of the
/// assistant-reply parser recognises — the [onSessionLinkTap]
/// callback forwarded into [HighlightedMarkdownText] turns the
/// reference into a clickable region that jumps back to the
/// session that was compacted.
///
/// Rendered above the first message of every session that has a
/// `compaction` role message with `sourceSessionId` in its meta.
/// Sits behind a thin divider so the user can scan past it to
/// the actual conversation.
class CompactedSessionHeader extends StatelessComponent {
  final int sourceSessionId;

  /// Callback when the `ses://<id>` reference inside the header
  /// is tapped. Same shape as the assistant-message callback —
  /// `ChatPanel._handleSessionLinkTap` does the right thing.
  final void Function(int sessionId)? onSessionLinkTap;

  const CompactedSessionHeader({
    super.key,
    required this.sourceSessionId,
    this.onSessionLinkTap,
  });

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
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
          Expanded(
            child: HighlightedMarkdownText(
              'Compacted from ses://$sourceSessionId',
              onSessionLinkTap: onSessionLinkTap,
            ),
          ),
        ],
      ),
    );
  }
}