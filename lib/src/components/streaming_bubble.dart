import 'package:nocterm/nocterm.dart';

import '../theme/crux_theme.dart';
import '../models/session_runtime_state.dart';
import 'ui/highlighted_markdown_text.dart';

class StreamingBubble extends StatelessComponent {
  final String streamingContent;
  final String streamingReasoning;
  final bool thinkingCollapsed;
  final SessionRuntimeState? runtimeState;

  const StreamingBubble({
    required this.streamingContent,
    required this.streamingReasoning,
    required this.thinkingCollapsed,
    this.runtimeState,
  });

  @override
  Component build(BuildContext context) {
    final hasReasoning = streamingReasoning.isNotEmpty;
    final collapsed = thinkingCollapsed && streamingContent.isNotEmpty;

    String thinkingLine = '';
    if (hasReasoning && collapsed) {
      final thinkingMs = runtimeState?.thinkingDurationMs ?? 0;
      final secs = thinkingMs > 0
          ? (thinkingMs / 1000.0).toStringAsFixed(1)
          : '?';
      final tokens = '~${(streamingReasoning.length / 3.5).ceil()}';
      final effort = runtimeState?.reasoningEffort ?? 'normal';
      thinkingLine = 'thought for ${secs}s, $tokens tokens [$effort]';
    }

    final children = <Component>[];

    if (hasReasoning && collapsed) {
      children.add(
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
                  thinkingLine,
                  style: TextStyle(color: CruxTheme.thinkingPrefix),
                ),
              ),
            ],
          ),
        ),
      );
    } else if (hasReasoning && !collapsed) {
      children.add(
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
              Expanded(child: HighlightedMarkdownText(streamingReasoning)),
            ],
          ),
        ),
      );
    }

    if (!hasReasoning) {
      children.add(
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
                child: streamingContent.isEmpty
                    ? Text('...', style: TextStyle(color: CruxTheme.foreground))
                    : HighlightedMarkdownText(streamingContent),
              ),
            ],
          ),
        ),
      );
    } else if (collapsed && streamingContent.isNotEmpty) {
      children.add(
        Container(
          padding: EdgeInsets.only(left: 7, right: 1, top: 0, bottom: 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: HighlightedMarkdownText(streamingContent)),
            ],
          ),
        ),
      );
    }

    children.add(Divider(color: CruxTheme.divider, height: 1));

    return Column(children: children);
  }
}
