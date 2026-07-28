import 'package:path/path.dart' as p;

import '../models/message.dart';
import '../models/session_runtime_state.dart';
import '../utils/tool_metrics_animator.dart';
import 'shell_monitor.dart';
import 'shell_risk.dart';

class AbortSignal {
  final int? sessionId;
  bool _aborted = false;

  bool get isAborted => _aborted;

  AbortSignal({this.sessionId});

  void abort() {
    _aborted = true;
  }
}

class ToolContext {
  final int sessionId;
  final int messageId;
  final AbortSignal abort;
  final String? callId;
  final String workingDirectory;

  /// Optional reference to the session's runtime state. Used by
  /// the shell tool to read/write the consecutive-shell-violations
  /// counter (see `lib/src/tools/shell_guard.dart` and
  /// [SessionRuntimeState.consecutiveShellViolations]).
  ///
  /// Optional so non-shell tools don't need to know about it; tools
  /// that don't care about shell-violation state can pass `null`
  /// (and tests / internal callers can omit it). The shell base
  /// (`lib/src/tools/shell_base.dart`) reads the current counter
  /// from this field when deciding the guard's severity tier and
  /// increments it on every detected violation; the chat service
  /// resets the counter to 0 when a proper-tool call succeeds.
  final SessionRuntimeState? sessionRuntime;

  /// Optional layer-2 evaluator for the shell high-risk guardrail
  /// (see `lib/src/tools/shell_risk.dart`). Injected by
  /// `chat_turn_executor.dart` when it builds the context for a real
  /// turn; wired to `AuxiliaryService.assessShellCommand`.
  ///
  /// Optional for the same reason as [sessionRuntime]: non-shell
  /// tools don't care, and tests / internal callers that synthesise
  /// their own ToolContext can omit it. The shell base
  /// (`lib/src/tools/shell_base.dart`) invokes this only for
  /// `suspicious` commands without `confirmed: true`; when it is
  /// null the guardrail fails open (runs the command with a warning
  /// appended) rather than blocking work it cannot get a second
  /// opinion on.
  final Future<ShellRiskVerdict> Function(
    String command, {
    required String intent,
    required bool isWindows,
    required AbortSignal abort,
  })? shellRiskEvaluator;

  /// Optional evaluator for the shell progress monitor (see
  /// `lib/src/tools/shell_monitor.dart`). Injected by
  /// `chat_turn_executor.dart` when an auxiliary model is
  /// configured; wired to `AuxiliaryService.assessShellProgress`.
  ///
  /// When this is non-null, the shell tools (bash / cmd /
  /// powershell) do NOT enforce the static `timeout` parameter —
  /// the monitor watches the running process and kills it only on a
  /// confident STUCK verdict. When null (no auxiliary model
  /// configured, or a test that synthesises its own [ToolContext]),
  /// the shell tools fall back to classic timeout behaviour.
  final ShellMonitorEvaluator? shellMonitorEvaluator;

  /// Optional sink for monitor events (one row per check, persisted
  /// to `shell_monitor_logs`). Injected alongside
  /// [shellMonitorEvaluator] by the chat executor; a null sink
  /// disables logging entirely (the monitor loop's default, so tests
  /// and non-persisted setups need no changes). The shell base emits
  /// events only when both this AND [shellMonitorEvaluator] are
  /// non-null — logging without a live monitor would be empty.
  final ShellMonitorLogSink? shellMonitorLogSink;

  ToolContext({
    required this.sessionId,
    required this.messageId,
    required this.abort,
    this.callId,
    required this.workingDirectory,
    this.sessionRuntime,
    this.shellRiskEvaluator,
    this.shellMonitorEvaluator,
    this.shellMonitorLogSink,
  });
}

class ToolResult {
  final String title;
  final String output;
  final bool truncated;
  final String? outputPath;
  final Map<String, dynamic> metadata;

