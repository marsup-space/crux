import '../models/message.dart';
import '../tools/tool_def.dart';
import '../tools/registry.dart';
import '../utils/token_estimate.dart';

/// Aggregated think-box data for one vibe segment.
///
/// All fields are summed across reasoning rounds within the segment.
/// [effort] is the last round's effort (highest precedence wins —
/// effort doesn't average well). Stored as a raw string because many
/// models override the display value (e.g. MiniMax maps `normal` →
/// `adaptive`).
class ThinkBoxData {
  final Duration duration;
  final int tokens;
  final String? effort;

  const ThinkBoxData({
    required this.duration,
    required this.tokens,
    this.effort,
  });
}

/// Per-tool entry in the tools box. [name] is the tool's short name,
/// [callCount] is how many times it was called in this segment,
/// [totalTokens] is the sum of each call's token estimate.
class ToolBoxEntry {
  final String name;
  final int callCount;
  final int totalTokens;

  const ToolBoxEntry({
    required this.name,
    required this.callCount,
    required this.totalTokens,
  });
}

/// Aggregated tools-box data for one vibe segment.
///
/// [entries] preserves first-occurrence order with later duplicates
/// dropped — gives "I worked through these" not "I churned on these".
/// [totalTokens] is the grand total across all entries.
class ToolBoxData {
  final List<ToolBoxEntry> entries;
  final int totalTokens;

  const ToolBoxData({
    required this.entries,
    required this.totalTokens,
  });
}

/// Aggregated files-box data for one vibe segment.
///
/// [paths] preserves first-touch order, capped at 8 entries.
/// [overflowCount] is the number of files past the 8-row cap.
/// [linesAdded] / [linesRemoved] are sums across the segment.
class ModBoxData {
  final List<String> paths;
  final int linesAdded;
  final int linesRemoved;
  final int overflowCount;

  const ModBoxData({
    required this.paths,
    required this.linesAdded,
    required this.linesRemoved,
    required this.overflowCount,
  });
}

/// One [VibeSegment] per `role: 'ai'` row (response body).
///
/// Spec (see `docs/design-vibe-mode.md`, "Segmentation" section):
/// segments are bounded by response bodies — every `role: 'ai'`
/// row closes the running segment and emits a fresh one. The
/// agent's reasoning, tool calls, and tool results that landed
/// since the previous `role: 'ai'` (or the user start of turn)
/// are folded into the segment's think/tools/files boxes; the
/// `role: 'ai'` row's `content` is the segment's prose.
///
/// `role: 'tool_call'` rows do **not** close a segment on their
/// own — they just contribute to the running segment's boxes
/// and (for any non-empty `content`) to the prose buffer.
/// Multiple consecutive `role: 'ai'` rows in one user turn
/// (the agent emitting follow-up prose without a tool call
/// between them) produce multiple segments that share the same
/// [userMessage].
///
/// Each segment's boxes are the **window** of work that landed
/// since the previous close: reasoning/tool rounds accumulate,
/// then a close fires and the walker emits a segment with those
/// boxes plus the closing message's content as the prose. The
/// walker resets the accumulators right after each emit, so the
/// next segment's boxes are unique to its own window — no carry-
/// over means no duplicate think/tools boxes across segments in
/// the same turn.
///
/// [prose] is the **concatenated** prose string for the
/// segment: the closing `role: 'ai'` row's `content`, joined
/// with `\n\n` to any non-empty `role: 'tool_call'` row's
/// `content` that landed in the segment's window. The walker's
/// per-`role: 'ai'` close fires AFTER the `tool_call_with_content`
/// has been accumulated, so the segment's prose can include
/// mid-round text ("let me check first") plus the final answer
/// ("here is the result") on the same row.
///
/// [showUserMessage] is `true` on the **first** segment that each
/// user turn produces, `false` thereafter. With multiple
/// segments per turn now possible (see docstring above), only
/// the first shows the `you:` line so the user's input appears
/// once.
class VibeSegment {
  final Message userMessage;
  final ThinkBoxData? think;
  final ToolBoxData? tools;
  final ModBoxData? mods;
  final String? prose;
  final bool showUserMessage;

  const VibeSegment({
    required this.userMessage,
    this.think,
    this.tools,
    this.mods,
    this.prose,
    this.showUserMessage = true,
  });
}

/// System roles that the segment walker skips entirely — they never
/// enter a segment and never render in vibe mode.
const _systemRoles = {
  'parallel_praise',
  'single_call_reminder',
  'lsp_diagnostics',
  'tool_guard',
  'shell_guard',
  'compaction',
};

