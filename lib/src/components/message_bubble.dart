import 'dart:io';

import 'package:nocterm/nocterm.dart';
import '../theme/crux_theme.dart';
import '../models/message.dart';
import '../services/llm_provider.dart';
import '../utils/frame_profiler.dart';
import '../tools/tool_def.dart';
import '../tools/registry.dart';
import '../utils/token_estimate.dart';
import 'ui/highlighted_markdown_text.dart';
import 'parallel_praise_bubble.dart';
import 'single_call_reminder_bubble.dart';

class MessageBubble extends StatelessComponent {
  final Message message;
  final bool reasoningCollapsed;
  final Message? pairedResult;
  final ToolRegistry? toolRegistry;
  final String? highlightText;

  /// Reasoning presets from the session's provider, used to map
  /// internal effort values to display labels (e.g. `normal` →
  /// `adaptive` for MiniMax). If null, a default identity mapping
  /// is used.
  final List<ReasoningPreset>? reasoningPresets;

  /// Callback when a tool call bubble is tapped. Receives the
  /// [ToolCallData] and the paired result [Message] (if any).
  final void Function(ToolCallData toolCall, Message? pairedResult)?
      onToolCallTap;

  const MessageBubble({
    required this.message,
    this.reasoningCollapsed = true,
    this.pairedResult,
    this.toolRegistry,
    this.highlightText,
    this.reasoningPresets,
    this.onToolCallTap,
  });

  String _displayEffort(String effort) {
    final presets = reasoningPresets;
    if (presets != null) {
      for (final p in presets) {
        if (p.internalValue == effort) return p.displayLabel;
      }
    }
    return effort; // null presets or no match: show internal value
  }

  @override
  Component build(BuildContext context) {
    // Each message bubble's build is cheap on its own
    // (tens of microseconds), but with hundreds of messages
    // in a session the cumulative cost is visible in the
    // chat history's overall build time. Tagging each
    // individual bubble lets the report break the
    // aggregate down to "how many message bubbles were
    // built per frame" rather than treating it as one
    // monolithic build.
    return FrameProfiler.instance.timed(
      'messageBubble.build',
      () => _buildInner(context),
    );
  }

