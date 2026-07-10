import 'dart:convert';
import 'dart:io';

import 'package:nocterm/nocterm.dart';
import '../theme/crux_theme.dart';
import '../utils/skill_chip_parser.dart';
import '../models/message.dart';
import '../services/llm_provider.dart';
import '../utils/frame_profiler.dart';
import '../tools/tool_def.dart';
import '../tools/shell_guard.dart' show ShellGuardSeverity;
import '../tools/registry.dart';
import '../utils/token_estimate.dart';
import '../utils/tool_metrics_animator.dart';
import 'ui/highlighted_markdown_text.dart';
import '../utils/markdown_links.dart';
import '../utils/quick_reply_parser.dart';
import '../lsp/language.dart';
import '../utils/tool_meta.dart';
import 'parallel_praise_bubble.dart';
import 'single_call_reminder_bubble.dart';
import 'lsp_diagnostics_bubble.dart';
import 'shell_guard_bubble.dart';
import 'tool_guard_bubble.dart';
import 'error_bubble.dart';
import '../services/llm_error.dart';

class MessageBubble extends StatelessComponent {
  final Message message;
  final bool reasoningCollapsed;
  final Message? pairedResult;
  final Map<String, Message> resultByCallId;
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

  /// Callback when the user clicks a `ses://<id>` reference in the
  /// assistant's prose. Forwarded to [HighlightedMarkdownText] so
  /// refs become clickable buttons that jump to the referenced
  /// session. Skipped for tool output, reasoning blocks, and the
  /// compaction bubble — only the assistant's main reply gets
  /// session links.
  final void Function(int sessionId)? onSessionLinkTap;

  /// Callback when the user clicks a quick-reply token
  /// (`ask://label{answer}` or `ask://label`) in the assistant's
  /// prose. Forwarded to [HighlightedMarkdownText] so tokens
  /// become clickable buttons. Skipped for reasoning blocks and
  /// tool output — only the assistant's main reply and the
  /// compaction summary can carry quick replies.
  final void Function(QuickReply reply)? onQuickReplyTap;

  /// Callback when the user clicks a markdown link
  /// (`[label](url)`) in the assistant's prose. Forwarded to
  /// [HighlightedMarkdownText] so links open the user's default
  /// browser. Applied to the main reply and tool output that has
  /// its own content area; reasoning blocks don't get link
  /// handling because they shouldn't be navigable surfaces.
  final void Function(MarkdownLink link)? onLinkTap;

  /// Callback when the user clicks the retry affordance on a
  /// `stream_error` bubble. Wired by [ChatHistory] (which receives
  /// it from [ChatPanel]) to invoke the command executor's
  /// `/continue` flow. Only set on `stream_error` rows; null on
  /// every other role.
  final VoidCallback? onRetryContinue;