/// Pure function: messages + results → segment list. No side
/// effects. See [VibeSegment] for the docstring that captures
/// the segmentation model verbatim.
///
/// In short: each **response body** — `role: 'tool_call'` with
/// non-empty `content` (a mixed round, per spec rule 2.3) or
/// `role: 'ai'` (per spec rule 3) — emits a [VibeSegment] anchored
/// to the current user and resets the box accumulators, so the
/// next segment's boxes describe only the work that lands after
/// that close. `currentUser` is **not** cleared after a close so
/// consecutive closings (e.g. two `role: 'ai'` rows back to back)
/// stay anchored to the same user. The walker resets
/// `currentUser` only when it sees the next `role: 'user'` row.
///
/// [resultsByCallId] maps tool-call IDs to their result messages
/// so the per-call [CollapsedSummary] can be computed;
/// [toolRegistry] is used to look up each [ToolDef] for the
/// summary.
List<VibeSegment> walkSegments(
  List<Message> messages,
  Map<String, Message> resultsByCallId,
  ToolRegistry toolRegistry,
) {
  final segments = <VibeSegment>[];

  Message? currentUser;
  Duration thinkDuration = Duration.zero;
  int thinkTokens = 0;
  String? thinkEffort;
  final toolEntries = <String, ToolBoxEntry>{};
  final toolOrder = <String>[];
  int toolTotalTokens = 0;
  // Files-box accumulators.
  final modPaths = <String>[];
  final modLinesAdded = <String, int>{};
  final modLinesRemoved = <String, int>{};
  // Prose buffer for the current user turn. Every `role: 'ai'`
  // row's `content` and every non-empty `role: 'tool_call'`
  // row's `content` is appended (via [_appendProse]) until the
  // turn ends at a user boundary or end of walk. The buffer
  // becomes the segment's [VibeSegment.prose] at emit time.
  String? proseBuffer;
  // `true` once the current user turn has produced its first
  // emitted segment. The first segment carries the `you:` line;
  // siblings in the same turn render prose only. Reset on
  // user-boundary.
  bool userLineShown = false;

  for (final msg in messages) {
    // Skip system-role messages entirely.
    if (_systemRoles.contains(msg.role)) continue;

    if (msg.role == 'user') {
      // Flush whatever the previous turn's pending state looks
      // like, then reset for the new turn. This is also the
      // path that emits the pending segment for a user who
      // typed but never received a response.
      _emitSegment(
        segments,
        currentUser,
        thinkDuration,
        thinkTokens,
        thinkEffort,
        toolEntries,
        toolOrder,
        toolTotalTokens,
        modPaths,
        modLinesAdded,
        modLinesRemoved,
        proseBuffer,
        showUserLine: !userLineShown,
      );
      currentUser = msg;
      userLineShown = false;
      thinkDuration = Duration.zero;
      thinkTokens = 0;
      thinkEffort = null;
      toolEntries.clear();
      toolOrder.clear();
      toolTotalTokens = 0;
      modPaths.clear();
      modLinesAdded.clear();
      modLinesRemoved.clear();
      proseBuffer = null;
      continue;
    }

    if (msg.role == 'ai' || msg.role == 'tool_call') {
      // Accumulate think data from reasoning-bearing messages.
      if (msg.reasoningContent.isNotEmpty) {
        thinkDuration += Duration(milliseconds: msg.thinkingDurationMs);
        // Fall back to estimating from content when the persisted
        // token count is 0 (many providers don't populate it).
        thinkTokens += msg.reasoningTokens > 0
            ? msg.reasoningTokens
            : estimateTokens(msg.reasoningContent);
        if (msg.reasoningEffort != null) {
          thinkEffort = msg.reasoningEffort;
        }
      }

      // Accumulate tools data from tool_call messages.
      if (msg.toolCalls.isNotEmpty) {
        for (final tc in msg.toolCalls) {
          final toolDef = toolRegistry.lookup(tc.name);
          final resultMsg = resultsByCallId[tc.callId];
          int callTokens = 0;
          // Construct the ToolResult once so both the collapsedSummary
          // and modSummary calls share the same object.
          final toolResult = (toolDef != null && resultMsg != null)
              ? ToolResult(title: '', output: resultMsg.content)
              : null;
          if (toolDef != null && toolResult != null) {
            final summary = toolDef.collapsedSummary(tc.input, toolResult);
            callTokens = summary.totalTokens > 0
                ? summary.totalTokens
                : estimateTokens(resultMsg!.content);
          } else if (resultMsg != null) {
            callTokens = estimateTokens(resultMsg.content);
          }

          if (!toolEntries.containsKey(tc.name)) {
            toolOrder.add(tc.name);
          }
          final prev = toolEntries[tc.name];
          toolEntries[tc.name] = ToolBoxEntry(
            name: tc.name,
            callCount: (prev?.callCount ?? 0) + 1,
            totalTokens: (prev?.totalTokens ?? 0) + callTokens,
          );
          toolTotalTokens += callTokens;

          // Accumulate file-modification data via the modSummary hook.
          if (toolDef != null && toolResult != null) {
            final modSummary = toolDef.modSummary(tc.input, toolResult);
            if (modSummary != null) {
              for (final change in modSummary.changes) {
                if (!modPaths.contains(change.path)) {
                  modPaths.add(change.path);
                  modLinesAdded[change.path] = 0;
                  modLinesRemoved[change.path] = 0;
                }
                modLinesAdded[change.path] =
                    modLinesAdded[change.path]! + change.linesAdded;
                modLinesRemoved[change.path] =
                    modLinesRemoved[change.path]! + change.linesRemoved;
              }
            }
          }
        }
      }

      // Prose-buffer accumulation. The segment's prose is the
      // closing `role: 'ai'` row's content, joined with `\n\n` to
      // any non-empty `role: 'tool_call'` row's `content` that
      // landed in the segment's window. We accumulate into
      // `proseBuffer` rather than emit-on-tool_call-with-content
      // so the segment's prose carries the mid-round remark
      // ("let me check first") AND the final answer ("here is
      // the result") on the same row — both belong to the
      // same response-window per the per-`role: 'ai'` model.
      //
      // The `trim().isNotEmpty` guard on tool_call content keeps
      // whitespace-only / single-token "OK"-style mid-round
      // remarks from polluting the buffer (and matches the
      // renderer's notion of "actually has prose").
      if (msg.role == 'ai') {
        proseBuffer = _appendProse(proseBuffer, msg.content);
      } else if (msg.content.trim().isNotEmpty) {
        proseBuffer = _appendProse(proseBuffer, msg.content);
      }

      // Close boundary. Per the per-`role: 'ai'` model, only
      // `role: 'ai'` closes a segment. `role: 'tool_call'`
      // never closes (regardless of `content`) — its content
      // (when non-empty) joins the prose buffer above, and its
      // tools accumulate to the segment's tools box. This
      // matches the spec's "segment is bounded by a response
      // body from the LLM (role: 'ai')" framing.
      if (msg.role == 'ai' && currentUser != null) {
        _emitSegment(
          segments,
          currentUser,
          thinkDuration,
          thinkTokens,
          thinkEffort,
          toolEntries,
          toolOrder,
          toolTotalTokens,
          modPaths,
          modLinesAdded,
          modLinesRemoved,
          proseBuffer,
          showUserLine: !userLineShown,
        );
        userLineShown = true;
        // Reset accumulators so the next segment's box window
        // is its own (see [VibeSegment] docstring — this is
        // what prevents duplicate think/tools boxes across
        // segments in the same turn).
        thinkDuration = Duration.zero;
        thinkTokens = 0;
        thinkEffort = null;
        toolEntries.clear();
        toolOrder.clear();
        toolTotalTokens = 0;
        modPaths.clear();
        modLinesAdded.clear();
        modLinesRemoved.clear();
        proseBuffer = null;
        // Critically, do NOT clear `currentUser` here. The
        // spec doesn't say to, and the earlier implementation
        // did — that's what silently dropped a 2nd
        // `role: 'ai'` row when it appeared in the same turn.
        // Multiple closures within one user turn anchor
        // against the same user row.
      }
    }
    // `role: 'tool'` messages are result rows — they pair with the
    // preceding `tool_call` by `toolCallId`. The pairing happens
    // above when we look up `resultsByCallId[tc.callId]`, so we
    // don't need to process tool-result messages here.
  }

  // Trailing flush: a user has typed (currentUser set) but no
  // `role: 'ai'` row arrived — emit a pending segment for the
  // open turn so the `you:` line shows the user's input
  // immediately and any accumulated boxes (think from a fresh
  // reasoning burst, etc.) render. `proseBuffer` carries any
  // mid-round content (`role: 'tool_call'` rows that landed
  // since the user) so a thinking-only or tool-only turn still
  // shows the mid-round remark on the pending segment's row.
  _emitSegment(
    segments,
    currentUser,
    thinkDuration,
    thinkTokens,
    thinkEffort,
    toolEntries,
    toolOrder,
    toolTotalTokens,
    modPaths,
    modLinesAdded,
    modLinesRemoved,
    proseBuffer,
    showUserLine: !userLineShown,
  );

  return segments;
}

