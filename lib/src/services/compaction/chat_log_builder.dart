import '../../models/message.dart';
import '../../tools/registry.dart';
import '../../tools/tool_def.dart';
import 'summary_collector.dart';

/// Result of [buildChatLog]: the rendered Markdown plus the file
/// markers the caller needs to replay through [FileReadTracker] so the
/// read-before-write guard sees fresh mtimes post-compact.
class ChatLogResult {
  final String markdown;
  final List<FileReadMarker> fileMarkers;
  const ChatLogResult({required this.markdown, required this.fileMarkers});
}

/// Walk [messages] and render them as a chat log. The walk:
///   * groups user → crux → tool-calls per turn,
///   * within a round, groups tool calls by tool name into single
///     comma-separated lines — each line is just `tool: marker(s)`,
///     no result text. Tools WITH an `intent` render as
///     `<tool> for {intent}`; tools without one (e.g. `read`,
///     `webfetch`) render as `<tool> <path|url>`,
///   * drops `grep` / `glob` / `session` entirely (per the
///     `skipInPrune` flag on each [ToolDef]),
///   * collects `read` and `write` contributions for the
///     bottom-of-log summary section. Everything else (search
///     results, fetched pages, bash output, edit diffs) is
///     intentionally NOT contributed — the model's reasoning
///     during the original turn was based on the inline result,
///     and dumping the result again at the bottom would inflate
///     the chain-accumulated compaction size without giving the
///     resumed agent anything it didn't already have.
///
/// [messages] is expected to be in chronological order (oldest first),
/// which is what `MessageStore.getMessages` returns. [toolRegistry]
/// is the live runtime [ToolRegistry]; the builder looks up each
/// tool by name and calls the prune methods on the [ToolDef]
/// instance directly — no parallel rule table.
ChatLogResult buildChatLog({
  required List<Message> messages,
  required String workingDirectory,
  required ToolRegistry toolRegistry,
}) {
  final bodyBuf = StringBuffer('## Session activity log\n');
  final summary = SummaryCollector();

  // State for the current turn. A "turn" starts at a `user` message
  // and runs until the next `user` (or end of input).
  String? currentUserContent;
  bool currentUserHasImages = false;
  final rounds = <_RoundBuilder>[];

  void flushTurn() {
    if (currentUserContent == null && rounds.isEmpty) return;
    _writeTurn(bodyBuf, currentUserContent, currentUserHasImages, rounds);
    currentUserContent = null;
    currentUserHasImages = false;
    rounds.clear();
  }

  for (final m in messages) {
    switch (m.role) {
      case 'user':
        // New turn boundary — flush the previous one first.
        flushTurn();
        currentUserContent = m.content;
        currentUserHasImages = m.images.isNotEmpty;
        break;

      case 'ai':
        // Pure-text assistant response. Add a round with no tool calls.
        // If a TLDR summary already exists for this response, substitute
        // it for the full content. The response was long enough to
        // warrant summarization in the user-facing TldrBubble, and the
        // chat log should preserve the same compression ratio — keeping
        // the full text would defeat most of the win compaction just
        // bought. Tldr is only generated for `role: 'ai'` messages
        // (see chat_turn_orchestrator.maybeGenerateTldr), so we don't
        // touch the `tool_call` branch below.
        final body = m.tldr.isNotEmpty ? m.tldr : m.content;
        rounds.add(_RoundBuilder(preamble: body, calls: const []));
        break;

      case 'tool_call':
        // Round with N tool calls. For each call, find its paired
        // `role: tool` result by walking forward.
        final calls = <_ResolvedCall>[];
        for (final call in m.toolCalls) {
          final result = _findToolResult(messages, m, call.callId);
          final isError = _looksLikeError(result);
          final tool = toolRegistry.lookup(call.name);

          calls.add(_ResolvedCall(
            call: call,
            tool: tool,
            result: result ?? '',
            isError: isError,
          ));

          // Summary contribution: each tool decides whether to feed
          // the bottom-of-log section. Last-write-wins dedup happens
          // inside the collector.
          if (tool != null) {
            final contribution = tool.extractPruneSummary(
              call: call,
              pairedResult: result ?? '',
              isError: isError,
              workingDirectory: workingDirectory,
            );
            if (contribution != null) summary.add(contribution);
          }
        }
        rounds.add(_RoundBuilder(preamble: m.content, calls: calls));
        break;

      case 'tool':
        // Already consumed by the preceding `tool_call`. Skip.
        break;

      case 'compaction':
        // Already a chat log; skip.
        break;

      case 'system':
        // UI meta bubbles (parallel_praise etc.) — never sent to LLM.
        break;
    }
  }
  flushTurn();

  // Append the bottom-of-log summary section: read files, searched
  // terms, fetched pages. The collector is fed by each tool's
  // `extractPruneSummary` (see `ToolDef`) — `read` / `write` /
  // `edit` contribute current on-disk file content (with mtime so
  // the resumed agent can detect stale snapshots), and the web /
  // search tools contribute their last results. Last-write-wins
  // dedup keeps the section bounded even when a single tool is
  // invoked many times.
  final body = bodyBuf.toString().trimRight();
  final summaryMarkdown = summary.render();
  final fullMarkdown = summaryMarkdown.isEmpty
      ? body
      : '$body\n\n$summaryMarkdown';

  return ChatLogResult(
    markdown: fullMarkdown,
    fileMarkers: summary.fileMarkers(),
  );
}

