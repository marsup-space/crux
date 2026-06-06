import 'package:nocterm/nocterm.dart';
import '../theme/crux_theme.dart';
import '../models/message.dart';
import '../tools/tool_def.dart';
import '../tools/registry.dart';
import 'ui/highlighted_markdown_text.dart';

class MessageBubble extends StatelessComponent {
  final Message message;
  final bool reasoningCollapsed;
  final Message? pairedResult;
  final ToolRegistry? toolRegistry;

  const MessageBubble({
    required this.message,
    this.reasoningCollapsed = true,
    this.pairedResult,
    this.toolRegistry,
  });

  @override
  Component build(BuildContext context) {
    if (message.role == 'tool_call') return _buildToolCall(context);
    if (message.role == 'tool') return const SizedBox.shrink();

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
      thinkingSummary = '${secs}s, $tokens tokens [$effort]';
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
                  ' Think: ',
                  style: TextStyle(
                    color: CruxTheme.thinkPrefix,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Expanded(
                  child: Text(
                    thinkingSummary,
                    style: TextStyle(color: CruxTheme.thinkPrefix),
                  ),
                ),
              ],
            ),
          ),
        if (hasReasoning && !reasoningCollapsed)
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
                      message.reasoningContent,
                      styleSheet: HighlightMarkdownStyleSheet.thinking(),
                    ),
                  ),
                ],
              ),
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
                  color: isUser ? CruxTheme.userPrefix : CruxTheme.responsePrefix,
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

  Component _buildToolCall(BuildContext context) {
    final calls = message.toolCalls;
    if (calls.isEmpty) {
      return Container(
        padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
        child: Text('(no calls)', style: TextStyle(color: CruxTheme.onSurfaceDim)),
      );
    }
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: calls.map((tc) => _buildCollapsedToolCall(tc)).toList(),
      ),
    );
  }

  Component _buildCollapsedToolCall(ToolCallData tc) {
    final tool = toolRegistry?.lookup(tc.name);
    final keyArg = _keyArg(tc);
    String resultText = '';
    if (tool != null && pairedResult != null) {
      final result = ToolResult(title: '', output: pairedResult!.content);
      resultText = tool.collapsedSummary(tc.input, result);
    } else if (pairedResult != null) {
      resultText = _resultMetrics(pairedResult!.content);
    }

    final children = <Text>[
      Text(
        ' ${_capitalize(tc.name)}: ',
        style: TextStyle(
          color: CruxTheme.toolPrefix,
          fontWeight: FontWeight.bold,
        ),
      ),
    ];
    if (keyArg.isNotEmpty) {
      children.add(Text(
        '$keyArg ',
        style: TextStyle(color: CruxTheme.foreground),
      ));
    }
    if (resultText.isNotEmpty) {
      children.add(Text(
        resultText,
        style: TextStyle(color: CruxTheme.onSurfaceDim),
      ));
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  String _capitalize(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1);
  }

  String _keyArg(ToolCallData tc) {
    const priorityKeys = ['file_path', 'path', 'filePath', 'command', 'query', 'url', 'directory'];
    for (final key in priorityKeys) {
      if (tc.input.containsKey(key)) return _truncateArg(tc.input[key], 40);
    }
    if (tc.input.isNotEmpty) {
      return _truncateArg(tc.input.values.first, 40);
    }
    return '';
  }

  String _resultMetrics(String content) {
    final lines = '\n'.allMatches(content).length + 1;
    final size = content.length;
    final sizeStr = size > 1024
        ? '${(size / 1024).toStringAsFixed(1)}KB'
        : '${size}B';
    return '$lines lines, $sizeStr';
  }

  String _truncateArg(dynamic value, [int maxLen = 80]) {
    final s = value.toString();
    return s.length > maxLen ? '${s.substring(0, maxLen - 3)}...' : s;
  }
}
