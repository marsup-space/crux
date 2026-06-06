import 'package:nocterm/nocterm.dart';

import '../theme/crux_theme.dart';
import '../models/session_runtime_state.dart';
import 'ui/highlighted_markdown_text.dart';

class StreamingBubble extends StatelessComponent {
  final String streamingContent;
  final String streamingReasoning;
  final SessionRuntimeState? runtimeState;

  const StreamingBubble({
    required this.streamingContent,
    required this.streamingReasoning,
    this.runtimeState,
  });

  @override
  Component build(BuildContext context) {
    final hasReasoning = streamingReasoning.isNotEmpty;

    final children = <Component>[];

    if (hasReasoning) {
      children.add(
        Tint(
          color: CruxTheme.thinkingExpandedText.withOpacity(0.5),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ' Think: ',
                  style: TextStyle(
                    color: CruxTheme.thinkPrefix,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Expanded(
                  child: HighlightedMarkdownText(
                    streamingReasoning,
                    styleSheet: HighlightMarkdownStyleSheet.thinking(),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    children.add(
      Container(
        padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              ' Crux: ',
              style: TextStyle(
                color: CruxTheme.responsePrefix,
                fontWeight: FontWeight.bold,
              ),
            ),
            Expanded(
              child: streamingContent.isEmpty
                  ? Text('...', style: TextStyle(color: CruxTheme.foreground))
                  : HighlightedMarkdownText(streamingContent),
            ),
          ],
        ),
      ),
    );

    children.add(Divider(color: CruxTheme.divider, height: 1));

    return Column(children: children);
  }
}