/// Emit a [VibeSegment] if there's anything to show.
///
/// [currentUser] is the segment anchor. When null, no emit.
///
/// [prose] is the pre-joined prose string for the segment
/// (built up by [walkSegments] across every `ai` and non-empty
/// `tool_call` row in the segment's window). When null this is
/// either a user-boundary flush where the previous turn never
/// produced any prose, or a trailing-flush of a pending-but-not-
/// closed turn.
///
/// [showUserLine] controls [VibeSegment.showUserMessage]:
/// `true` on the first emit of a user turn, `false` thereafter so
/// the `you:` line appears only once per turn.
///
/// Emit is suppressed when there's nothing visible — e.g. a
/// flush at a user boundary where the previous turn already
/// emitted everything. Without this guard the trailing flush
/// would pile empty duplicates onto the list whenever the user's
/// turn was already closed by `ai`.
void _emitSegment(
  List<VibeSegment> segments,
  Message? currentUser,
  Duration thinkDuration,
  int thinkTokens,
  String? thinkEffort,
  Map<String, ToolBoxEntry> toolEntries,
  List<String> toolOrder,
  int toolTotalTokens,
  List<String> modPaths,
  Map<String, int> modLinesAdded,
  Map<String, int> modLinesRemoved,
  String? prose, {
  required bool showUserLine,
}) {
  if (currentUser == null) return;

  final entries = toolOrder.map((name) => toolEntries[name]!).toList();
  final hasThink = thinkDuration.inMilliseconds > 0 || thinkTokens > 0;
  final hasBoxes = hasThink || entries.isNotEmpty || modPaths.isNotEmpty;
  // A non-null and non-empty prose is the test for whether the
  // row actually has content to draw. Empty-string prose is
  // treated like null — the row is hidden.
  final hasProse = prose != null && prose.isNotEmpty;

  // Skip when the flush has nothing to show: no boxes, no
  // prose. Pending-only emission (user just typed, no agent
  // output yet) lands here too when currentUser is set but
  // accumulators are empty and there's no closing — we want
  // to emit that case (showUserLine=true makes it carry the
  // user line), so the guard is gated on showUserLine.
  if (!hasBoxes && !hasProse && !showUserLine) return;

  segments.add(VibeSegment(
    userMessage: currentUser,
    showUserMessage: showUserLine,
    think: hasThink
        ? ThinkBoxData(
            duration: thinkDuration,
            tokens: thinkTokens,
            effort: thinkEffort,
          )
        : null,
    tools: entries.isNotEmpty
        ? ToolBoxData(entries: entries, totalTokens: toolTotalTokens)
        : null,
    mods: modPaths.isNotEmpty
        ? ModBoxData(
            paths: modPaths.take(8).toList(),
            linesAdded: modPaths.take(8).fold(0,
                (sum, p) => sum + (modLinesAdded[p] ?? 0)),
            linesRemoved: modPaths.take(8).fold(0,
                (sum, p) => sum + (modLinesRemoved[p] ?? 0)),
            overflowCount: modPaths.length > 8 ? modPaths.length - 8 : 0,
          )
        : null,
    prose: prose,
  ));
}

/// Join two prose snippets with a blank line, treating empty /
/// whitespace-only inputs as no-op. Used by [walkSegments] to
/// fold every `role: 'ai'` row's `content` and every non-empty
/// `role: 'tool_call'` row's `content` into a single
/// concatenated [VibeSegment.prose] string for the segment.
String? _appendProse(String? existing, String addition) {
  final trimmedAdd = addition.trim();
  if (trimmedAdd.isEmpty) return existing;
  final trimmedExisting = existing?.trim();
  if (trimmedExisting == null || trimmedExisting.isEmpty) {
    return trimmedAdd;
  }
  return '$trimmedExisting\n\n$trimmedAdd';
}

/// Format a token count for display in the tools box.
///
///   543   → "543 tokens"
///   2100  → "2.1k tokens"
///   12000 → "12k tokens"
String formatTokens(int tokens) {
  if (tokens >= 1000) {
    final k = tokens / 1000;
    final str = k >= 10
        ? k.round().toString()
        : k.toStringAsFixed(1);
    return '${k >= 10 ? k.round() : str}k tokens';
  }
  return '$tokens tokens';
}
