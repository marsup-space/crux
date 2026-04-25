import 'package:nocterm/nocterm.dart';
import '../models/message.dart';

class ExtraInfoPanel extends StatelessComponent {
  final List<Message> messages;

  const ExtraInfoPanel({required this.messages});

  @override
  Component build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 1, vertical: 1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Info',
            style: TextStyle(
              color: Colors.brightMagenta,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 1),
          _buildInfoRow('Messages', '${messages.length}'),
          _buildInfoRow('Model', 'crux-v1'),
          _buildInfoRow('Status', 'ready'),
        ],
      ),
    );
  }

  Component _buildInfoRow(String label, String value) {
    return Row(
      children: [
        Text(
          '$label ',
          style: TextStyle(color: Colors.gray),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(color: Colors.white),
          ),
        ),
      ],
    );
  }
}