  Component _buildInner(BuildContext context) {
    if (message.role == 'tool') return const SizedBox.shrink();
    if (message.role == 'tool_call') return _buildToolCallWithContent(context);
    if (message.role == 'parallel_praise') {
      return ParallelPraiseBubble(successfulCount: message.parallelCount);
    }
    if (message.role == 'single_call_reminder') {
      // `parallelCount` is reused as the "telemetry int" column for
      // both system-role bubbles: it's the parallelized call count
      // for `parallel_praise` rows and the consecutive single-call
      // round count for `single_call_reminder` rows. Same column,
      // different meaning per role — see Message.parallelCount.
      return SingleCallReminderBubble(
        consecutiveCount: message.parallelCount,
      );
    }

    final isUser = message.role == 'user';
    final hasReasoning = !isUser && message.reasoningContent.isNotEmpty;

    String thinkingSummary = '';
    if (hasReasoning && reasoningCollapsed) {
      final secs = message.thinkingDurationMs > 0
          ? (message.thinkingDurationMs / 1000.0).toStringAsFixed(1)
          : '?';
      final tokens = message.reasoningTokens > 0
          ? message.reasoningTokens.toString()
          : '~${estimateTokens(message.reasoningContent)}';
      final effort = _displayEffort(message.reasoningEffort ?? 'normal');
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
                    color: CruxTheme.of(context).thinkPrefix,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Expanded(
                  child: Text(
                    thinkingSummary,
                    style: TextStyle(color: CruxTheme.of(context).thinkPrefix),
                  ),
                ),
              ],
            ),
          ),
        if (hasReasoning && !reasoningCollapsed)
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
                      message.reasoningContent,
                      styleSheet: HighlightMarkdownStyleSheet.thinking(
                        CruxTheme.of(context),
                      ),
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
                  color: isUser
                      ? CruxTheme.of(context).userPrefix
                      : CruxTheme.of(context).responsePrefix,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Expanded(
                child: isUser
                    ? Text(
                        message.images.isNotEmpty
                            ? (message.content.isEmpty
                                ? '📎 ${message.images.length} image(s)'
                                : '📎 ${message.images.length} • ${message.content}')
                            : message.content,
                        style: TextStyle(
                          color: CruxTheme.of(context).foreground,
                        ),
                      )
                    : HighlightedMarkdownText(
                        message.content,
                        highlightText: highlightText,
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Component _buildToolCallWithContent(BuildContext context) {
    final hasReasoning = message.reasoningContent.isNotEmpty;
    final hasContent = message.content.trim().isNotEmpty;

    String thinkingSummary = '';
    if (hasReasoning && reasoningCollapsed) {
      final secs = message.thinkingDurationMs > 0
          ? (message.thinkingDurationMs / 1000.0).toStringAsFixed(1)
          : '?';
      final tokens = message.reasoningTokens > 0
          ? message.reasoningTokens.toString()
          : '~${estimateTokens(message.reasoningContent)}';
      final effort = _displayEffort(message.reasoningEffort ?? 'normal');
      thinkingSummary = '${secs}s, $tokens tokens [$effort]';
    }

    final children = <Component>[];

    if (hasReasoning && reasoningCollapsed) {
      children.add(
        Container(
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
                child: Text(
                  thinkingSummary,
                  style: TextStyle(color: CruxTheme.of(context).thinkPrefix),
                ),
              ),
            ],
          ),
        ),
      );
    } else if (hasReasoning) {
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
                    message.reasoningContent,
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

    if (hasContent) {
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
                child: HighlightedMarkdownText(
                  message.content,
                  highlightText: highlightText,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final calls = message.toolCalls;
    if (calls.isNotEmpty) {
      children.add(
        Container(
          padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: calls
                .map((tc) => _ClickableToolCall(
                      toolCall: tc,
                      pairedResult: pairedResult,
                      toolRegistry: toolRegistry,
                      onTap: onToolCallTap,
                    ))
                .toList(),
          ),
        ),
      );
    }

    return Column(children: children);
  }
}

/// A single collapsed tool-call row that is clickable and shows
/// hover state. Tapping it invokes [onTap] to open the detail
/// fullpane. This is a [StatefulComponent] to track hover state.
class _ClickableToolCall extends StatefulComponent {
  final ToolCallData toolCall;
  final Message? pairedResult;
  final ToolRegistry? toolRegistry;
  final void Function(ToolCallData toolCall, Message? pairedResult)? onTap;

  const _ClickableToolCall({
    required this.toolCall,
    this.pairedResult,
    this.toolRegistry,
    this.onTap,
  });

  @override
  State<_ClickableToolCall> createState() => _ClickableToolCallState();
}

class _ClickableToolCallState extends State<_ClickableToolCall> {
  bool _hovered = false;

  @override
  Component build(BuildContext context) {
    return FrameProfiler.instance.timed(
      'clickableToolCall.build',
      () => _buildInner(context),
    );
  }