class _RoundBuilder {
  final String preamble;
  final List<_ResolvedCall> calls;
  const _RoundBuilder({required this.preamble, required this.calls});
}

class _ResolvedCall {
  final ToolCallData call;

  /// The looked-up tool. Null when the call's tool name isn't
  /// registered (e.g. legacy message from a removed tool). We
  /// fall through to a placeholder render in that case.
  final ToolDef? tool;
  final String result;
  final bool isError;
  const _ResolvedCall({
    required this.call,
    required this.tool,
    required this.result,
    required this.isError,
  });

  bool get skipInPrune => tool?.skipInPrune ?? false;
  String renderInline() {
    final t = tool;
    if (t == null) return call.name;
    return t.renderPruneInline(
      call: call,
      pairedResult: result,
      isError: isError,
    );
  }
}

void _writeTurn(
  StringBuffer buf,
  String? userContent,
  bool userHasImages,
  List<_RoundBuilder> rounds,
) {
  if (userContent != null) {
    buf.writeln();
    buf.writeln('user: $userContent');
    if (userHasImages) {
      buf.writeln('(attached image(s))');
    }
  }

  // Pre-process: merge consecutive empty-preamble rounds into the
  // previous non-empty preamble round. This collapses the common
  // LLM streaming pattern
  //   ai (text) → tool_call [a] → tool → tool_call [b] → tool → …
  // into one chunk per preamble, so calls of the same tool split
  // across tool_call messages render as one merged line per tool
  // (`read: foo, bar` instead of two `read: foo` / `read: bar`
  // lines). Rounds with empty preamble AND empty calls drop
  // entirely. The first chunk in a turn can have an empty preamble
  // (no `crux:` above it) when the LLM went straight to tool calls
  // without a text lead-in.
  final chunks = <_RoundBuilder>[];
  for (final r in rounds) {
    if (r.preamble.isNotEmpty) {
      chunks.add(r);
    } else if (r.calls.isNotEmpty) {
      if (chunks.isNotEmpty) {
        chunks[chunks.length - 1] = _RoundBuilder(
          preamble: chunks.last.preamble,
          calls: [...chunks.last.calls, ...r.calls],
        );
      } else {
        chunks.add(_RoundBuilder(preamble: '', calls: r.calls));
      }
    }
  }

  var isFirstChunk = true;
  for (final chunk in chunks) {
    final visibleCalls =
        chunk.calls.where((c) => !c.skipInPrune).toList();
    if (chunk.preamble.isEmpty && visibleCalls.isEmpty) continue;

    if (!isFirstChunk) buf.writeln();
    isFirstChunk = false;

    if (chunk.preamble.isNotEmpty) {
      buf.writeln('crux: ${chunk.preamble}');
    }
    if (visibleCalls.isNotEmpty) {
      // Each tool's calls render on their own line (one line per
      // tool, comma-joined when N>1). The `tool calls:` wrapper
      // we used to emit is gone — the per-tool `<name>:` lines
      // are self-describing and the wrapper was pure noise.
      buf.writeln(_groupCalls(visibleCalls));
    }
  }
}

/// Group a flat list of resolved calls into per-tool-type lines with
/// comma-separated keys. Mirrors the chat log format the user spec'd:
///
///   read: foo.txt, bar.txt
///   edit: foo.txt for {add X}, bar.txt for {fix Y}
///   executed 2 commands for {run tests}, {install deps}
String _groupCalls(List<_ResolvedCall> calls) {
  final byTool = <String, List<_ResolvedCall>>{};
  for (final c in calls) {
    byTool.putIfAbsent(c.call.name.toLowerCase(), () => []).add(c);
  }

  final lines = <String>[];
  // Stable rendering order — match the tool spec's likely reading order.
  const order = [
    'read',
    'write',
    'edit',
    'bash',
    'cmd',
    'powershell',
    'webfetch',
    'websearch',
    'semantic_search',
    'find_similar_code',
  ];
  final rendered = <String>{};

  for (final toolName in order) {
    final group = byTool[toolName];
    if (group == null || group.isEmpty) continue;
    lines.add(_renderGroup(toolName, group));
    rendered.add(toolName);
  }

  // Anything not in the canonical order (e.g. a new tool registered
  // with default rules) — append alphabetically.
  final remaining = byTool.keys.where((k) => !rendered.contains(k)).toList()
    ..sort();
  for (final toolName in remaining) {
    final group = byTool[toolName]!;
    lines.add(_renderGroup(toolName, group));
  }

  return lines.join('\n');
}