  const ToolResult({
    required this.title,
    required this.output,
    this.truncated = false,
    this.outputPath,
    this.metadata = const {},
  });

  static ToolResult error(String message) {
    return ToolResult(title: 'Error', output: message);
  }
}

String resolvePath(String filePath, String workingDirectory) {
  if (p.isAbsolute(filePath)) return p.normalize(filePath);
  return p.normalize(p.join(workingDirectory, filePath));
}

String relativePath(String absolutePath, String workingDirectory) {
  if (p.equals(absolutePath, workingDirectory)) return '.';
  final rel = p.relative(absolutePath, from: workingDirectory);
  if (rel.startsWith('..') || p.isAbsolute(rel)) return absolutePath;
  return rel;
}

/// Structured result of [ToolDef.collapsedSummary] so the bubble
/// can render a tool-specific one-line description with token counts.
class CollapsedSummary {
  final String text;
  final int argsTokens;
  final int totalTokens;

  const CollapsedSummary({
    required this.text,
    required this.argsTokens,
    required this.totalTokens,
  });
}

/// Maximum size (in Dart `String.length` units) of a file's content
/// inlined into the chat log under `read files:`. Files larger than
/// this are truncated with a hint to re-read. Kept small because:
///
///   * the LLM context grows linearly with the chat log size, so
///     huge inline files eat the win compaction just bought;
///   * the debug fullpane renders the entire chat log on a single
///     `RichText`, so multi-MB inlines cause multi-second freezes
///     on open;
///   * the LLM can always call `read` with `offset`/`limit` to
///     re-fetch the rest, so we don't lose information.
const int kInlineReadMaxChars = 100 * 1024;

/// Same idea for fetched pages. Pages already come through the
/// web provider's cleaner (title + body), so 50KB is enough for
/// the LLM to recognize the page; the URL is preserved so the
/// agent can re-fetch if it needs the full text.
const int kInlineFetchMaxChars = 50 * 1024;

/// Same idea for semantic_search / find_similar_code / websearch
/// results. These are snippet blocks, not full documents, so 20KB
/// is plenty — the top-K hits have already been trimmed by the
/// tool itself.
const int kInlineSearchMaxChars = 20 * 1024;

/// Total size cap for the `read files:` section that the chat
/// log appends at the bottom of a compaction. Each individual
/// `read` / `write` / `edit` call is already capped at
/// [kInlineReadMaxChars] = 100KB, but a session that touches
/// many files can still accumulate a multi-MB section — which
/// (a) makes the next compaction's projection show
/// `post > pre` (the section is folded into the new
/// compaction's chain content, growing the post-side beyond
/// the pre-side), and (b) the LLM rarely needs the FULL
/// current contents of every file; the path + mtime is
/// enough for the agent to re-read on demand. Cap the whole
/// section at 32KB (~8K tokens): a few small files fit whole,
/// one mid-size file gets a partial fit, the rest are listed
/// by path only.
const int kInlineSummarySectionMaxChars = 32 * 1024;

/// Truncate [content] to at most [maxChars] characters, appending
/// a marker that tells the reader (LLM or human) the original
/// size and (optionally) how to see the rest. Returns the input
/// unchanged when it fits — a no-op fast path so the chat log
/// builder doesn't pay a per-call cost for typical-sized entries.
String truncateForInline(
  String content,
  int maxChars, {
  String? hint,
}) {
  if (content.length <= maxChars) return content;
  final truncated = content.substring(0, maxChars);
  final total = content.length;
  final hintSuffix = hint != null && hint.isNotEmpty ? ' $hint' : '';
  return '$truncated\n\n... [truncated — full content is $total chars;$hintSuffix]';
}