  Component _buildInner(BuildContext context) {
    final tc = component.toolCall;
    final tool = component.toolRegistry?.lookup(tc.name);
    final theme = CruxTheme.of(context);
    final keyArg = _keyArg(tc);
    CollapsedSummary? summary;
    String? fallbackText;
    final resultContent = component.pairedResult?.content ?? '';
    final isGuard = resultContent.startsWith('[GUARD]');
    final isAutoRead = resultContent.startsWith('[AUTOREAD]');
    if (isGuard || isAutoRead) {
      final label =
          isGuard ? _guardLabel(resultContent) : _autoReadLabel(resultContent);
      final tokens = estimateTokens(resultContent);
      summary = CollapsedSummary(
        text: label,
        argsTokens: tokens,
        totalTokens: tokens,
      );
    } else if (tool != null && component.pairedResult != null) {
      final result = ToolResult(title: '', output: resultContent);
      summary = tool.collapsedSummary(tc.input, result);
    } else if (component.pairedResult != null) {
      fallbackText = _resultMetrics(resultContent);
    }

    // For intentional tools, prefer displaying the intent over the
    // file path so the user sees *why* the tool was called.
    final intentLabel = _intentLabel(tc, tool);

    // Build body as TextSpans — everything after the prefix.
    final bodySpans = <TextSpan>[];
    if (intentLabel != null) {
      bodySpans.add(TextSpan(
        text: '$intentLabel ',
        style: TextStyle(
          color: theme.foreground,
          fontStyle: FontStyle.italic,
        ),
      ));
    } else if (keyArg.isNotEmpty) {
      bodySpans.add(TextSpan(
        text: '$keyArg ',
        style: TextStyle(color: theme.foreground),
      ));
    }
    if (summary != null) {
      bodySpans.add(TextSpan(
        text: '${summary.text}, ',
        style: TextStyle(color: theme.onSurfaceDim),
      ));
      bodySpans.add(TextSpan(
        text: '~${summary.totalTokens} t',
        style: TextStyle(color: theme.onSurfaceDim),
      ));
    } else if (fallbackText != null && fallbackText.isNotEmpty) {
      bodySpans.add(TextSpan(
        text: fallbackText,
        style: TextStyle(color: theme.onSurfaceDim),
      ));
    }

    // Hover indicator — show ▸ on hover to signal clickability.
    final prefixSpans = <TextSpan>[];
    prefixSpans.add(TextSpan(
      text: _hovered ? '▸ ' : ' ',
      style: TextStyle(color: theme.toolPrefix),
    ));
    prefixSpans.add(TextSpan(
      text: '${_capitalize(tc.name)}: ',
      style: TextStyle(
        color: theme.toolPrefix,
        fontWeight: FontWeight.bold,
      ),
    ));

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      opaque: false,
      child: GestureDetector(
        onTap: component.onTap != null
            ? () => component.onTap!(tc, component.pairedResult)
            : null,
        behavior: HitTestBehavior.opaque,
        child: Container(
          decoration: BoxDecoration(
            color: _hovered ? theme.surfaceVariant : null,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RichText(text: TextSpan(children: prefixSpans)),
              Expanded(
                child: RichText(text: TextSpan(children: bodySpans)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _capitalize(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1);
  }

  String _keyArg(ToolCallData tc) {
    const priorityKeys = [
      'file_path',
      'path',
      'filePath',
      'command',
      'query',
      'url',
      'directory',
    ];
    for (final key in priorityKeys) {
      if (tc.input.containsKey(key)) {
        final value = tc.input[key].toString();
        final display =
            (key != 'command' && key != 'query' && key != 'url')
                ? relativePath(value, Directory.current.path)
                : value;
        return _truncateArg(display, 40);
      }
    }
    if (tc.input.isNotEmpty) {
      return _truncateArg(tc.input.values.first, 40);
    }
    return '';
  }

  String? _intentLabel(ToolCallData tc, ToolDef? tool) {
    if (tool is IntentionalTool) {
      return tool.intentFromArgs(tc.input);
    }
    return null;
  }

  String _guardLabel(String content) {
    const blockedPrefix = '[GUARD] Write was BLOCKED';
    if (content.startsWith(blockedPrefix)) {
      final rest = content.substring(blockedPrefix.length);
      final dash = rest.indexOf('\u2014');
      if (dash != -1) {
        final reason = rest.substring(dash + 1);
        final newline = reason.indexOf('\n');
        final trimmed =
            (newline == -1 ? reason : reason.substring(0, newline)).trim();
        if (trimmed.isNotEmpty) return trimmed;
      }
    }
    return 'guard triggered (auto read)';
  }

  String _autoReadLabel(String content) {
    const prefix = '[AUTOREAD] No changes were made';
    if (!content.startsWith(prefix)) return 'auto read';
    final rest = content.substring(prefix.length);
    final dash = rest.indexOf('\u2014'); // em-dash
    if (dash == -1) return 'auto read';
    final reason = rest.substring(dash + 1);
    final newline = reason.indexOf('\n');
    final trimmed =
        (newline == -1 ? reason : reason.substring(0, newline)).trim();
    return trimmed.isEmpty ? 'auto read' : trimmed;
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
