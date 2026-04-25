import 'package:nocterm/nocterm.dart';
import '../models/message.dart';

class MessageBubble extends StatelessComponent {
  final Message message;

  const MessageBubble({required this.message});

  @override
  Component build(BuildContext context) {
    final isUser = message.role == 'user';

    return Column(
      children: [
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