/// A piece of content for the bottom-of-log summary section of a
/// chat log. Tools produce these via [ToolDef.extractPruneSummary];
/// the chat log builder accumulates them, deduplicates by
/// (category, key) using last-write-wins, and renders them at the
/// end of the log.
///
/// Three categories survive into the summary section:
///   * `'skill-bodies'` — skill content the agent loaded via the
///     `skill` tool. Sourced from the tool_result (the
///     `<skill_content>` block the model saw). Dedup by skill
///     name, rendered first under `loaded skills:` because the
///     resumed agent needs the procedure before anything else.
///   * `'read-files'` — content the agent READ at the time of
///     the call. Sourced from the read tool's `tool_result` (the
///     numbered file body the model actually saw), not from a
///     re-read of disk at compact time. The chat log preserves
///     the model's memory, not the current file state — if the
///     file changed externally between read and compact, showing
///     the current state would silently "correct" the model's
///     recollection without telling it.
///   * `'write-files'` — content the agent WROTE via the `write`
///     tool. Sourced from the input `content` argument (the
///     payload the model produced), so post-compact the resumed
///     agent has its own write preserved verbatim.
///
/// Everything else — `webfetch`, `websearch`, `semantic_search`,
/// `find_similar_code`, `edit`, `bash`, `grep`, `glob` — is
/// dropped from the bottom-of-log section. The chat log body
/// already records the call (path / query / intent), and the
/// model's reasoning during the original turn was based on the
/// inline result. Dumping the result again at the bottom would
/// double-count tokens without adding information; if the model
/// needs the result post-compact, it can re-call the tool. The
/// `skill`, `read` and `write` cases are exceptions because the
/// CONTENT is the durable artifact — the name / path / intent
/// alone wouldn't let the agent continue working with it.
class SummaryContribution {
  /// One of `'skill-bodies'`, `'read-files'`, `'write-files'`.
  final String category;

  /// Stable identity for dedup (last-write-wins within a category).
  /// The skill name or file path.
  final String key;

  /// Full body to render — file content.
  final String value;

  /// Reserved for future metadata. Currently unused by the chat
  /// log rendering (the section just shows `path\n<content>`),
  /// but kept on the type so callers can attach extra hints
  /// without an API change.
  final Map<String, dynamic>? meta;

  const SummaryContribution({
    required this.category,
    required this.key,
    required this.value,
    this.meta,
  });

  factory SummaryContribution.readFile({
    required String path,
    required String content,
  }) =>
      SummaryContribution(
        category: 'read-files',
        key: path,
        value: content,
      );

  factory SummaryContribution.writtenFile({
    required String path,
    required String content,
  }) =>
      SummaryContribution(
        category: 'write-files',
        key: path,
        value: content,
      );
}

abstract class ToolDef {
  String get name;
  String get description;
  Map<String, dynamic> get parametersSchema;

  Future<ToolResult> execute(Map<String, dynamic> args, ToolContext ctx);

  CollapsedSummary collapsedSummary(
    Map<String, dynamic> args,
    ToolResult result,
  ) {
    final lines = '\n'.allMatches(result.output).length + 1;
    final size = result.output.length;
    final sizeStr = size > 1024
        ? '${(size / 1024).toStringAsFixed(1)}KB'
        : '${size}B';
    return CollapsedSummary(
      text: '$lines lines, $sizeStr',
      argsTokens: 0,
      totalTokens: 0,
    );
  }

  /// Live preview label for an in-progress tool call. Called from
  /// the chat panel's streaming bubble as the LLM emits
  /// `tool_use` deltas, so the user sees the call materialize
  /// (tool name + growing argument budget) instead of waiting for
  /// the whole JSON to arrive.
  ///
  /// [accumulatedInputJson] is the raw, possibly-malformed partial
  /// JSON string the LLM has emitted so far (we can't `jsonDecode`
  /// it — the close braces haven't arrived yet). [estimatedInputTokens]
  /// is `estimateTokens(accumulatedInputJson)`; tools that want to
  /// show a richer preview (e.g. the key argument of `read` /
  /// `bash` / `edit`) can override and ignore the raw JSON.
  ///
  /// Default implementation: capitalized tool name + estimated
  /// input-token count, e.g. `Bash (~12 t)`.
  String streamingLabel({
    required String accumulatedInputJson,
    required int estimatedInputTokens,
  }) {
    return '${_capitalize(name)} (~$estimatedInputTokens t)';
  }

