import 'dart:convert';

import 'package:path/path.dart' as p;

import '../models/message.dart';
import '../tools/tool_def.dart';
import '../tools/registry.dart';
import '../utils/subagent_meta.dart';
import '../utils/token_estimate.dart';
import '../utils/tool_meta.dart';

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
///
/// [lspState] is the **worst** per-call LSP outcome seen across this
/// entry's calls in the segment (errors > failed > clean > none), so
/// an aggregated `write x3` row turns red if *any* of the three edits
/// left diagnostics. Only write/edit carry a real state; every other
/// tool is [LspState.disabled] (no glyph). [LspState.none] is the gray
/// "no server for this file type" case, shown but muted.
class ToolBoxEntry {
  final String name;
  final int callCount;
  final int totalTokens;
  final LspState lspState;

  const ToolBoxEntry({
    required this.name,
    required this.callCount,
    required this.totalTokens,
    this.lspState = LspState.disabled,
  });
}

/// Rank an [LspState] for worst-state-wins aggregation: a higher
/// number is the more severe outcome. Used to fold many per-call
/// states into one row's displayed state. [LspState.disabled] ranks
/// below [LspState.none] so "LSP happened to be off" never outranks a
/// real outcome for a tool that did report one — though in practice
/// disabled is never persisted, so it only appears when a tool reports
/// nothing for an entire segment.
int lspStateSeverity(LspState s) => switch (s) {
  LspState.errors => 4,
  LspState.failed => 3,
  LspState.clean => 2,
  LspState.none => 1,
  LspState.disabled => 0,
};

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

/// One file's line delta within a [ModBoxData]. [path] is the display
/// path (relative when possible); [linesAdded] / [linesRemoved] are the
/// per-file diff counts summed across that file's calls in the segment.
class ModFileEntry {
  final String path;
  final int linesAdded;
  final int linesRemoved;

  const ModFileEntry(this.path, this.linesAdded, this.linesRemoved);
}

/// Aggregated files-box data for one vibe segment.
///
/// [paths] preserves first-touch order, capped at 8 entries.
/// [overflowCount] is the number of files past the 8-row cap.
/// [linesAdded] / [linesRemoved] are sums across the segment.
/// [files] carries the per-file entries (same order/cap as [paths]) so
/// the files box can render each row's own `+N -M` and so the diff
/// fullpane can seed the selected file's header counts.
class ModBoxData {
  final List<String> paths;
  final int linesAdded;
  final int linesRemoved;
  final int overflowCount;
  final List<ModFileEntry> files;

  const ModBoxData({
    required this.paths,
    required this.linesAdded,
    required this.linesRemoved,
    required this.overflowCount,
    this.files = const [],
  });
}

/// Aggregated progress-box data for one vibe segment — the persisted
/// echo of a long-running bash call that reported progress signals.
///
/// Parsed from the `shellProgress` field the shell base stamps into
/// `ToolResult.metadata` (and the chat executor persists into
/// `messages.meta`). Renders as a compact single-row box on reload;
/// the live bar is the streaming bubble's job.
class ProgressBoxData {
  /// Last phase word seen ("Downloading", "Installing", ...).
  final String? phase;

  /// Highest percent observed across the run, 0..100.
  final double? peakPercent;

  /// Wall-clock seconds the command ran (as measured by the tool).
  final int durationSec;

  /// Total stdout+stderr bytes produced.
  final int bytes;

  /// Process exit code; non-zero renders as a failure row.
  final int exitCode;

  const ProgressBoxData({
    this.phase,
    this.peakPercent,
    this.durationSec = 0,
    this.bytes = 0,
    this.exitCode = 0,
  });
}