  const MessageBubble({
    required this.message,
    this.reasoningCollapsed = true,
    this.pairedResult,
    this.resultByCallId = const {},
    this.toolRegistry,
    this.highlightText,
    this.reasoningPresets,
    this.onToolCallTap,
    this.onSessionLinkTap,
    this.onQuickReplyTap,
    this.onLinkTap,
    this.onRetryContinue,
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

  /// Map a persisted LSP-diagnostic file path to a humanised
  /// language label suitable for prefixing the bubble (e.g.
  /// `foo.dart` → `Dart`, `src/auth.ts` → `Typescript`).
  ///
  /// Falls back to the shared [kLspLanguageIds] map and skips the
  /// prefix entirely for unknown / extension-less paths so the
  /// legacy `"lsp: ..."` form still renders for files we don't
  /// recognise. The leading character is capitalised so the label
  /// reads like a proper noun in the bubble body.
  static String? _languageLabelForPath(String? filePath) {
    if (filePath == null || filePath.isEmpty) return null;
    final slash = filePath.lastIndexOf('/');
    final basename = slash >= 0 ? filePath.substring(slash + 1) : filePath;
    final dot = basename.lastIndexOf('.');
    if (dot <= 0) return null; // no extension or hidden file
    final ext = basename.substring(dot);
    final id = kLspLanguageIds[ext];
    if (id == null || id == 'plaintext') return null;
    return id[0].toUpperCase() + id.substring(1);
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

  /// Builds the user message content with chip rendering for
  /// `$skill-name`, `@path`, and `[ image N ]` tokens.
  ///
  /// Strips any appended `Skill: <name>\n<body>` blocks that were
  /// added for the LLM — the chat log should only show what the
  /// user actually typed.
  Component _buildUserMessageContent(BuildContext context) {
    final theme = CruxTheme.of(context);
    final content = _stripSkillBodies(message.content);

    // Prefix for images.
    final imagePrefix = message.images.isNotEmpty ? '📎 ${message.images.length} • ' : '';

    // Build styled spans.
    final spans = <TextSpan>[];
    if (imagePrefix.isNotEmpty) {
      spans.add(TextSpan(
        text: imagePrefix,
        style: TextStyle(color: theme.foreground),
      ));
    }

    if (content.isNotEmpty) {
      final baseStyle = TextStyle(color: theme.foreground);
      final chipStyle = TextStyle(
        color: theme.onColor(theme.chipBackground),
        backgroundColor: theme.chipBackground,
      );
      final invisibleTrigger = TextStyle(
        color: theme.chipBackground,
        backgroundColor: theme.chipBackground,
      );
      final imagePattern = RegExp(r'\[ image (\d+) \]');

      var i = 0;
      while (i < content.length) {
        final ch = content[i];

        // Image marker: `[ image N ]`
        if (ch == '[' && imagePattern.hasMatch(content.substring(i))) {
          final m = imagePattern.firstMatch(content.substring(i))!;
          spans.add(TextSpan(text: m.group(0), style: chipStyle));
          i += m.group(0)!.length;
          continue;
        }

        // Skill chip: `$name`
        if (ch == r'$' &&
            (i == 0 || !isSkillNameChar(content[i - 1])) &&
            i + 1 < content.length &&
            isSkillNameChar(content[i + 1])) {
          var j = i + 1;
          while (j < content.length && isSkillNameChar(content[j])) {
            j++;
          }
          spans.add(TextSpan(text: r'$', style: invisibleTrigger));
          spans.add(TextSpan(text: content.substring(i + 1, j), style: chipStyle));
          i = j;
          continue;
        }

        // At-mention: `@path`
        if (ch == '@' &&
            (i == 0 || !_isIdentifierChar(content[i - 1])) &&
            i + 1 < content.length &&
            _isPathChar(content[i + 1])) {
          var j = i + 1;
          while (j < content.length && _isPathChar(content[j])) {
            j++;
          }
          spans.add(TextSpan(text: '@', style: invisibleTrigger));
          spans.add(TextSpan(text: content.substring(i + 1, j), style: chipStyle));
          i = j;
          continue;
        }

        // Regular text.
        var j = i + 1;
        while (j < content.length) {
          if (content[j] == r'$' &&
              (j == 0 || !isSkillNameChar(content[j - 1])) &&
              j + 1 < content.length &&
              isSkillNameChar(content[j + 1])) {
            break;
          }
          if (content[j] == '@' &&
              (j == 0 || !_isIdentifierChar(content[j - 1])) &&
              j + 1 < content.length &&
              _isPathChar(content[j + 1])) {
            break;
          }
          if (content[j] == '[' && imagePattern.hasMatch(content.substring(j))) {
            break;
          }
          j++;
        }
        spans.add(TextSpan(text: content.substring(i, j), style: baseStyle));
        i = j;
      }
    }

    if (spans.isEmpty) {
      // Fallback for empty content with images.
      return Text(
        message.images.isNotEmpty ? '📎 ${message.images.length} image(s)' : '',
        style: TextStyle(color: theme.foreground),
      );
    }

    return RichText(
      text: TextSpan(children: spans),
      softWrap: true,
    );
  }

  static bool _isIdentifierChar(String c) {
    if (c.isEmpty) return false;
    final cc = c.codeUnitAt(0);
    return (cc >= 0x30 && cc <= 0x39) ||
        (cc >= 0x41 && cc <= 0x5A) ||
        (cc >= 0x61 && cc <= 0x7A) ||
        cc == 0x5F ||
        cc == 0x2D;
  }

  static bool _isPathChar(String c) {
    if (c.isEmpty) return false;
    final cc = c.codeUnitAt(0);
    return (cc >= 0x30 && cc <= 0x39) ||
        (cc >= 0x41 && cc <= 0x5A) ||
        (cc >= 0x61 && cc <= 0x7A) ||
        cc == 0x5F ||
        cc == 0x2D ||
        cc == 0x2E ||
        cc == 0x2F ||
        cc == 0x20;
  }

  /// Strips appended `Skill: <name>\n<body>` blocks from the
  /// content. These are added for the LLM at send time but should
  /// not appear in the chat log. The pattern is: a blank line
  /// followed by `Skill: <name>\n` and then the body text, all the
  /// way to the end of the message (bodies are always appended at
  /// the end, after the user's prose).
  static String _stripSkillBodies(String content) {
    final idx = content.indexOf('\n\nSkill: ');
    if (idx == -1) return content;
    return content.substring(0, idx);
  }

  Component _buildInner(BuildContext context) {
    if (message.role == 'tool') return const SizedBox.shrink();
    if (message.role == 'tool_call') return _buildToolCallWithContent(context);
    if (message.role == 'compaction') return _buildCompactionBubble(context);
    if (message.role == 'parallel_praise') {
      return ParallelPraiseBubble(successfulCount: message.parallelCount);
    }
    if (message.role == 'single_call_reminder') {
      // `parallelCount` is reused as the "telemetry int" column for
      // both system-role bubbles: it's the parallelized call count
      // for `parallel_praise` rows and the consecutive single-call
      // round count for `single_call_reminder` rows. Same column,
      // different meaning per role — see Message.parallelCount.
      return SingleCallReminderBubble(consecutiveCount: message.parallelCount);
    }
    if (message.role == 'lsp_diagnostics') {
      // Same `parallelCount` column reused for the error count of
      // LSP diagnostics produced by a tool round. The file path is
      // stored in [Message.content] by the chat service; the bubble
      // parses it back out. The language is derived from the file
      // extension via the shared LSP extension map so the bubble
      // reads `"Dart lsp: 5 errors in foo.dart"` rather than the
      // generic `"lsp: 5 errors in foo.dart"`.
      final filePath = message.content.isEmpty ? null : message.content;
      return LspDiagnosticsBubble(
        errorCount: message.parallelCount,
        filePath: filePath,
        language: _languageLabelForPath(filePath),
      );
    }
    if (message.role == 'tool_guard') {
      // The kind is encoded in `parallelCount` (the same
      // multi-purpose telemetry-int column used by the other
      // system-role bubbles). The file path is in `content` when
      // applicable. A negative or out-of-range kind renders
      // nothing — defensive against future schema drift.
      final kindIndex = message.parallelCount;
      if (kindIndex < 0 || kindIndex >= ToolGuardKind.values.length) {
        return const SizedBox.shrink();
      }
      final kind = ToolGuardKind.values[kindIndex];
      final filePath = message.content.isEmpty ? null : message.content;
      return ToolGuardBubble(guardKind: kind, filePath: filePath);
    }
    if (message.role == 'stream_error') {
      // Persisted error bubble from a failed LLM turn. Decode the
      // structured payload from `message.error` (JSON), fall back
      // to a generic unknown-error bubble if the JSON is missing
      // or malformed (defensive — future schema changes could leave
      // a stale row that we still want to render).
      final llmError = decodeLlmErrorJson(message.error ?? '');
      return ErrorBubble(
        error: llmError,
        // The retry affordance only renders when (a) the error is
        // retriable (auth / billing / content-policy failures don't
        // expose the button — they'd obviously fail again) and (b)
        // the chat panel has wired a callback. The bubble builder
        // checks both before adding the affordance row.
        onRetry: onRetryContinue,
      );
    }
    if (message.role == 'shell_guard') {
      // `parallelCount` carries the post-call streak (1, 2, 3, …)
      // for shell_guard rows — same multi-purpose telemetry-int
      // column used by the other system-role bubbles. The
      // canonical label (including the ordinal and the
      // recommended tool name) is in `content`, produced by
      // `renderShellGuardBubbleLabel(verdict)` in
      // `lib/src/tools/shell_guard.dart`. The bubble reads the
      // label verbatim so the in-context reminder and the
      // visible bubble never drift.
      //
      // The severity is reconstructed from the streak value
      // (mild=1, firm=2, reject=3+) — kept in sync with
      // `_severityForStreak` in `shell_guard.dart`. We can't
      // persist a separate severity column without a schema
      // migration, and the streak is the only signal that
      // uniquely identifies the tier anyway.
      final streak = message.parallelCount;
      final severity = streak >= 3
          ? ShellGuardSeverity.reject
          : streak == 2
              ? ShellGuardSeverity.firm
              : streak == 1
                  ? ShellGuardSeverity.mild
                  : ShellGuardSeverity.none;
      return ShellGuardBubble(
        label: message.content,
        severity: severity,
        streakAfter: streak,
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
                    ? _buildUserMessageContent(context)
                    : HighlightedMarkdownText(
                        message.content,
                        highlightText: highlightText,
                        onSessionLinkTap: onSessionLinkTap,
                        onQuickReplyTap: onQuickReplyTap,
                        onLinkTap: onLinkTap,
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Component _buildCompactionBubble(BuildContext context) {
    final theme = CruxTheme.of(context);
    final meta = _compactionMeta();
    final status = meta['status'] as String? ?? 'complete';
    final label = switch (status) {
      'compacting' => ' Compacting: ',
      'failed' => ' Compact failed: ',
      _ => ' Summary: ',
    };
    final labelColor = switch (status) {
      'failed' => theme.error,
      'compacting' => theme.warning,
      _ => theme.info,
    };
    // The "back to source session" link used to live here as a Button.
    // It now lives at the top of the session (see [ChatHistory] and
    // [CompactedSessionHeader]) so the user sees it immediately on
    // arrival instead of having to scroll past the summary to find it.
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: labelColor,
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
    );
  }

  Map<String, dynamic> _compactionMeta() {
    if (message.meta.isEmpty) return const {};
    try {
      final decoded = jsonDecode(message.meta);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      return const {};
    }
    return const {};
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
                  onSessionLinkTap: onSessionLinkTap,
                  onQuickReplyTap: onQuickReplyTap,
                  onLinkTap: onLinkTap,
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
            children: calls.map((tc) {
              final result = resultByCallId[tc.callId];
              return _ClickableToolCall(
                toolCall: tc,
                pairedResult: result,
                toolRegistry: toolRegistry,
                onTap: onToolCallTap,
              );
            }).toList(),
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

  /// Lerps the displayed `~N t` token count from 0 → final when
  /// the paired result lands (or the result's token count
  /// changes between rebuilds). Auto-driven — the shared
  /// module's scheduler pauses once the value settles, so the
  /// post-call row doesn't keep a per-frame callback running
  /// for the rest of the session.
  ///
  /// We key by `tc.callId` so two parallel calls in the same
  /// round don't stomp on each other. The same shared
  /// [ToolMetricsAnimator] class also drives the streaming
  /// bubble (manually-driven) and the tool detail pane header,
  /// so the per-frame math, the line-delta extraction, and the
  /// `~N t` formatter all live in one place.
  final ToolMetricsAnimator _animator = ToolMetricsAnimator(
    tickerName: 'clickableToolCall',
  );

  @override
  void initState() {
    super.initState();
    _animator.onAdvance = () {
      if (mounted) setState(() {});
    };
  }

  @override
  void dispose() {
    _animator.dispose();
    super.dispose();
  }

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
    final isGuardAborted = resultContent.contains(
      '[Crux system note — tool-call early abort]',
    );
    final isAutoRead = resultContent.startsWith('[AUTOREAD]');
    if (isGuard || isGuardAborted || isAutoRead) {
      final label = isGuardAborted
          ? _guardAbortedLabel(resultContent)
          : isGuard
          ? _guardLabel(resultContent)
          : _autoReadLabel(resultContent);
      final tokens = estimateTokens(resultContent);
      summary = CollapsedSummary(
        text: label,
        argsTokens: tokens,
        totalTokens: tokens,
      );
    } else if (tool != null && component.pairedResult != null) {
      final result = ToolResult(title: '', output: resultContent);
      summary = tool.collapsedSummary(tc.input, result);
      // Append inline UI hints persisted in `messages.meta`. The LLM
      // never sees this — it's read only by the bubble renderer to
      // surface things like proxy-routing in the chat history.
      final hint = routingBubbleHint(
        parseToolRouting(component.pairedResult!.meta),
      );
      if (hint != null) {
        summary = CollapsedSummary(
          text: '${summary.text}  · $hint',
          argsTokens: summary.argsTokens,
          totalTokens: summary.totalTokens,
        );
      }
    } else if (component.pairedResult != null) {
      fallbackText = _resultMetrics(resultContent);
    }

    // Update the shared animator's target from the freshly
    // computed summary. The animator decides whether anything
    // actually changed; if not, this is a no-op and the
    // per-frame scheduler stays paused. The displayed
    // `~N t` (read via [formatToolMetricsToken] below) will
    // lerp from the current displayed value toward the new
    // target over a few hundred milliseconds.
    //
    // Guard/auto-read rows have a synthetic summary with
    // `argsTokens == totalTokens == estimateTokens(result)`,
    // so the lerp still works — the value settles on the
    // rough token count of the error output.
    if (summary != null) {
      _animator.setTarget(tc.callId, tokens: summary.totalTokens);
    } else {
      // Paired result is gone (or the tool produced a
      // fallback text without a token count) — make sure the
      // animator doesn't keep a stale per-callId entry.
      _animator.forget(tc.callId);
    }

    // For intentional tools, prefer displaying the intent over the
    // file path so the user sees *why* the tool was called.
    final intentLabel = _intentLabel(tc, tool);

    // Build body as TextSpans — everything after the prefix.
    final bodySpans = <TextSpan>[];
    if (intentLabel != null) {
      bodySpans.add(
        TextSpan(
          text: '$intentLabel ',
          style: TextStyle(
            color: theme.foreground,
            fontStyle: FontStyle.italic,
          ),
        ),
      );
    } else if (keyArg.isNotEmpty) {
      bodySpans.add(
        TextSpan(
          text: '$keyArg ',
          style: TextStyle(color: theme.foreground),
        ),
      );
    }
    if (summary != null) {
      bodySpans.add(
        TextSpan(
          text: '${summary.text}, ',
          style: TextStyle(color: theme.onSurfaceDim),
        ),
      );
      // The token count comes from the shared animator so it
      // lerps from 0 → summary.totalTokens when the result
      // first lands, and stays put on subsequent rebuilds
      // (the shared module's `setTarget` is a no-op when the
      // target didn't change). The line-delta half of the
      // format is intentionally omitted here — the static
      // `summary.text` already carries the `+M -N lines`
      // shape for write/edit (encoded by each tool's
      // `collapsedSummary`), so we just lerp the `~N t` part.
      bodySpans.add(
        TextSpan(
          text: formatToolMetricsToken(_animator.read(tc.callId)),
          style: TextStyle(color: theme.onSurfaceDim),
        ),
      );
    } else if (fallbackText != null && fallbackText.isNotEmpty) {
      bodySpans.add(
        TextSpan(
          text: fallbackText,
          style: TextStyle(color: theme.onSurfaceDim),
        ),
      );
    }

    // Hover indicator — show ▸ on hover to signal clickability.
    final prefixSpans = <TextSpan>[];
    prefixSpans.add(
      TextSpan(
        text: _hovered ? '▸ ' : ' ',
        style: TextStyle(color: theme.toolPrefix),
      ),
    );
    prefixSpans.add(
      TextSpan(
        text: '${_capitalize(tc.name)}: ',
        style: TextStyle(color: theme.toolPrefix, fontWeight: FontWeight.bold),
      ),
    );

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
        final display = (key != 'command' && key != 'query' && key != 'url')
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
        final trimmed = (newline == -1 ? reason : reason.substring(0, newline))
            .trim();
        if (trimmed.isNotEmpty) return trimmed;
      }
    }
    return 'guard triggered (auto read)';
  }

  String _guardAbortedLabel(String content) {
    // Unknown-tool aborts use a different body prefix (`[UNKNOWN
    // TOOL]` instead of `[GUARD]`) and the file-guard helper would
    // fall through to its generic fallback. Detect the unknown-tool
    // shape up front and emit a label that names the bad tool so
    // the collapsed row explains what happened.
    if (content.startsWith('[UNKNOWN TOOL]')) {
      final requested =
          RegExp(r'no tool named "([^"]+)"').firstMatch(content)?.group(1);
      final tokenMatch = RegExp(
        r'Aborted after ~(\d+) generated tool-argument tokens\.',
      ).firstMatch(content);
      final tokenCount = tokenMatch?.group(1);
      final base = requested != null
          ? "unknown tool '$requested', aborted mid-stream"
          : 'unknown tool, aborted mid-stream';
      if (tokenCount == null) return base;
      return '$base (~$tokenCount t)';
    }
    final label = _guardLabel(content);
    final tokenMatch = RegExp(
      r'Aborted after ~(\d+) generated tool-argument tokens\.',
    ).firstMatch(content);
    final tokenCount = tokenMatch?.group(1);
    if (tokenCount == null) return '$label, aborted mid-stream';
    return '$label, aborted after ~$tokenCount t';
  }

  String _autoReadLabel(String content) {
    const prefix = '[AUTOREAD] No changes were made';
    if (!content.startsWith(prefix)) return 'auto read';
    final rest = content.substring(prefix.length);
    final dash = rest.indexOf('\u2014'); // em-dash
    if (dash == -1) return 'auto read';
    final reason = rest.substring(dash + 1);
    final newline = reason.indexOf('\n');
    final trimmed = (newline == -1 ? reason : reason.substring(0, newline))
        .trim();
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