  /// `+added -removed` line delta for a completed call, used by
  /// the collapsed chat row + the tool detail pane to render
  /// the same `+M lines · -K lines` animation the streaming
  /// bubble shows while the LLM is still emitting input.
  ///
  /// The default is `null` — only `write` and `edit` have a
  /// meaningful add/remove diff in their input. Tools that
  /// return `null` (or that don't override) get a metric row
  /// with just `~N t` and no line count, matching the streaming
  /// bubble's behavior for non-line-bearing tools.
  ///
  /// The [args] map is the fully-parsed input the LLM emitted
  /// (or whatever the tool received and stored in
  /// `ToolCallData.input`); [result] is the final [ToolResult].
  ToolMetricsLineDelta? toolMetricsLineDelta(
    Map<String, dynamic> args,
    ToolResult result,
  ) {
    return null;
  }

  /// Structured per-call modification summary, used by vibe mode's
  /// `files` box. Default implementation returns `null` (no
  /// modifications reported). Tools that mutate files
  /// (`write_tool`, `edit_tool`) override this to report the file
  /// path + line deltas.
  ///
  /// The [args] map is the fully-parsed input the LLM emitted
  /// (or whatever the tool received and stored in
  /// `ToolCallData.input`); [result] is the final [ToolResult].
  ModSummary? modSummary(
    Map<String, dynamic> args,
    ToolResult result,
  ) {
    return null;
  }

  /// Whether this tool's results should be dropped entirely from
  /// chat logs. Override to `true` for discovery / introspection
  /// tools (`grep` / `glob` / `session`) whose success is implied
  /// by downstream reads and whose failures are rarely interesting.
  /// Default false.
  bool get skipInPrune => false;

  /// Render this tool call's line in the inline `tool calls:` block
  /// of the chat log. [pairedResult] is the matching `role: tool`
  /// message content (empty if no result was captured); [isError]
  /// is true when the result indicates failure — implementations
  /// should keep the error text in that case instead of synthesising
  /// a one-line summary.
  ///
  /// Default: `$name for {intent}` if an intent is present, else
  /// `$name`. Tools whose primary identifier is something other
  /// than `intent` (`read` uses filePath, `webfetch` uses url,
  /// `semantic_search` uses query, etc.) should override.
  String renderPruneInline({
    required ToolCallData call,
    required String pairedResult,
    required bool isError,
  }) {
    final intent = _intentOf(call);
    if (isError) {
      return intent.isNotEmpty
          ? '$name for {$intent} → $pairedResult'
          : '$name → $pairedResult';
    }
    if (intent.isNotEmpty) return '$name for {$intent}';
    return name;
  }

  /// Extract a contribution for the bottom-of-log summary section,
  /// or return null if this tool doesn't contribute. Override in
  /// tools whose content is worth preserving verbatim.
  ///
  /// `read` / `write` / `edit` use this to surface the current
  /// on-disk state of files the agent touched. For `read`, this
  /// re-reads the file because the original read result may be
  /// partial (offset/limit) or stale (post-edit). For `write` /
  /// `edit`, the input `content` / `oldString` / `newString` was
  /// dropped from the chat log, so re-reading the file restores the
  /// agent's memory of what it wrote / edited. Newly-created files
  /// (write to a path that didn't exist) are included too — they
  /// exist on disk by the time the chat log is built.
  ///
  /// `webfetch` / `websearch` / `semantic_search` /
  /// `find_similar_code` use this to surface full results.
  ///
  /// [workingDirectory] is the session's project root; tools that
  /// need to read files should resolve relative paths via
  /// [resolvePath] before reading.
  SummaryContribution? extractPruneSummary({
    required ToolCallData call,
    required String pairedResult,
    required bool isError,
    required String workingDirectory,
  }) =>
      null;

