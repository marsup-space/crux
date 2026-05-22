import 'package:nocterm/nocterm.dart';
import '../models/message.dart';

class MessageBubble extends StatelessComponent {
  final Message message;
  final bool reasoningCollapsed;

  const MessageBubble({
    required this.message,
    this.reasoningCollapsed = true,
  });

  @override
  Component build(BuildContext context) {
    final isUser = message.role == 'user';
    final hasReasoning =
        !isUser && message.reasoningContent.isNotEmpty;

    String thinkingSummary = '';
    if (hasReasoning && reasoningCollapsed) {
      final secs = message.thinkingDurationMs > 0
          ? (message.thinkingDurationMs / 1000.0).toStringAsFixed(1)
          : '?';
      final tokens = message.reasoningTokens > 0
          ? message.reasoningTokens.toString()
          : '~${(message.reasoningContent.length / 3.5).ceil()}';
      thinkingSummary = 'thought for ${secs}s, $tokens tokens';
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
                    color: Color.fromRGB(100, 85, 140),
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Expanded(
                  child: Text(
                    thinkingSummary,
                    style: TextStyle(
                      color: Color.fromRGB(100, 85, 140),
                    ),
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
                    color: Colors.brightMagenta,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Expanded(
                  child: Text(
                    message.reasoningContent,
                    style: TextStyle(
                      color: Color.fromRGB(80, 70, 110),
                    ),
                  ),
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
                  color: isUser ? Colors.brightCyan : Colors.brightMagenta,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Expanded(
                child: Text(
                  isUser ? message.content : message.content,
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        ),
        Divider(color: Color.fromRGB(40, 40, 60), height: 1),
      ],
    );
  }
}
