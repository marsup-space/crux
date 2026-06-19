import 'package:path/path.dart' as p;
import '../utils/tool_metrics_animator.dart';

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

  ToolContext({
    required this.sessionId,
    required this.messageId,
    required this.abort,
    this.callId,
    required this.workingDirectory,
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
}

String _capitalize(String s) {
  if (s.isEmpty) return s;
  return s[0].toUpperCase() + s.substring(1);
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