  /// Whether this call should be dropped from the chat log entirely
  /// because the tool did NOT actually do what the model asked for.
  ///
  /// The chat log builder drops a call when this returns `true`:
  /// the inline per-turn line is skipped, and [extractPruneSummary]
  /// is NOT called for the call (so the summary section won't pick
  /// up a stale "read" / "write" snapshot for a file the tool never
  /// touched). Tools that succeed in mutating / fetching always
  /// return `false` — the default.
  ///
  /// The original motivation is the `edit` and `write` guards. The
  /// model almost always follows a guarded / aborted call with a
  /// corrected retry in the same turn, so the failed attempt is
  /// pure noise in the post-compaction context: the agent doesn't
  /// need to know "this edit was BLOCKED" if a successful `edit`
  /// for the same file is right next to it in the log. Filtering
  /// the inline line keeps the activity log tight and stops the
  /// guard's full file body (the guard returns the current file
  /// content as a hint for the retry) from blowing up the chat log
  /// size.
  ///
  /// Auto-reads (edit's `[AUTOREAD]` response when the oldString
  /// didn't match) deliberately do NOT report no-op: the call DID
  /// teach the model the file content, and [extractPruneSummary]
  /// can route that into the `read files:` summary section. Only
  /// the guard / abort paths — where the model gained nothing
  /// useful and the retry is the durable signal — are filtered.
  ///
  /// [pairedResult] is the matching `role: tool` message content
  /// (empty if no result was captured). [isError] is true when the
  /// result indicates failure. Implementations should restrict the
  /// scan to a small leading window — file content that happens
  /// to contain the trigger substring would otherwise false-
  /// positive. See `_looksLikeError` in `chat_log_builder.dart`
  /// for the window-size rationale.
  bool isNoOpForCompaction({
    required String pairedResult,
    required bool isError,
  }) =>
      false;
}

String _capitalize(String s) {
  if (s.isEmpty) return s;
  return s[0].toUpperCase() + s.substring(1);
}

/// Structured per-call modification summary for vibe mode's `files`
/// box. Returned by [ToolDef.modSummary] on tools that mutate files
/// (`write_tool`, `edit_tool`).
class ModSummary {
  final List<ModFileChange> changes;

  const ModSummary({required this.changes});
}

/// One file's line delta within a [ModSummary]. [path] is the
/// display path (relative when possible), [linesAdded] /
/// [linesRemoved] are the diff counts for that file in this call.
class ModFileChange {
  final String path;
  final int linesAdded;
  final int linesRemoved;

  const ModFileChange(this.path, this.linesAdded, this.linesRemoved);
}

String _intentOf(ToolCallData c) {
  final i = c.input['intent'];
  return i is String ? i : '';
}

/// Mixin for tools whose schema includes an `intent` parameter.
/// The UI uses this to display the intent (what the tool call is for)
/// instead of the file path in the collapsed tool-call bubble, giving
/// the user a more meaningful summary at a glance.
///
/// Implemented as a mixin (rather than an abstract class with
/// `implements ToolDef`) so it can be mixed into tools that already
/// extend another class (e.g. `WriteTool extends ToolDef`).
mixin IntentionalTool implements ToolDef {
  /// Extract the intent string from the tool's input arguments.
  /// Returns null if no intent was provided.
  String? intentFromArgs(Map<String, dynamic> args) {
    final value = args['intent'];
    return value is String && value.isNotEmpty ? value : null;
  }
}

class GuardResult {
  final String header;

  /// Full current contents of the file the agent was about to
  /// overwrite. Surfaced to the LLM via [ToolResult.output] so it
  /// can re-read the file (or diff against its own plan) before
  /// deciding whether to proceed with the write.
  final String content;

  /// Machine-readable guard reason used by streaming-time aborts
  /// and UI labels.
  final String? reason;

  const GuardResult({required this.header, required this.content, this.reason});
}