/// Parse a [ProgressBoxData] out of a persisted `messages.meta` JSON
/// blob. Null when the blob has no (or malformed) `shellProgress`.
ProgressBoxData? progressFromMeta(String? meta) {
  if (meta == null || meta.isEmpty) return null;
  Map<String, dynamic>? root;
  try {
    final decoded = jsonDecode(meta);
    if (decoded is Map) root = decoded.cast<String, dynamic>();
  } catch (_) {
    return null;
  }
  final raw = root?['shellProgress'];
  if (raw is! Map) return null;
  final m = raw.cast<String, dynamic>();
  final phase = m['phase'];
  final peak = _progressNum(m['peakPercent']);
  final duration = _progressNum(m['durationSec'])?.round() ?? 0;
  final bytes = _progressNum(m['bytes'])?.round() ?? 0;
  final exitCode = _progressNum(m['exitCode'])?.round() ?? 0;
  if (phase is! String && peak == null && duration <= 0) return null;
  return ProgressBoxData(
    phase: phase is String ? phase : null,
    peakPercent: peak,
    durationSec: duration,
    bytes: bytes,
    exitCode: exitCode,
  );
}

double? _progressNum(dynamic v) => v is num ? v.toDouble() : null;

/// Merge two segment progress summaries (several bash calls in one
/// segment): longest duration, highest peak, summed bytes, last phase,
/// any non-zero exit wins.
ProgressBoxData mergeProgress(ProgressBoxData a, ProgressBoxData b) {
  return ProgressBoxData(
    phase: b.phase ?? a.phase,
    peakPercent: (a.peakPercent ?? 0) >= (b.peakPercent ?? 0)
        ? a.peakPercent
        : b.peakPercent,
    durationSec: a.durationSec > b.durationSec ? a.durationSec : b.durationSec,
    bytes: a.bytes + b.bytes,
    exitCode: (a.exitCode != 0) ? a.exitCode : b.exitCode,
  );
}

/// Aggregated agents-box data for one vibe segment — the commander↔worker
/// communication rows parsed from `agentBubble` meta (see `subagent_meta.dart`).
///
/// Rows preserve emission order. [entries] is capped at 6 with
/// [overflowCount] carrying the remainder, mirroring the files box's shape.
class AgentsBoxData {
  final List<AgentBubblePayload> entries;
  final int overflowCount;

  const AgentsBoxData({required this.entries, required this.overflowCount});
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
  final ProgressBoxData? progress;
  final AgentsBoxData? agents;
  final Message? prose;
  final bool showUserMessage;

  /// The segment's mutating `write`/`edit` tool calls, in emission
  /// order. The walker accumulates these alongside [ModBoxData] so the
  /// files box's `diff` action can rebuild each file's before/after from
  /// the persisted call args (old/new content) without re-reading the
  /// live file. Empty when the segment mutated nothing.
  final List<ToolCallData> modCalls;

  /// The segment's `surface` tool calls, in emission order. The walker
  /// preserves these so [VibeSegmentBubble] can render the A2UI surface
  /// inline below the boxes. Empty when the segment has no surfaces.
  final List<ToolCallData> surfaceToolCalls;

  /// The turn's abnormal stop, when the agent turn anchored here ended
  /// with a persisted `stream_error` row. Null on normal completion.
  final Message? stopError;

