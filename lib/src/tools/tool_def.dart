import 'package:path/path.dart' as p;

class AbortSignal {
  bool _aborted = false;

  bool get isAborted => _aborted;

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
/// can render the pre-compression / post-compression token
/// comparison when the tool_call's large args were off-loaded.
///
/// The [text] is the human-readable line (e.g. "1 replacement,
/// 41→87 lines"). It does NOT include the token count — the
/// bubble appends `~Nt` so it can compare pre vs post when
/// compression happened.
///
/// [tokens] is the round-trip cost as it appears in the
/// conversation log NOW (i.e. post-compression if the call was
/// compressed). For a `read` or `bash` call (no compression),
/// this is the only meaningful value; for a compressed `write`
/// or `edit`, the bubble will show it next to a strikethrough
/// pre-compression value pulled from the message metadata.
class CollapsedSummary {
  final String text;
  final int tokens;

  const CollapsedSummary({required this.text, required this.tokens});
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
      tokens: 0,
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
}

String _capitalize(String s) {
  if (s.isEmpty) return s;
  return s[0].toUpperCase() + s.substring(1);
}

/// Marker interface: tool has arguments whose values may be too large
/// to carry in the conversation log. Implementations declare which
/// top-level argument keys are eligible for offload; the chat
/// service does the actual compression at the persist boundary.
///
/// Order is significant: callers that walk [offloadableArgs] should
/// do so in declaration order so the persisted JSON has deterministic
/// key ordering (cache stability).
abstract class LargePayloadTool implements ToolDef {
  List<String> get offloadableArgs;
}

class GuardResult {
  final String header;

  /// Full current contents of the file the agent was about to
  /// overwrite. Surfaced to the LLM via [ToolResult.output] so it
  /// can re-read the file (or diff against its own plan) before
  /// deciding whether to proceed with the write.
  final String content;

  const GuardResult({required this.header, required this.content});
}
