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

/// One segment per prose-bearing round. Boxes are `null` when their
/// data is empty — the renderer emits nothing in that case rather than
/// rendering an empty bordered region.
///
/// [showUserMessage] is `true` only for the first segment after a user
/// turn, so the user's input appears exactly once. Subsequent segments
/// (from `tool_call` with content + later `ai` message) omit the user
/// line to avoid repetition.
///
/// [prose] is `null` for a "pending" segment — the user has typed but
/// the agent hasn't emitted a closing `ai` message yet. The renderer
/// shows the user line + any accumulated boxes but no prose.
class VibeSegment {
  final Message userMessage;
  final ThinkBoxData? think;
  final ToolBoxData? tools;
  final ModBoxData? mods;
  final Message? prose;
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

/// Pure function: messages + results → segment list. No side effects.
///
/// Walks messages in order, grouping into segments bounded by
/// `role: 'ai'` response bodies (or `role: 'tool_call'` messages with
/// non-empty `content`). System-role messages are skipped entirely.
///
/// [resultsByCallId] maps tool-call IDs to their result messages so
/// the per-call [CollapsedSummary] can be computed. [toolRegistry] is
/// used to look up each [ToolDef] for the summary computation.
List<VibeSegment> walkSegments(
  List<Message> messages,
  Map<String, Message> resultsByCallId,
  ToolRegistry toolRegistry,
) {
  final segments = <VibeSegment>[];

  Message? currentUser;
  bool userMessageShown = false;
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

  for (final msg in messages) {
    // Skip system-role messages entirely.
    if (_systemRoles.contains(msg.role)) continue;

    if (msg.role == 'user') {
      // Start a new user turn — flush any pending segment first.
      _emitPending(segments, currentUser, userMessageShown, thinkDuration,
          thinkTokens, thinkEffort, toolEntries, toolOrder, toolTotalTokens,
          modPaths, modLinesAdded, modLinesRemoved);
      currentUser = msg;
      userMessageShown = false;
      thinkDuration = Duration.zero;
      thinkTokens = 0;
      thinkEffort = null;
      toolEntries.clear();
      toolOrder.clear();
      toolTotalTokens = 0;
      modPaths.clear();
      modLinesAdded.clear();
      modLinesRemoved.clear();
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

      // Check if this message closes the segment.
      // A `role: 'ai'` row always closes. A `role: 'tool_call'` with
      // non-empty `content` also closes (mixed round with prose).
      final closesSegment = msg.role == 'ai' ||
          (msg.role == 'tool_call' && msg.content.isNotEmpty);

      if (closesSegment && currentUser != null) {
        final entries = toolOrder
            .map((name) => toolEntries[name]!)
            .toList();

        segments.add(VibeSegment(
          userMessage: currentUser,
          showUserMessage: !userMessageShown,
          think: thinkDuration.inMilliseconds > 0 || thinkTokens > 0
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
          prose: msg,
        ));
        userMessageShown = true;

        // Reset accumulators for the next segment.
        thinkDuration = Duration.zero;
        thinkTokens = 0;
        thinkEffort = null;
        toolEntries.clear();
        toolOrder.clear();
        toolTotalTokens = 0;
        modPaths.clear();
        modLinesAdded.clear();
        modLinesRemoved.clear();
        // Only clear currentUser when the closing message is 'ai'.
        // When a 'tool_call' with content closes (mixed round), keep
        // currentUser so the subsequent 'ai' message can emit another
        // segment with the full response. Without this, the agent's
        // final reply is silently lost in vibe mode.
        if (msg.role == 'ai') {
          currentUser = null;
        }
      }
    }
    // `role: 'tool'` messages are result rows — they pair with the
    // preceding `tool_call` by `toolCallId`. The pairing happens
    // above when we look up `resultsByCallId[tc.callId]`, so we
    // don't need to process tool-result messages here.
  }

  // After walking all messages, emit a pending segment if the user
  // has typed but the agent hasn't emitted a closing message yet.
  // This ensures the user's input appears immediately, and any
  // accumulated think/tools boxes from completed-but-unclosed rounds
  // are visible during streaming.
  _emitPending(segments, currentUser, userMessageShown, thinkDuration,
      thinkTokens, thinkEffort, toolEntries, toolOrder, toolTotalTokens,
      modPaths, modLinesAdded, modLinesRemoved);

  return segments;
}

/// Emit a pending segment if there's an unclosed user turn.
///
/// Called when a new user message arrives (flushing the previous
/// turn's pending state) and after walking all messages (flushing
/// the current turn). Only emits if [currentUser] is non-null AND
/// there's something to show: either the user message hasn't been
/// shown yet, or there are accumulated think/tools/mods boxes.
void _emitPending(
  List<VibeSegment> segments,
  Message? currentUser,
  bool userMessageShown,
  Duration thinkDuration,
  int thinkTokens,
  String? thinkEffort,
  Map<String, ToolBoxEntry> toolEntries,
  List<String> toolOrder,
  int toolTotalTokens,
  List<String> modPaths,
  Map<String, int> modLinesAdded,
  Map<String, int> modLinesRemoved,
) {
  if (currentUser == null) return;

  final entries = toolOrder.map((name) => toolEntries[name]!).toList();
  final hasBoxes = thinkDuration.inMilliseconds > 0 ||
      thinkTokens > 0 ||
      entries.isNotEmpty ||
      modPaths.isNotEmpty;

  // Only emit if the user message hasn't been shown yet, or there
  // are accumulated boxes to display.
  if (userMessageShown && !hasBoxes) return;

  segments.add(VibeSegment(
    userMessage: currentUser,
    showUserMessage: !userMessageShown,
    think: thinkDuration.inMilliseconds > 0 || thinkTokens > 0
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
    prose: null,
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
