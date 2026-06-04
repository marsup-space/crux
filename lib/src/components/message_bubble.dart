import 'package:nocterm/nocterm.dart';
import '../theme/crux_theme.dart';
import '../models/message.dart';
import 'ui/highlighted_markdown_text.dart';

class MessageBubble extends StatelessComponent {
  final Message message;
  final bool reasoningCollapsed;

  const MessageBubble({required this.message, this.reasoningCollapsed = true});

  @override
  Component build(BuildContext context) {
    final isUser = message.role == 'user';
    final hasReasoning = !isUser && message.reasoningContent.isNotEmpty;

    String thinkingSummary = '';
    if (hasReasoning && reasoningCollapsed) {
      final secs = message.thinkingDurationMs > 0
          ? (message.thinkingDurationMs / 1000.0).toStringAsFixed(1)
          : '?';
      final tokens = message.reasoningTokens > 0
          ? message.reasoningTokens.toString()
          : '~${(message.reasoningContent.length / 3.5).ceil()}';
      final effort = message.reasoningEffort ?? 'normal';
      thinkingSummary = 'thought for ${secs}s, $tokens tokens [$effort]';
    }

    return Column(
      children: [
        if (hasReasoning && reasoningCollapsed)
          Container(
            padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ' Crux: ',
                  style: TextStyle(
                    color: CruxTheme.thinkingPrefix,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Expanded(
                  child: Text(
                    thinkingSummary,
                    style: TextStyle(color: CruxTheme.thinkingPrefix),
                  ),
                ),
              ],
            ),
          ),
        if (hasReasoning && !reasoningCollapsed)
          Container(
            padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ' Crux: ',
                  style: TextStyle(
                    color: CruxTheme.aiPrefix,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Expanded(
                  child: HighlightedMarkdownText(message.reasoningContent),
                ),
              ],
            ),
          ),
        Container(
          padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isUser ? ' You: ' : (hasReasoning ? '       ' : ' Crux: '),
                style: TextStyle(
                  color: isUser ? CruxTheme.userPrefix : CruxTheme.aiPrefix,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Expanded(
                child: isUser
                    ? Text(
                        message.content,
                        style: TextStyle(color: CruxTheme.foreground),
                      )
                    : HighlightedMarkdownText(message.content),
              ),
            ],
          ),
        ),
        Divider(color: CruxTheme.divider, height: 1),
      ],
    );
  }
}
