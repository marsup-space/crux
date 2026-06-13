import 'package:nocterm/nocterm.dart';

import '../theme/crux_theme.dart';
import '../models/session_runtime_state.dart';
import '../tools/tool_def.dart';
import '../tools/registry.dart';
import 'streaming_controller.dart';
import 'ui/highlighted_markdown_text.dart';

class StreamingBubble extends StatelessComponent {
  final String streamingContent;
  final String streamingReasoning;
  final SessionRuntimeState? runtimeState;

  /// In-progress tool calls, in declared order. Each entry is a
  /// snapshot of one call's id, name, and the (possibly-partial)
  /// input JSON the LLM has emitted so far. We render one row per
  /// call so the user sees parallel calls materialize as they
  /// stream, instead of having to wait for the round to end.
  final List<StreamingToolCall> streamingToolCalls;

  /// Optional registry used to look up the [ToolDef] for each
  /// streaming call, so we can ask it for a richer streaming
  /// preview label (e.g. `Bash ls -la` instead of `Bash (~12 t)`).
  /// When null — or the tool isn't registered — we fall back to
  /// the default capitalized-name + token-budget label.
  final ToolRegistry? toolRegistry;

  const StreamingBubble({
    required this.streamingContent,
    required this.streamingReasoning,
    this.runtimeState,
    this.streamingToolCalls = const [],
    this.toolRegistry,
  });

  @override
  Component build(BuildContext context) {
    final hasReasoning = streamingReasoning.isNotEmpty;

    final children = <Component>[];

    if (hasReasoning) {
      children.add(
        Tint(
          color: CruxTheme.of(context).thinkingExpandedText.withOpacity(0.5),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ' Think: ',
                  style: TextStyle(
                    color: CruxTheme.of(context).thinkPrefix,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Expanded(
                  child: HighlightedMarkdownText(
                    streamingReasoning,
                    styleSheet: HighlightMarkdownStyleSheet.thinking(
                      CruxTheme.of(context),
                    ),
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
                color: CruxTheme.of(context).responsePrefix,
                fontWeight: FontWeight.bold,
              ),
            ),
            Expanded(
              child: streamingContent.isEmpty
                  ? Text(
                      '...',
                      style: TextStyle(color: CruxTheme.of(context).foreground),
                    )
                  : HighlightedMarkdownText(streamingContent),
            ),
          ],
        ),
      ),
    );

    if (streamingToolCalls.isNotEmpty) {
      children.add(
        Container(
          padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: streamingToolCalls
                .map((tc) => _buildStreamingToolCallRow(tc, context))
                .toList(),
          ),
        ),
      );
    }

    return Column(children: children);
  }

  /// Render a single in-flight tool call as a `ToolName: <label>`
  /// row, matching the look of [MessageBubble._buildCollapsedToolCall]
  /// but with no result yet. The label comes from
  /// [ToolDef.streamingLabel] when we can resolve the tool, or
  /// the default `Name (~Nt t)` format otherwise. For
  /// [IntentionalTool]s, the intent is shown instead of the
  /// default streaming label when it can be extracted from the
  /// partial JSON.
  Component _buildStreamingToolCallRow(
    StreamingToolCall tc,
    BuildContext context,
  ) {
    final tool = toolRegistry?.lookup(tc.name);

    // For intentional tools, try to extract the intent from the
    // partial JSON and display it as the label.
    String? intentLabel;
    if (tool is IntentionalTool) {
      intentLabel = _tryExtractIntent(tc.accumulatedInputJson);
    }

    final label = intentLabel ?? tool?.streamingLabel(
          accumulatedInputJson: tc.accumulatedInputJson,
          estimatedInputTokens: tc.estimatedInputTokens,
        ) ??
        '${_capitalize(tc.name)} (~${tc.estimatedInputTokens} t)';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          ' ${_capitalize(tc.name)}: ',
          style: TextStyle(
            color: CruxTheme.of(context).toolPrefix,
            fontWeight: FontWeight.bold,
          ),
        ),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              color: intentLabel != null
                  ? CruxTheme.of(context).foreground
                  : CruxTheme.of(context).onSurfaceDim,
              fontStyle: intentLabel != null ? FontStyle.italic : null,
            ),
          ),
        ),
      ],
    );
  }

  /// Attempt to extract the `intent` value from a possibly-partial
  /// JSON string. The LLM streams input JSON incrementally, so we
  /// can't use `jsonDecode`. Instead, we do a simple regex search
  /// for `"intent":"..."` or `"intent": "..."`.
  String? _tryExtractIntent(String partialJson) {
    final match = RegExp(r'"intent"\s*:\s*"((?:[^"\\]|\\.)*)"')
        .firstMatch(partialJson);
    if (match == null) return null;
    final raw = match.group(1);
    if (raw == null || raw.isEmpty) return null;
    // Unescape simple JSON string escapes.
    return raw
        .replaceAll(r'\\', '\\')
        .replaceAll(r'\"', '"')
        .replaceAll(r'\n', '\n')
        .replaceAll(r'\t', '\t');
  }

  String _capitalize(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1);
  }
}