  const VibeSegment({
    required this.userMessage,
    this.think,
    this.tools,
    this.mods,
    this.progress,
    this.agents,
    this.prose,
    this.showUserMessage = true,
    this.modCalls = const [],
    this.surfaceToolCalls = const [],
    this.stopError,
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
  // The segment's write/edit calls, in order, for the files box's diff
  // action. Accumulated alongside modPaths and reset on each emit.
  final modCalls = <ToolCallData>[];
  // The segment's surface tool calls, preserved so the vibe bubble
  // can render A2UI surfaces inline.
  final surfaceToolCalls = <ToolCallData>[];
  // The segment's commander↔worker communication rows, parsed from
  // `agentBubble` meta on subagent tool results and from dedicated
  // role:'user' report rows. Kept SEPARATE from toolEntries so the
  // subagent orchestration calls don't pollute the tools box — they
  // render in the agents box instead.
  final agentRows = <AgentBubblePayload>[];
  // Merged progress summary for the progress box: at most one entry
  // per segment, folded from every bash run that reported signals.
  ProgressBoxData? progressAccum;
  Message? stopErrorAccum;
  // `true` once the current user turn has produced its first
  // emitted segment. The first segment carries the `you:` line;
  // siblings in the same turn render prose only. Reset on
  // user-boundary.
  bool userLineShown = false;

  // Tracks whether the most recent non-system message was a
  // `role: 'tool'` result row. Used to recognize an `ask` form
  // answer: the chat panel persists the user's picks as a bare
  // `role: 'user'` row inserted immediately after the `ask` tool's
  // result (mid-round), where a normal conversation never has a
  // user message. Such a row is an answer boundary, not a fresh
  // user turn.
  bool lastWasToolResult = false;

  for (final msg in messages) {
    // Skip system-role messages entirely.
    if (_systemRoles.contains(msg.role)) continue;

    if (msg.role == 'user') {
      // Worker→commander report row (persisted with `agentBubble` meta,
      // empty content). Not a user turn — fold into the running segment's
      // agents accumulator so the row lands in the CURRENT segment's
      // agents box, in order, without resetting any accumulator.
      //
      // When there is no current user anchor yet — the row is the session's
      // first non-system message (a wake that opens the log, e.g. a report
      // row left first after a compaction) — anchor the segment to this row
      // instead of leaving `currentUser` null. Otherwise the next
      // `role: 'ai'` reply closes nothing (`_emitSegment` returns early on a
      // null anchor) and the whole wake turn renders as an empty segment
      // list: the reply silently vanishes in vibe mode. The row itself
      // already renders in the agents box below, so its `You:` line is
      // suppressed — matching how a mid-turn report folds in without a user
      // turn of its own.
      if (msg.content.trim().isEmpty && parseAgentBubble(msg.meta) != null) {
        if (currentUser == null) {
          currentUser = msg;
          userLineShown = true;
        }
        agentRows.add(parseAgentBubble(msg.meta)!);
        lastWasToolResult = false;
        continue;
      }
      // Subagent report WAKE row: the envelope text persisted by sendTurn
      // to wake the model (`[Crux system note — subagent report]…`). The
      // report's visual already landed in the agents box via the dedicated
      // `agentBubble` row above, so this envelope is model-facing
      // instruction, not user prose — it must NOT render a `You:` line.
      // It still opens a fresh segment so the model's reply has an anchor;
      // `userLineShown = true` suppresses the line itself. Without this the
      // raw envelope (from:/intention:/status:/report:) leaked into the
      // vibe-mode chat as if the user had typed it.
      if (msg.content.trimLeft().startsWith(
        '[Crux system note — subagent report]',
      )) {
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
          modCalls,
          surfaceToolCalls,
          agentRows,
          progressAccum,
          stopErrorAccum,
          null,
          showUserLine: !userLineShown,
        );
        currentUser = msg;
        userLineShown = true; // anchor set, but the envelope text is hidden
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
        modCalls.clear();
        surfaceToolCalls.clear();
        agentRows.clear();
        progressAccum = null;
        stopErrorAccum = null;
        lastWasToolResult = false;
        continue;
      }
      // Ask-answer boundary: a `role: 'user'` row that lands right
      // after a tool result is the submitted `ask` form, not a new
      // turn. Flush the in-flight segment (the ask call + its prose
      // close), then emit the answer as its OWN segment — no boxes,
      // no prose — so the AskAnswerBubble renders at the answer's
      // true position: after the preceding tool round, before the
      // continuation. The continuation keeps the same [currentUser]
      // anchor but suppresses its user line (the answer bubble
      // already showed who answered), so the follow-up tools/prose
      // render as a sibling segment below the answer.
      if (lastWasToolResult) {
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
          modCalls,
          surfaceToolCalls,
          agentRows,
          progressAccum,
          stopErrorAccum,
          null,
          showUserLine: !userLineShown,
        );
        // The standalone answer segment: anchored to the answer row,
        // carrying the user line (which chat_history swaps for the
        // AskAnswerBubble), nothing else.
        currentUser = msg;
        _emitSegment(
          segments,
          currentUser,
          Duration.zero,
          0,
          null,
          const {},
          const [],
          0,
          const [],
          const {},
          const {},
          const [],
          const [],
          const [],
          null,
          null,
          null,
          showUserLine: true,
        );
        // Continuation below the answer reuses this user anchor but
        // hides its `you:` line — the answer bubble already stands
        // in for it.
        userLineShown = true;
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
        modCalls.clear();
        surfaceToolCalls.clear();
        agentRows.clear();
        progressAccum = null;
        stopErrorAccum = null;
        lastWasToolResult = false;
        continue;
      }

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
        modCalls,
        surfaceToolCalls,
        agentRows,
        progressAccum,
        stopErrorAccum,
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
      modCalls.clear();
      surfaceToolCalls.clear();
      agentRows.clear();
      progressAccum = null;
      stopErrorAccum = null;
      lastWasToolResult = false;
      continue;
    }

    if (msg.role == 'tool') {
      // Tool result row: paired with its `tool_call` inside the
      // accumulation above (via resultsByCallId), so no segment work
      // here — just record the boundary for ask-answer detection.
      lastWasToolResult = true;
      continue;
    }

    if (msg.role == 'stream_error') {
      // Attach errors that arrive after an already-emitted final prose row
      // to that row; otherwise carry them into the next emitted segment.
      final last = segments.isNotEmpty ? segments.last : null;
      if (currentUser != null &&
          last != null &&
          identical(last.userMessage, currentUser) &&
          last.prose != null &&
          last.stopError == null) {
        segments[segments.length - 1] = _withStopError(last, msg);
      } else {
        stopErrorAccum = msg;
      }
      continue;
    }

    if (msg.role == 'ai' || msg.role == 'tool_call') {
      lastWasToolResult = false;
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
          // Subagent orchestration calls bypass the tools box — they
          // render as commander↔worker rows in the agents box instead
          // (the tool result's `agentBubble` meta carries the payload).
          // v2 tool set (find/hire/send/check/cancel); the v1 names
          // stay matched so pre-migration sessions still fold right.
          final isSubagentTool =
              tc.name == 'find_agents' ||
              tc.name == 'hire_agent' ||
              tc.name == 'send_agent' ||
              tc.name == 'check_agent' ||
              tc.name == 'cancel_agent' ||
              // v1 legacy names (pre-v2 sessions replayed from history).
              tc.name == 'send_worker' ||
              tc.name == 'spawn_worker' ||
              tc.name == 'assign_worker' ||
              tc.name == 'fork_worker' ||
              tc.name == 'cancel_assignment' ||
              tc.name == 'read_worker';
          if (isSubagentTool) {
            final agentBubble = parseAgentBubble(resultMsg?.meta);
            if (agentBubble != null) agentRows.add(agentBubble);
            continue;
          }
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
          // Only write/edit consult a language server, and only when
          // the result actually persisted an `lsp` field. Both gates
          // must hold for a real state: a non-LSP tool (read/bash/grep)
          // or a guard-aborted edit (no lspStatus persisted) is
          // LspState.disabled — no glyph. Worst-state-wins across the
          // entry's calls: a red row flags that at least one write/edit
          // in the segment left diagnostics, even if others were clean.
          final isLspTool = tc.name == 'write' || tc.name == 'edit';
          final meta = resultMsg?.meta;
          final callState = (isLspTool && hasLspState(meta))
              ? parseLspState(meta)
              : LspState.disabled;
          final mergedState =
              lspStateSeverity(callState) >
                  lspStateSeverity(prev?.lspState ?? LspState.disabled)
              ? callState
              : (prev?.lspState ?? LspState.disabled);
          toolEntries[tc.name] = ToolBoxEntry(
            name: tc.name,
            callCount: (prev?.callCount ?? 0) + 1,
            totalTokens: (prev?.totalTokens ?? 0) + callTokens,
            lspState: mergedState,
          );
          toolTotalTokens += callTokens;

          // Accumulate progress-box data from the tool result's
          // persisted `shellProgress` metadata — only bash runs that
          // reported progress signals carry it (see
          // `shell_progress_parser.dart`). Multiple runs in one
          // segment fold into a single summary via mergeProgress.
          final progressMeta = resultMsg?.meta;
          if (progressMeta != null && progressMeta.isNotEmpty) {
            final pb = progressFromMeta(progressMeta);
            if (pb != null) {
              progressAccum = progressAccum == null
                  ? pb
                  : mergeProgress(progressAccum, pb);
            }
          }

          // Preserve surface tool calls for inline rendering — but
          // only SUCCESSFUL ones. A failed `surface` call (bad payload,
          // missing surfaceId, validation errors) renders as a red
          // "invalid declaration" SurfaceBubble below the boxes, which
          // duplicates the error the tool-result row already shows and
          // sits as an ugly red block next to the retried success.
          // Failure signal: the persisted tool-result row's `error`
          // column (the walker's local ToolResult carries a synthetic
          // empty title, so the `title == 'Error'` convention used in
          // chat_turn_executor is not available here).
          if (tc.name == 'surface') {
            final failed =
                resultMsg == null || (resultMsg.error ?? '').isNotEmpty;
            if (!failed) surfaceToolCalls.add(tc);
          }

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
              // Record the mutating call for the files box's diff
              // action. Only calls that actually produced a mod summary
              // (a real write/edit mutation, not a guard-aborted or
              // errored one) carry reconstructable old/new content.
              if (tc.name == 'write' || tc.name == 'edit') {
                modCalls.add(tc);
              }
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
          modCalls,
          surfaceToolCalls,
          agentRows,
          progressAccum,
          stopErrorAccum,
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
        modCalls.clear();
        surfaceToolCalls.clear();
        agentRows.clear();
        progressAccum = null;
        stopErrorAccum = null;
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
    modCalls,
    surfaceToolCalls,
    agentRows,
    progressAccum,
    stopErrorAccum,
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
/// [progress] is the segment's merged progress summary (bash runs
/// that reported signals); null when none did.
///
/// [stopError] is the turn's abnormal stop, when one occurred.
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
  List<ToolCallData> modCalls,
  List<ToolCallData> surfaceToolCalls,
  List<AgentBubblePayload> agentRows,
  ProgressBoxData? progress,
  Message? stopError,
  Message? closing, {
  required bool showUserLine,
}) {
  if (currentUser == null) return;

  final entries = toolOrder.map((name) => toolEntries[name]!).toList();
  final hasThink = thinkDuration.inMilliseconds > 0 || thinkTokens > 0;
  final hasBoxes =
      hasThink ||
      entries.isNotEmpty ||
      modPaths.isNotEmpty ||
      agentRows.isNotEmpty ||
      progress != null;
  final hasProse = closing != null;

  // Skip when the flush has nothing to show: no boxes, no
  // closing message. Pending-only emission (user just typed,
  // no agent output yet) lands here too when currentUser is
  // set but accumulators are empty and there's no closing —
  // we want to emit that case (showUserLine=true makes it
  // carry the user line), so the guard is gated on showUserLine.
  if (!hasBoxes && !hasProse && !showUserLine && stopError == null) return;

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
              // Per-file entries, same order/cap as `paths`, keyed by
              // basename for the diff counts. The files box renders each
              // row's own `+N -M` from these, and the diff fullpane uses
              // them to seed the selected file's header.
              files: modPaths
                  .take(8)
                  .map(
                    (path) => ModFileEntry(
                      path,
                      modLinesAdded[p.basename(path)] ?? 0,
                      modLinesRemoved[p.basename(path)] ?? 0,
                    ),
                  )
                  .toList(),
            )
          : null,
      prose: closing,
      progress: progress,
      agents: agentRows.isEmpty
          ? null
          : AgentsBoxData(
              entries: agentRows.take(6).toList(),
              overflowCount: agentRows.length > 6 ? agentRows.length - 6 : 0,
            ),
      modCalls: List.unmodifiable(modCalls),
      surfaceToolCalls: List.unmodifiable(surfaceToolCalls),
      stopError: stopError,
    ),
  );
}

/// Return a copy of [seg] with [stopError] attached.
VibeSegment _withStopError(VibeSegment seg, Message stopError) {
  return VibeSegment(
    userMessage: seg.userMessage,
    showUserMessage: seg.showUserMessage,
    think: seg.think,
    tools: seg.tools,
    mods: seg.mods,
    progress: seg.progress,
    agents: seg.agents,
    prose: seg.prose,
    modCalls: seg.modCalls,
    surfaceToolCalls: seg.surfaceToolCalls,
    stopError: stopError,
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