String _renderGroup(String toolName, List<_ResolvedCall> group) {
  final rendered = group.map((c) => c.renderInline()).toList();

  // Detect "shared prefix = tool name": read / write / edit /
  // webfetch / websearch / semantic_search / find_similar_code.
  final sharedPrefix = _detectSharedPrefix(toolName, rendered);

  if (sharedPrefix != null) {
    final tails = rendered.map((s) => _stripPrefix(s, sharedPrefix)).toList();
    // `<tool>: <details>` — colon labels match the `user:` /
    // `crux:` style the chat log uses for everything else. Shell
    // tools keep their `executed N commands` form below.
    return '$sharedPrefix: ${tails.join(", ")}';
  }

  // Special case: shell — rules render `bash for {X}` so a group of N
  // becomes `executed N commands for {X}, {Y}, {Z}` per the user spec.
  if (toolName == 'bash' || toolName == 'cmd' || toolName == 'powershell') {
    final n = group.length;
    final noun = n == 1 ? 'command' : 'commands';
    final intents = group.map((c) {
      final intent = c.call.input['intent']?.toString() ?? '';
      if (intent.isNotEmpty) return '{$intent}';
      final cmd = (c.call.input['command'] as String?) ?? '';
      final preview = cmd.length > 60 ? '${cmd.substring(0, 60)}…' : cmd;
      return '`<$preview>`';
    }).toList();
    return 'executed $n $noun for ${intents.join(", ")}';
  }

  // Fallback: one line per call (shouldn't normally hit).
  return rendered.join('\n');
}

String? _detectSharedPrefix(String toolName, List<String> rendered) {
  // All lines should start with the tool name + a space. If so, strip
  // it so we can re-prefix once after joining.
  final prefix = '$toolName ';
  if (rendered.every((s) => s.startsWith(prefix))) return toolName;
  // Also accept no-space variants like `read foo.txt` → prefix `read`.
  final barePrefix = toolName;
  if (rendered.every((s) => s == barePrefix || s.startsWith('$barePrefix '))) {
    return toolName;
  }
  return null;
}

String _stripPrefix(String line, String prefix) {
  if (line == prefix) return '';
  if (line.startsWith('$prefix ')) return line.substring(prefix.length + 1);
  return line;
}

/// Walk forward from [toolCallMsg] to find the matching `role: tool`
/// message keyed by [callId]. Stops at the next user / tool_call /
/// compaction boundary so a tool result from a later round never
/// pairs with an earlier call.
String? _findToolResult(
  List<Message> messages,
  Message toolCallMsg,
  String callId,
) {
  final startIdx = messages.indexOf(toolCallMsg);
  if (startIdx < 0) return null;
  for (var i = startIdx + 1; i < messages.length; i++) {
    final m = messages[i];
    if (m.role == 'tool' && m.toolCallId == callId) return m.content;
    if (m.role == 'user' || m.role == 'tool_call' || m.role == 'compaction') {
      return null;
    }
  }
  return null;
}

/// Heuristic for "this tool result indicates an error". Looks for the
/// common error markers the tool layer emits, but only in a small
/// leading window — not anywhere in the result.
///
/// The previous version ran the check over the entire result, which
/// triggered false positives whenever the tool happened to return
/// content that contained the trigger substrings as literals. The
/// concrete case: a `read` of `chat_log_builder.dart` returns the
/// file's own source as line-numbered text, and that source includes
/// the string `('exit code:') && lower.contains('failed');` (the
/// body of this very function). The old `contains('exit code:') &&
/// contains('failed')` clause then matched, classifying the
/// successful read as an error, and `renderPruneInline` rendered
/// the inline line as `read $path → $pairedResult` — embedding
/// 358 lines of source code into a single chat log line and
/// inflating the post-compaction size by ~14k tokens.
///
/// Limiting the scan to the first 200 characters is enough: every
/// error format the tool layer emits prefixes the failure cause
/// (`Error: …`, `Path not found: …`, `[guard] aborted: …`,
/// `exit code: N\n…failed…`). If neither marker shows up in the
/// first 200 chars, the result is treated as success and we err
/// on the side of pruning — which is the documented design intent
/// ("pruning the success path wrongly is much worse than
/// over-keeping an error" actually argues for false NEGATIVES
/// here, not positives; the heuristic was inverted in practice).
bool _looksLikeError(String? result) {
  if (result == null || result.isEmpty) return false;
  // 200 chars is enough to span the longest header our tool
  // layer emits (`[guard] auto-read: <path>` = ~50 chars in the
  // worst case) plus a line of body. The leading window means
  // source code that incidentally contains "exit code:" /
  // "failed" / "[guard]" further down the file no longer
  // triggers a false positive.
  const leadingWindow = 200;
  final head = result.length > leadingWindow
      ? result.substring(0, leadingWindow)
      : result;
  final lower = head.toLowerCase();
  return lower.startsWith('error') ||
      lower.startsWith('path not found') ||
      lower.startsWith('[guard]') ||
      lower.contains('exit code:') && lower.contains('failed');
}