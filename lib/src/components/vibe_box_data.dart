import 'package:path/path.dart' as p;

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

  const ToolBoxData({required this.entries, required this.totalTokens});
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

/// One [VibeSegment] per prose boundary in the message list.
///
/// Spec (see `docs/design-vibe-mode.md`, "Segmentation" section):
/// segments are bounded by **response bodies** — every
/// `role: 'tool_call'` row whose embedded `content` is non-empty
/// (a mid-round remark alongside a tool call) and every
/// `role: 'ai'` row closes the running segment and emits a fresh
/// one. Multiple consecutive closings within one user turn
/// produce multiple segments: for example, two consecutive
/// `role: 'ai'` rows (the agent emitting follow-up prose without
/// a tool call between them) yield two segments that share the
/// same [userMessage].
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
/// [prose] is the closing message itself — a [Message] whose
/// `content` is what the renderer displays. For a `role: 'ai'`
/// that's the final reply; for a `role: 'tool_call'` with
/// content that's the mid-round remark that provoked this
/// close. Null on a user-boundary flush where the previous turn
/// had no close, or on a trailing flush of a pending turn
/// without an ai yet.
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
  //
  // `modPaths` is the list of full paths in first-seen order.
  // `seenModBasenames` is the basename-keyed dedup set: two
  // tool calls naming the same file with different path strings
  // land on the same basename entry, so the files box never
  // shows the same basename twice. `modLinesAdded` /
  // `modLinesRemoved` are keyed by basename for the same reason.
  // The `_emitSegment` fold translates back to basenames when
  // summing diffs across the 8-row cap.
  final modPaths = <String>[];
  final seenModBasenames = <String>{};
  final modLinesAdded = <String, int>{};
  final modLinesRemoved = <String, int>{};
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
        null,
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
      seenModBasenames.clear();
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
          // Dedupe by `p.basename`, NOT by the full path string:
          // the LLM can name the same file with different path
          // strings across tool calls (absolute vs. relative,
          // with or without a leading `./`, occasionally with
          // redundant `.` segments). String equality on the full
          // path would miss those, leaving the file with two
          // rows in the files box — same basename, same +N -M
          // diff, twice. The box only ever renders the basename
          // anyway, so basename is the right key.
          if (toolDef != null && toolResult != null) {
            final modSummary = toolDef.modSummary(tc.input, toolResult);
            if (modSummary != null) {
              for (final change in modSummary.changes) {
                final base = p.basename(change.path);
                if (base.isEmpty) continue;
                if (!seenModBasenames.add(base)) {
                  // Same file already in this segment under a
                  // different path string — fold the diff into
                  // the existing entry rather than creating a new
                  // row.
                  modLinesAdded[base] =
                      (modLinesAdded[base] ?? 0) + change.linesAdded;
                  modLinesRemoved[base] =
                      (modLinesRemoved[base] ?? 0) + change.linesRemoved;
                  continue;
                }
                modPaths.add(change.path);
                modLinesAdded[base] = change.linesAdded;
                modLinesRemoved[base] = change.linesRemoved;
              }
            }
          }
        }
      }

      // Prose-boundary check. Per spec rule 2.3 / rule 3:
      // * role: 'tool_call' with non-empty content — close.
      // * role: 'ai' — close.
      // Either kind closes the running segment; the closing
      // message's content becomes the segment's prose.
      //
      // Why both paths close: rule 2.3 explicitly lists
      // tool_call-with-content as a prose boundary. Skipping
      // that close was the mistake that collapsed multi-emit
      // turns into a single segment and made consecutive
      // `role: 'ai'` rows appear as one vibe segment.
      //
      // Tool-call's `content` here is checked with `trim().isNotEmpty`
      // rather than the literal `isNotEmpty`: the LLM frequently
      // emits tool_call rows with whitespace-only or single-token
      // content ("OK", "got it", " ".trim()==""), and treating those
      // as prose boundaries would emit a segment whose prose the
      // renderer then refuses to draw (the renderer's
      // `content.trim().isNotEmpty` guard skips the whole crux:
      // row). That left a "two box groups with no response
      // between them" gap in vibe mode. The trim() check matches
      // the renderer's notion of "actually has prose" so the
      // walker and renderer agree on what counts as a boundary.
      final closesSegment =
          msg.role == 'ai' ||
          (msg.role == 'tool_call' && msg.content.trim().isNotEmpty);

      if (closesSegment && currentUser != null) {
        // The segment's prose is the closing message itself —
        // its `content` is what the renderer displays. For
        // a `role: 'ai'` that's the final reply; for a
        // `role: 'tool_call'` with content that's the mid-round
        // remark that provoked this close. Either way the
        // segment carries the closing row in [VibeSegment.prose].
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
          msg,
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
        seenModBasenames.clear();
        modLinesAdded.clear();
        modLinesRemoved.clear();
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
  // closing message landed — emit a pending segment so the
  // `you:` line shows the user's input immediately.
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
    null,
    showUserLine: !userLineShown,
  );

  return segments;
}

/// Emit a [VibeSegment] if there's anything to show.
///
/// [currentUser] is the segment anchor. When null, no emit.
///
/// [closing] is the closing message — `role: 'ai'` (final reply)
/// or `role: 'tool_call'` with non-empty content (mid-round
/// remark). Its `content` becomes the segment's prose via the
/// caller binding it onto [VibeSegment.prose]. When null this is
/// either a user-boundary flush or a trailing-flush of a
/// pending-but-not-closed turn.
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
  Message? closing, {
  required bool showUserLine,
}) {
  if (currentUser == null) return;

  final entries = toolOrder.map((name) => toolEntries[name]!).toList();
  final hasThink = thinkDuration.inMilliseconds > 0 || thinkTokens > 0;
  final hasBoxes = hasThink || entries.isNotEmpty || modPaths.isNotEmpty;
  final hasProse = closing != null;

  // Skip when the flush has nothing to show: no boxes, no
  // closing message. Pending-only emission (user just typed,
  // no agent output yet) lands here too when currentUser is
  // set but accumulators are empty and there's no closing —
  // we want to emit that case (showUserLine=true makes it
  // carry the user line), so the guard is gated on showUserLine.
  if (!hasBoxes && !hasProse && !showUserLine) return;

  segments.add(
    VibeSegment(
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
              // Sum diffs by basename (the dedup key) — modLinesAdded
              // is keyed by basename, not by the full path in `paths`.
              // Loop var `path` deliberately shadows the `path` package
              // alias `p` so the fold reads naturally; `p.basename(path)`
              // would be a self-call.
              linesAdded: modPaths
                  .take(8)
                  .fold(
                    0,
                    (sum, path) => sum + (modLinesAdded[p.basename(path)] ?? 0),
                  ),
              linesRemoved: modPaths
                  .take(8)
                  .fold(
                    0,
                    (sum, path) =>
                        sum + (modLinesRemoved[p.basename(path)] ?? 0),
                  ),
              overflowCount: modPaths.length > 8 ? modPaths.length - 8 : 0,
            )
          : null,
      prose: closing,
    ),
  );
}

/// Format a token count for display in the tools box.
///
///   543   → "543 tokens"
///   2100  → "2.1k tokens"
///   12000 → "12k tokens"
String formatTokens(int tokens) {
  if (tokens >= 1000) {
    final k = tokens / 1000;
    final str = k >= 10 ? k.round().toString() : k.toStringAsFixed(1);
    return '${k >= 10 ? k.round() : str}k tokens';
  }
  return '$tokens tokens';
}
