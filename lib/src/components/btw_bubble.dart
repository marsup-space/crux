import 'package:nocterm/nocterm.dart';
import '../theme/crux_theme.dart';
import 'ui/highlighted_markdown_text.dart';

/// One rendered line of a `/btw` chain. Used for both the user's
/// ephemeral prompt and the AI's ephemeral reply. The whole bubble
/// is wrapped in a dim, rounded-bordered box so the user can see at
/// a glance that the content is "off the record" — it will be wiped
/// as soon as the next non-`/btw` message is sent.
///
/// Two visual variants:
/// - [BtwBubble.user] — the user's prompt, prefixed with `btw >`.
/// - [BtwBubble.ai] — the AI's response, prefixed with `btw ✦` (or
///   "..." while streaming, see [streaming]).
class BtwBubble extends StatelessComponent {
  final String content;
  final bool isUser;
  final bool streaming;

  /// Construct a user-prompt variant of the btw bubble. The
  /// `streaming` flag is always false — user bubbles are always
  /// fully formed the moment they're rendered.
  const BtwBubble.user({
    super.key,
    required this.content,
  })  : isUser = true,
        streaming = false;

  /// Construct an AI-response variant of the btw bubble. Pass
  /// `streaming: true` for the live "btw ..." bubble shown while
  /// the LLM is still emitting deltas; the final rendered bubble
  /// is `BtwBubble.ai` with `streaming: false` (the default).
  const BtwBubble.ai({
    super.key,
    required this.content,
    this.streaming = false,
  }) : isUser = false;

  @override
  Component build(BuildContext context) {
    final prefixColor = isUser
        ? CruxTheme.btwUserPrefix
        : CruxTheme.btwAiPrefix;
    final prefix = isUser
        ? ' btw > '
        : (streaming && content.isEmpty ? ' btw ... ' : ' btw ✦ ');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
      decoration: BoxDecoration(
        color: CruxTheme.btwBackground,
        border: BoxBorder(
          top: BorderSide(
            color: CruxTheme.btwBorder,
            style: BoxBorderStyle.rounded,
          ),
          right: BorderSide(
            color: CruxTheme.btwBorder,
            style: BoxBorderStyle.rounded,
          ),
          bottom: BorderSide(
            color: CruxTheme.btwBorder,
            style: BoxBorderStyle.rounded,
          ),
          left: BorderSide(
            color: CruxTheme.btwBorder,
            style: BoxBorderStyle.rounded,
          ),
        ),
      ),
      child: Container(
        // Inner padding so the rounded border + tinted background
        // sit *around* the prefix + body, not under the leading
        // column. Otherwise the first column starts flush with the
        // border and looks cramped.
        padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              prefix,
              style: TextStyle(
                color: prefixColor,
                fontWeight: FontWeight.bold,
              ),
            ),
            Expanded(
              child: isUser
                  ? Text(
                      content,
                      style: TextStyle(color: CruxTheme.foreground),
                    )
                  : HighlightedMarkdownText(content),
            ),
          ],
        ),
      ),
    );
  }
}
