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

/// One segment per user turn. Boxes are `null` when their data is
/// empty — the renderer emits nothing in that case rather than
/// rendering an empty bordered region.
///
/// [showUserMessage] is always `true`: with one segment per turn,
/// there's no second segment to dedupe against.
///
/// [prose] is the closing `ai` message's content. [midProse] is
/// mid-round prose accumulated from `tool_call` messages with
/// non-empty `content` (e.g. the agent says "Let me check that for
/// you." alongside a bash call) — kept separately so the renderer
/// can render it above [prose] in temporal order. When [prose] is
/// `null` (pending segment — no closing `ai` yet) and only [midProse]
/// is non-null, the renderer falls back to showing [midProse]
/// alone. Either or both may be null for a pending / boxes-only
/// segment.
class VibeSegment {
  final Message userMessage;
  final ThinkBoxData? think;
  final ToolBoxData? tools;
  final ModBoxData? mods;
  final Message? prose;
  final String? midProse;
  final bool showUserMessage;

  const VibeSegment({
    required this.userMessage,
    this.think,
    this.tools,
    this.mods,
    this.prose,
    this.midProse,
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

/// Pure function: messages + results → segment list. No side effects.
///
/// Walks messages in order and emits **one [VibeSegment] per user
/// turn** — bounded by the user's `role: 'user'` row on the start
/// side and the closing `role: 'ai'` row on the end side. The
/// boundary is asymmetric on purpose:
///
/// * A `role: 'tool_call'` with non-empty `content` (a mid-round
///   remark like "Let me check that for you.") does **not** close a
///   segment. Its `content` is captured into the segment's
///   [VibeSegment.midProse] buffer and rendered above the closing
///   `ai`'s prose. The earlier design closed on `tool_call` with
///   content, which made a multi-round turn with mid-prose emit
///   **two** segments — each carrying its own think/tools boxes —
///   so the user saw duplicate think/tools inside what looked like
///   one logical turn. Collapsing to one segment per user turn
///   keeps the boxes aggregated and the prose naturally merged.
/// * A `role: 'ai'` row always closes the current segment, with
///   its `content` becoming [VibeSegment.prose].
///
/// System-role messages are skipped entirely (they never enter a
/// segment). [resultsByCallId] maps tool-call IDs to their result
/// messages so the per-call [CollapsedSummary] can be computed;
/// [toolRegistry] is used to look up each [ToolDef] for the summary.
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
  // Mid-round prose buffer: tool_call messages with non-empty
  // content append here; the closing ai (or end-of-walk) merges
  // it into the final segment's VibeSegment.midProse field.
  String? pendingMidProse;

  for (final msg in messages) {
    // Skip system-role messages entirely.
    if (_systemRoles.contains(msg.role)) continue;

    if (msg.role == 'user') {
      // User boundary: close the previous turn's segment (if any)
      // with whatever prose we've accumulated, then reset.
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
        pendingMidProse,
        null,
      );
      currentUser = msg;
      thinkDuration = Duration.zero;
      thinkTokens = 0;
      thinkEffort = null;
      toolEntries.clear();
      toolOrder.clear();
      toolTotalTokens = 0;
      modPaths.clear();
      modLinesAdded.clear();
      modLinesRemoved.clear();
      pendingMidProse = null;
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

      // Track prose. A tool_call with content appends to the
      // mid-round buffer (no close); an ai row closes the segment.
      if (msg.role == 'ai') {
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
          pendingMidProse,
          msg,
        );
        // Reset accumulators for the next turn.
        thinkDuration = Duration.zero;
        thinkTokens = 0;
        thinkEffort = null;
        toolEntries.clear();
        toolOrder.clear();
        toolTotalTokens = 0;
        modPaths.clear();
        modLinesAdded.clear();
        modLinesRemoved.clear();
        pendingMidProse = null;
        currentUser = null;
      } else if (msg.content.isNotEmpty) {
        // Mid-round prose: append to the buffer, do NOT close.
        pendingMidProse = pendingMidProse == null
            ? msg.content
            : '$pendingMidProse\n\n${msg.content}';
      }
    }
    // `role: 'tool'` messages are result rows — they pair with the
    // preceding `tool_call` by `toolCallId`. The pairing happens
    // above when we look up `resultsByCallId[tc.callId]`, so we
    // don't need to process tool-result messages here.
  }

  // Trailing flush: emit a pending segment for any unclosed turn.
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
    pendingMidProse,
    null,
  );

  return segments;
}

/// Emit a [VibeSegment] for the current user turn, if any. Used at
/// three sites:
///
///   * on a new `role: 'user'` row (flushing the previous turn),
///   * on a closing `role: 'ai'` row (midProse + mainProse attached),
///   * at end-of-walk (trailing segment for an unclosed turn).
///
/// [currentUser] is the segment anchor (the user message that
/// opened the turn). When null, no emission — caller's responsibility
/// to skip.
///
/// When [currentUser] is non-null, emission always happens. The
/// "pending" case (user just typed, agent hasn't replied — no
/// boxes, no prose yet) is legitimate: the renderer shows the
/// `you:` line so the user sees their own input reflected back.
/// Boxes and prose fields stay null and the renderer simply hides
/// them.
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
  String? midProse,
  Message? mainProse,
) {
  if (currentUser == null) return;

  final entries = toolOrder.map((name) => toolEntries[name]!).toList();
  final hasThink = thinkDuration.inMilliseconds > 0 || thinkTokens > 0;

  segments.add(VibeSegment(
    userMessage: currentUser,
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
    prose: mainProse,
    midProse: midProse,
  ));
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
