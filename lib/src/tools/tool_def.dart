import 'dart:convert';

import 'package:path/path.dart' as p;

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
/// can render the pre-compression / post-compression token
/// comparison when the tool_call's large args were off-loaded.
///
/// The split between [argsTokens] and [totalTokens] exists
/// because the *strikethrough* number must be apples-to-apples
/// with the *post-compression* number. The result of the tool
/// is unknown at compression time (it runs *after* the args are
/// off-loaded), so the pre-compression number is args-only —
/// "this is what the args would have cost if we hadn't
/// off-loaded them." The post-compression number shown next to
/// the "compressed:" prefix is also args-only, so the
/// comparison is honest: bigger strikethrough = bigger saving.
///
/// [totalTokens] is the full round-trip cost (args + result)
/// and is what an uncompressed tool_call displays as its
/// single `~Nt` value. When the call was compressed, the
/// bubble shows `~~{pre}t~~, compressed: ~{post}t` — the
/// strikethrough is the args saving, and the result is
/// shown separately by including [totalTokens] in the line
/// if it differs materially from [argsTokens].
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
}

String _capitalize(String s) {
  if (s.isEmpty) return s;
  return s[0].toUpperCase() + s.substring(1);
}

/// Minimum byte size (utf-8) before a LargePayloadTool's argument
/// is off-loaded to the `offloaded_content` table and replaced in
/// the conversation log with a stand-in pointer. 2 KB is a
/// reasonable default: small enough to skip trivial content,
/// large enough to catch the common case (a typical source-file
/// edit is well over 2 KB).
const int offloadThresholdBytes = 2048;

/// Marker interface: tool has arguments whose values may be too large
/// to carry in the conversation log. Implementations declare which
/// top-level argument keys are eligible for offload; the chat
/// service does the actual compression at the persist boundary.
///
/// Note: this is an `extends` relationship on purpose, not
/// `implements`. The class provides a default implementation of
/// [argsToOffload] that concrete tools inherit; if a tool
/// `implements LargePayloadTool`, the concrete method is NOT
/// inherited (Dart's `implements` only carries the interface)
/// and the tool would have to re-implement it.
///
/// Order is significant: callers that walk [offloadableArgs] should
/// do so in declaration order so the persisted JSON has deterministic
/// key ordering (cache stability).
abstract class LargePayloadTool extends ToolDef {
  List<String> get offloadableArgs;

  /// Returns the subset of [offloadableArgs] whose string values in
  /// [args] are large enough to be off-loaded by the chat service
  /// (i.e. utf-8 byte length ≥ [offloadThresholdBytes]). Tools use
  /// this to report the offload to the LLM in the result message.
  /// The chat service runs the same logic to decide what to
  /// compress; this is just a self-prediction so the tool can be
  /// informative before the persist boundary.
  List<String> argsToOffload(Map<String, dynamic> args) {
    final result = <String>[];
    for (final key in offloadableArgs) {
      final value = args[key];
      if (value is! String) continue;
      if (utf8.encode(value).length >= offloadThresholdBytes) {
        result.add(key);
      }
    }
    return result;
  }
}

/// Build the human-readable note the tool appends to its result
/// output when one or more of its arguments are off-loaded by the
/// chat service. The note tells the LLM (a) which arguments were
/// moved, (b) the composite key(s) under offloaded_content where
/// the original bytes live, (c) that a stand-in pointer will
/// substitute for the argument on subsequent turns, and (d) the
/// intent of the call so the LLM can reason about the offloaded
/// content without recalling it.
///
/// Tools call this from `execute` when [LargePayloadTool.argsToOffload]
/// returns a non-empty list, so the agent sees a single
/// authoritative message in the current turn rather than having
/// to infer the offload on the next turn from the stand-in
/// pointer in the persisted history.
String buildOffloadNote({
  required String callId,
  required List<String> offloadedArgs,
  String? intent,
}) {
  if (offloadedArgs.isEmpty) return '';
  final keys = offloadedArgs
      .map((k) => '`${callId}_$k`')
      .join(', ');
  final argList = _formatArgList(offloadedArgs);
  final were = offloadedArgs.length == 1 ? 'was' : 'were';
  final pronoun = offloadedArgs.length == 1 ? 'it' : 'them';
  final intentFragment = intent != null && intent.isNotEmpty
      ? " (intent: '$intent')"
      : '';
  return 'The $argList argument(s)$intentFragment exceeded the offload threshold and $were '
      'moved to the `offloaded_content` table (composite key(s): $keys) to '
      'reduce token usage; a stand-in pointer will substitute for $pronoun '
      'on subsequent turns.';
}

String _formatArgList(List<String> args) {
  if (args.length == 1) return '`${args[0]}`';
  if (args.length == 2) return '`${args[0]}` and `${args[1]}`';
  final head = args.sublist(0, args.length - 1).map((a) => '`$a`').join(', ');
  return '$head, and `${args.last}`';
}

/// Mixin for tools whose schema includes an `intent` parameter.
/// The UI uses this to display the intent (what the tool call is for)
/// instead of the file path in the collapsed tool-call bubble, giving
/// the user a more meaningful summary at a glance.
///
/// Implemented as a mixin (rather than an abstract class with
/// `implements ToolDef`) so it can be mixed into tools that already
/// extend another class (e.g. `WriteTool extends LargePayloadTool`).
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

  const GuardResult({required this.header, required this.content});
}
