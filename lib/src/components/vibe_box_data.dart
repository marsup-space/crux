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

/// One [VibeSegment] per user turn.
///
/// **Per-turn model** (departure from the prose-bounded spec in
/// `docs/design-vibe-mode.md`): segments are bounded by `role:
/// 'user'` rows, not by every `role: 'ai'` or `role: 'tool_call'`
/// close. The walker accumulates think/tools/mods and a
/// concatenated prose buffer across the entire turn, and only
/// emits at the user-boundary flush or the trailing flush at end
/// of walk.
///
/// Why this beats the per-close model: a typical agent turn
/// interleaves thinking, tool execution, and prose
/// (text+tools+text+tools+text). With per-close emission each
/// intermediate close resets the accumulators, so the think/tools
/// box for round N lands on segment N but round N+1's
/// accumulation doesn't carry N's data into the next segment.
/// The user sees a think box on segment 1 and a tools box on
/// segment 2 (or vice versa) — visually the "boxes split
/// across multiple segments" symptom. The per-turn model keeps
/// the entire turn's boxes together on the single segment that
/// represents the turn.
///
/// [prose] is the **concatenated** prose string for the turn:
/// every `role: 'ai'` row's `content` and every `role:
/// 'tool_call'` row's non-empty `content` gets joined with
/// `\n\n` and stored here. Earlier messages in the turn are
/// preserved (the "let me check first" mid-round remark + the
/// final "here is the answer" both show up), but the source
/// [Message] object is dropped — only the joined text survives.
/// `null` on a turn with no `ai` row yet (pending turn) or no
/// prose at all (boxes-only turn).
///
/// [showUserMessage] is always `true`: one segment per turn, the
/// `you:` line shows on that one segment.
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
  // row's content and every non-empty `role: 'tool_call'` row's
  // content is appended (via [_appendProse]) until the turn ends
  // at a user boundary or end of walk. The buffer becomes the
  // segment's [VibeSegment.prose] at emit time.
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
      // User boundary: flush the previous turn's pending
      // state, then reset for the new turn. This is also the
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

      // Accumulate prose. We deliberately do NOT close on `ai`
      // or `role: 'tool_call'` rows here — see the per-turn model
      // comment on [VibeSegment]. The closing message of a turn
      // is the next `role: 'user'` row, and the trailing flush
      // handles the open-ended case at end of walk.
      //
      // Every `role: 'ai'` and every non-empty `role: 'tool_call'`
      // contributes to the prose buffer, joined with `\n\n`. The
      // trim() check on tool_call content matches the renderer's
      // `content.trim().isNotEmpty` guard so whitespace-only
      // "OK"-style mid-round remarks don't pollute the prose.
      if (msg.role == 'ai') {
        proseBuffer = _appendProse(proseBuffer, msg.content);
      } else if (msg.content.trim().isNotEmpty) {
        proseBuffer = _appendProse(proseBuffer, msg.content);
      }
    }
    // `role: 'tool'` messages are result rows — they pair with the
    // preceding `tool_call` by `toolCallId`. The pairing happens
    // above when we look up `resultsByCallId[tc.callId]`, so we
    // don't need to process tool-result messages here.
  }

  // Trailing flush: a user has typed (currentUser set) but no
  // new user row arrived — emit a pending segment for the open
  // turn so the `you:` line shows the user's input immediately
  // and any accumulated boxes (think from a fresh reasoning
  // burst, etc.) render at frame rate. proseBuffer carries any
  // mid-round or partial final-prose content the agent emitted
  // before the user navigated away.
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

/// Join two prose snippets with a blank line, treating empty /
/// whitespace-only inputs as no-op. Used by [walkSegments] to
/// fold multiple `ai` and `role: 'tool_call'` rows' content
/// into a single concatenated [VibeSegment.prose] string.
String? _appendProse(String? existing, String addition) {
  final trimmedAdd = addition.trim();
  if (trimmedAdd.isEmpty) return existing;
  final trimmedExisting = existing?.trim();
  if (trimmedExisting == null || trimmedExisting.isEmpty) {
    return trimmedAdd;
  }
  return '$trimmedExisting\n\n$trimmedAdd';
}

/// Emit a [VibeSegment] if there's anything to show.
///
/// [currentUser] is the segment anchor. When null, no emit.
///
/// [prose] is the pre-joined prose string for the turn (built
/// up by [walkSegments] across every `ai` and non-empty
/// `tool_call` row in the turn). When null this is either a
/// user-boundary flush where the previous turn never produced
/// any prose, or a trailing-flush of a pending-but-not-closed
/// turn.
///
/// [showUserLine] controls [VibeSegment.showUserMessage]:
/// per the per-turn model, every emitted segment is the only
/// segment of its turn, so this is always `true` at every emit
/// site. Kept as a parameter for symmetry with the per-close
/// model and to avoid touching [chat_history.dart]'s render
/// path which still reads this field.
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
