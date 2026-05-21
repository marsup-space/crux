import 'package:nocterm/nocterm.dart';
import '../models/message.dart';

class MessageBubble extends StatelessComponent {
  final Message message;

  const MessageBubble({required this.message});

  @override
  Component build(BuildContext context) {
    final isUser = message.role == 'user';
    final hasReasoning =
        !isUser && message.reasoningContent.isNotEmpty;

    return Column(
      children: [
        if (hasReasoning)
          Container(
            padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ' Think: ',
                  style: TextStyle(
                    color: Color.fromRGB(100, 80, 140),
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
                isUser ? ' You: ' : ' Crux: ',
                style: TextStyle(
                  color: isUser ? Colors.brightCyan : Colors.brightMagenta,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Expanded(
                child: Text(
                  message.content,
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
