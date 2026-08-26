import 'package:nocterm/nocterm.dart';
import '../i18n/strings.dart';
import '../theme/crux_theme.dart';
import '../models/message_queue.dart';
import '../utils/terminal_symbols.dart';

/// Displays the list of queued messages that will be inserted into
/// the conversation at the next agent boundary. Each message shows
/// the text and a `[×]` discard button. The whole widget is rendered
/// inside a dim, rounded-bordered box (similar to the btw chain)
/// so it reads as "pending, not yet sent" at a glance.
class QueuedMessagesBubble extends StatelessComponent {
  final List<QueuedMessage> messages;
  final void Function(int queueId) onDiscard;

  /// Locale-aware chrome strings. Defaulted to English.
  final Strings strings;

  const QueuedMessagesBubble({
    super.key,
    required this.messages,
    required this.onDiscard,
    this.strings = kEnglishStrings,
  });

  @override
  Component build(BuildContext context) {
    if (messages.isEmpty) return const SizedBox.shrink();

    final rows = <Component>[];
    for (var i = 0; i < messages.length; i++) {
      final msg = messages[i];
      rows.add(_QueuedMessageRow(message: msg, index: i, onDiscard: onDiscard));
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
      decoration: BoxDecoration(
        color: CruxTheme.of(context).queueBackground,
        border: BoxBorder(
          top: BorderSide(
            color: CruxTheme.of(context).queueBorder,
            style: BoxBorderStyle.rounded,
          ),
          right: BorderSide(
            color: CruxTheme.of(context).queueBorder,
            style: BoxBorderStyle.rounded,
          ),
          bottom: BorderSide(
            color: CruxTheme.of(context).queueBorder,
            style: BoxBorderStyle.rounded,
          ),
          left: BorderSide(
            color: CruxTheme.of(context).queueBorder,
            style: BoxBorderStyle.rounded,
          ),
        ),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row
            Row(
              children: [
                Text(
                  strings.t('bubble.queued'),
                  style: TextStyle(
                    color: CruxTheme.of(context).queuePrefix,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  strings.t('bubble.queuedCount', {'n': '${messages.length}'}),
                  style: TextStyle(color: CruxTheme.of(context).queueText),
                ),
              ],
            ),
            // Individual queued messages
            ...rows,
          ],
        ),
      ),
    );
  }
}

class _QueuedMessageRow extends StatefulComponent {
  final QueuedMessage message;
  final int index;
  final void Function(int queueId) onDiscard;

  const _QueuedMessageRow({
    required this.message,
    required this.index,
    required this.onDiscard,
  });

  @override
  State<_QueuedMessageRow> createState() => _QueuedMessageRowState();
}

class _QueuedMessageRowState extends State<_QueuedMessageRow> {
  bool _discardHovered = false;

  @override
  Component build(BuildContext context) {
    final msg = component.message;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '   ${component.index + 1}. ',
          style: TextStyle(color: CruxTheme.of(context).queueText),
        ),
        Expanded(
          child: Text(
            msg.content.replaceAll('\n', ' '),
            style: TextStyle(color: CruxTheme.of(context).queueText),
            maxLines: 2,
            overflow: TextOverflow.clip,
          ),
        ),
        MouseRegion(
          onEnter: (_) => setState(() => _discardHovered = true),
          onExit: (_) => setState(() => _discardHovered = false),
          opaque: false,
          child: GestureDetector(
            onTap: () => component.onDiscard(msg.id),
            behavior: HitTestBehavior.opaque,
            child: Text(
              ' ${terminalSymbol('×', 'x')}',
              style: TextStyle(
                color: _discardHovered
                    ? CruxTheme.of(context).queueDiscardHoverText
                    : CruxTheme.of(context).queueDiscardText,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
