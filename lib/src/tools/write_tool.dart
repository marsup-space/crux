import 'dart:convert';
import 'dart:io';

import '../lsp/manager.dart' show LspManager;
import '../lsp/protocol.dart' show LspDiagnostic;
import '../utils/file_metadata.dart';
import '../utils/token_estimate.dart' show estimateToolRoundTripTokens;
import 'file_lock.dart';
import 'file_read_tracker.dart';
import 'tool_def.dart';
import '../utils/tool_metrics_animator.dart';

/// `write` intentionally does NOT extend [LargePayloadTool]: its
/// `content` argument is the payload the LLM just produced and
/// wants to keep referencing on subsequent turns (especially for
/// new files, where the LLM has no other anchor for what it
/// wrote). Compressing the content to a stand-in pointer forces a
/// redundant `read` turn to recover it. Edit-tool-sized changes
/// are done via `edit`, so `write` calls are by definition
/// substantial enough that the cost of keeping the content in
/// context is justified. See session discussion: the offload
/// "small write" escape hatch doesn't exist in practice.
class WriteTool extends ToolDef with IntentionalTool {
  @override
  String get name => 'write';

  @override
  CollapsedSummary collapsedSummary(
    Map<String, dynamic> args,
    ToolResult result,
  ) {
    final content = args['content'] as String? ?? '';
    // The prior line count used to be stashed on the input args
    // map by execute() (as `_existingLineCount`) so the summary
    // could show the `+added -removed` diff. Same side-channel
    // problem as EditTool's `_replaceCount`: the args map is the
    // LLM-controlled input and gets round-tripped back to the
    // model in conversation history, where it can be echoed in a
    // shape that breaks the consumer.
    //
    // Parse the diff straight out of the success message
    // (`"+N lines"` for new files, `"+N -M lines"` for existing
    // files) — both shapes are emitted by [_doWrite] below and
    // never user-controlled. When parsing fails (error output,
    // auto-read, future format change) we fall back to 0
    // existing lines, which renders as a new-file `+N lines`
    // — same as before.
    final existingLineCount = _existingLineCountFromOutput(result.output);
    final newLines = content.isEmpty ? 0 : '\n'.allMatches(content).length + 1;
    final size = content.length;
    final sizeStr = size > 1024
        ? '${(size / 1024).toStringAsFixed(1)}KB'
        : '${size}B';
    // Total cost = args (always full content — never offloaded)
    // + the tool's result.
    final totalTokens = estimateToolRoundTripTokens(
      toolName: name,
      args: args,
      resultOutput: content,
    );
    // Args-only cost is what the strikethrough compares against.
    // For `write` there is no compression, so args-only == total
    // and the strikethrough display is suppressed at the call
    // site (preCompressTokens is never accumulated for `write`).
    // We still compute it here for the bubble's own display.
    final argsTokens = estimateToolRoundTripTokens(
      toolName: name,
      args: args,
      resultOutput: '',
    );
    // For a brand-new file (existingLineCount == 0) there is
    // nothing "removed" to report, so we drop the -N part and
    // show only the `+N lines` half. The `git diff --stat`
    // convention does the same: a new file shows as
    // `+N, -0`, not as `+N -0` — omitting the zero keeps the
    // common case uncluttered.
    final text = existingLineCount == 0
        ? '+$newLines lines, $sizeStr'
        : '+$newLines -$existingLineCount lines, $sizeStr';
    return CollapsedSummary(
      text: text,
      argsTokens: argsTokens,
      totalTokens: totalTokens,
    );
  }

  @override
  ToolMetricsLineDelta? toolMetricsLineDelta(
    Map<String, dynamic> args,
    ToolResult result,
  ) {
    // The collapsed row + the tool detail pane render the same
    // `+M -N lines` shape the streaming bubble shows while the
    // LLM is still emitting input. Mirror the logic in
    // [collapsedSummary] above so the post-call animation lands
    // on the same final values: for a brand-new file the prior
    // line count is 0, so we only render the `+N` half (matching
    // the `git diff --stat` convention). The streaming bubble
    // also has access to only the new `content` (it can't see
    // the prior file state), so the two paths agree naturally.
    final content = args['content'] as String? ?? '';
    final existingLineCount = _existingLineCountFromOutput(result.output);
    final newLines = content.isEmpty ? 0 : '\n'.allMatches(content).length + 1;
    return ToolMetricsLineDelta(
      addedLines: newLines,
      removedLines: existingLineCount == 0 ? null : existingLineCount,
    );
  }

  /// Extract the prior line count from a WriteTool success
  /// message. Matches the two shapes [_doWrite] emits:
  ///   - new file:        `"... +4 lines, ..."`
  ///   - existing file:   `"... +4 -6 lines, ..."`
  /// Returns 0 when no `-M` half is present (treats it as a
  /// brand-new file) and 0 when nothing matches at all — same
  /// behavior as the previous args-stash default.
  static final RegExp _lineDiffPattern = RegExp(r'\+\d+(?:\s*-(\d+))?\s*lines');

  static int _existingLineCountFromOutput(String output) {
    final match = _lineDiffPattern.firstMatch(output);
    if (match == null) return 0;
    // group(1) is the `-M` capture; absent on the new-file
    // shape, in which case we want 0.
    return int.tryParse(match.group(1) ?? '') ?? 0;
  }

  @override
  String get description =>
      'Overwrites a file with new content. The full content stays in '
      'the conversation context for subsequent turns so '
      'the LLM can reference what it just wrote without re-reading. '
      'CALL MULTIPLE IN PARALLEL — issue as many write calls in one '
      'turn as you need. Writes to DIFFERENT files run in parallel; '
      'writes to the SAME file are serialized internally so all of '
      'them apply in emission order (last write wins, in order). '
      'Mixing write with read and grep in the same turn is also '
      'encouraged when the calls are independent.';

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'properties': {
      'filePath': {'type': 'string', 'description': 'Path to file'},
      'content': {'type': 'string', 'description': 'Content to write'},
      'intent': {
        'type': 'string',
        'description':
            'What this file is for / why you are writing it. Be concise.',
      },
      'force': {
        'type': 'boolean',
        'description':
            'Set to true to bypass the size-mismatch guard. Required '
            'when overwriting a large file with a small payload (e.g. '
            'a legitimate "rewrite whole file" use case). Without this '
            'flag, writes that would dramatically shrink an existing '
            'file are refused with a suggestion to use `edit` instead.',
        'default': false,
      },
    },
    'required': ['filePath', 'content', 'intent'],
  };

  final FileReadTracker? tracker;
  final LspManager? lsp;

  WriteTool({this.tracker, this.lsp});

  Future<GuardResult?> checkStreamingGuard({
    required String filePath,
    required String workingDirectory,
  }) async {
    final t = tracker;
    if (t == null) return null;
    final resolved = resolvePath(filePath, workingDirectory);
    return t.checkWriteGuard(resolved);
  }

  @override
  Future<ToolResult> execute(Map<String, dynamic> args, ToolContext ctx) async {
    final filePath = args['filePath'] as String?;
    final content = args['content'] as String?;
    final force = args['force'] == true;

    if (filePath == null || filePath.isEmpty) {
      return ToolResult.error('Missing required parameter: filePath');
    }
    if (content == null) {
      return ToolResult.error('Missing required parameter: content');
    }

    final resolved = resolvePath(filePath, ctx.workingDirectory);

    // Critical section: any file mutation must be serialized per-file
    // so concurrent writes (and write/edit crosses) don't lose data
    // or corrupt the file. See file_lock.dart and
    // write_parallel_safety_test.dart. The lock is per-path so
    // writes to different files still run in parallel.
    return fileLock(resolved).run(
      () => _doWrite(
        args: args,
        ctx: ctx,
        resolved: resolved,
        content: content,
        force: force,
      ),
    );
  }

  /// Body of [execute] that actually touches the file. Runs under
  /// the per-file lock acquired by [execute]; see file_lock.dart.
  Future<ToolResult> _doWrite({
    required Map<String, dynamic> args,
    required ToolContext ctx,
    required String resolved,
    required String content,
    required bool force,
  }) async {
    if (ctx.abort.isAborted) {
      return ToolResult.error('Tool aborted');
    }
    final file = File(resolved);

    if (tracker != null && file.existsSync()) {
      final guard = await tracker!.checkWriteGuard(resolved);
      if (guard != null) {
        return ToolResult(
          title: 'Write file: $resolved',
          output: '${guard.header}\n\n${guard.content}',
          metadata: {'guardTriggered': true, 'guardKind': 'read_before_write'},
        );
      }
    }

    // Size-mismatch guard. Refuses to silently truncate a large
    // existing file when the new payload is dramatically smaller
    // (e.g. session 1208: a 19-char payload clobbered a 16.9KB /
    // 463-line file). The LLM was almost certainly trying to do
    // an `edit` and accidentally used `write` instead. We bail
    // out with a clear error pointing it at `edit`, and provide
    // a `force` parameter for the legitimate "rewrite the whole
    // file" case.
    if (file.existsSync() && !force) {
      final mismatch = _checkSizeMismatch(file, content);
      if (mismatch != null) {
        return ToolResult(
          title: 'Write file: $resolved',
          output: mismatch,
          metadata: {'guardTriggered': true, 'guardKind': 'size_mismatch'},
        );
      }
    }

    final parentDir = Directory(file.parent.path);
    if (!parentDir.existsSync()) {
      parentDir.createSync(recursive: true);
    }

    FileReadResult meta;
    if (file.existsSync()) {
      meta = readFileWithMetadata(file.readAsBytesSync());
    } else {
      meta = const FileReadResult(
        content: '',
        encoding: 'utf-8',
        lineEnding: 'lf',
        byteLength: 0,
      );
    }
    // Capture the prior line count for the success message
    // (which embeds the actual `+added -removed` diff in the
    // output text). The bubble's collapsedSummary then parses
    // that diff back out of the result — no need to stash it
    // on the LLM-controlled args map (see CollapsedSummary
    // comment for the rationale).
    final existingLineCount = meta.content.isEmpty
        ? 0
        : '\n'.allMatches(meta.content).length + 1;
    final newLines = content.isEmpty ? 0 : '\n'.allMatches(content).length + 1;
    // Respect the target line ending from .gitattributes. If
    // the file is declared binary, `targetLineEnding` is null
    // and we write the content byte-for-byte (no normalization
    // — the agent would have to ask for a write that re-encodes
    // a binary file, which we should refuse on principle, but
    // for now we just don't break it).
    final targetLineEnding = targetLineEndingFor(resolved, meta.lineEnding);
    final body = targetLineEnding == null
        ? content
        : normalizeToLineEnding(content, targetLineEnding);
    final encoded = utf8.encode(body);
    if (meta.encoding == 'utf-8-bom') {
      await file.writeAsBytes(<int>[0xEF, 0xBB, 0xBF, ...encoded]);
    } else {
      await file.writeAsBytes(encoded);
    }

    if (tracker != null) {
      await tracker!.recordRead(resolved, await _mtimeMs(file));
    }

    final relPath = relativePath(resolved, ctx.workingDirectory);
    final diffLabel = existingLineCount == 0
        ? '+$newLines lines'
        : '+$newLines -$existingLineCount lines';
    var output = 'File written: $relPath';
    final intent = args['intent'];
    if (intent is String && intent.isNotEmpty) {
      output =
          '$output (intent: \'$intent\'), $diffLabel, ${_formatBytes(content.length)}';
    } else {
      output = '$output, $diffLabel, ${_formatBytes(content.length)}';
    }

    final lspResult = await _collectLspDiagnostics(resolved, output, ctx);

    return ToolResult(
      title: 'Write file: $resolved',
      output: lspResult.output,
      metadata: {'lsp': lspResult.diagnostics},
    );
  }

  /// Collect LSP diagnostics for [filePath]. Returns the (possibly-
  /// modified) output text and the raw diagnostic list. The list is
  /// exposed in [ToolResult.metadata] under the `lsp` key so
  /// [collapsedSummary] can show the count in the hint bubble.
  ///
  /// The output text gets a brief one-liner (no verbose block); the
  /// count goes in the hint bubble instead.
  ///
  /// Best-effort: any failure returns ([baseOutput], const []). The
  /// tool must never fail because of LSP.
  Future<({String output, List<LspDiagnostic> diagnostics})>
  _collectLspDiagnostics(
    String filePath,
    String baseOutput,
    ToolContext ctx,
  ) async {
    final mgr = lsp;
    if (mgr == null) {
      return (output: baseOutput, diagnostics: const <LspDiagnostic>[]);
    }
    try {
      if (ctx.abort.isAborted) {
        return (output: baseOutput, diagnostics: const <LspDiagnostic>[]);
      }
      final diagnostics = await mgr.touchFileAndWait(
        filePath,
        isCancelled: () => ctx.abort.isAborted,
      );
      if (diagnostics.isEmpty) {
        return (output: baseOutput, diagnostics: const <LspDiagnostic>[]);
      }
      // Output text stays clean; the count is surfaced via the
      // [LspDiagnosticsBubble] in the chat history, not appended
      // to the tool's textual output.
      return (output: baseOutput, diagnostics: diagnostics);
    } catch (_) {
      return (output: baseOutput, diagnostics: const <LspDiagnostic>[]);
    }
  }

  /// (Deprecated) The LSP count hint is now surfaced via
  /// [LspDiagnosticsBubble] in the chat history instead of being
  /// appended to the collapsed summary. Kept for backwards-compat
  /// with the test fixture; safe to delete in a follow-up.
  // ignore: unused_element
  static String _appendLspHint(String text, Map<String, dynamic> metadata) {
    return text;
  }

  Future<int> _mtimeMs(File file) async {
    final stat = await file.stat();
    return stat.modified.millisecondsSinceEpoch;
  }

  /// Returns a non-null error message when [file]'s existing
  /// content looks dramatically larger than [newContent], which
  /// is a strong signal the caller meant to use `edit` but used
  /// `write` by mistake (full-file rewrite, no merge). Returns
  /// null when the new content is a reasonable replacement.
  ///
  /// The thresholds are deliberately loose so a legitimate "few
  /// percent smaller / larger" rewrite is not refused:
  ///   - existing file must be at least [kLargeLineThreshold]
  ///     lines OR [kLargeByteThreshold] bytes (one of the two is
  ///     enough — a 200-line file that's all on one line is
  ///     still a "real" file)
  ///   - new content must be at most [kTinyFraction] of the
  ///     existing byte size AND at most [kTinyLineFraction] of
  ///     the existing line count
  ///
  /// "OR" on the size dimensions AND "AND" on the shrinkage
  /// dimensions: this catches the catastrophic case (463 → 1
  /// lines, 16.9KB → 19B) without false-positiving on a small
  /// refactor that happens to drop a few lines.
  static const int kLargeLineThreshold = 100;
  static const int kLargeByteThreshold = 4096;
  static const double kTinyFraction = 0.2;
  static const double kTinyLineFraction = 0.2;

  String? _checkSizeMismatch(File file, String newContent) {
    final existingBytes = file.lengthSync();
    if (existingBytes <= 0) return null;

    final existingText = file.readAsStringSync();
    final existingLines = existingText.isEmpty
        ? 0
        : '\n'.allMatches(existingText).length + 1;
    final newBytes = utf8.encode(newContent).length;
    final newLines = newContent.isEmpty
        ? 0
        : '\n'.allMatches(newContent).length + 1;

    final isLarge =
        existingLines >= kLargeLineThreshold ||
        existingBytes >= kLargeByteThreshold;
    if (!isLarge) return null;

    final isTinyByBytes = newBytes <= existingBytes * kTinyFraction;
    final isTinyByLines =
        existingLines > 0 && newLines <= existingLines * kTinyLineFraction;
    // Both shrinkages must be true to trigger — protects against
    // false positives where the new content is a small refactor
    // that just happens to use shorter lines.
    if (!(isTinyByBytes && isTinyByLines)) return null;

    final relPath = relativePath(file.path, file.parent.parent.path);
    return 'Refusing to overwrite $relPath: the existing file is '
        '$existingLines lines / ${_formatBytes(existingBytes)}, but the new '
        'content is only $newLines lines / ${_formatBytes(newBytes)}. '
        'This looks like an accidental full-file rewrite — the `edit` '
        'tool merges changes by oldString/newString, while `write` '
        'replaces the whole file. Use `edit` for in-place changes, or '
        'pass `force: true` if you really want to overwrite the entire '
        'file with this small payload.';
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '${bytes}B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)}KB';
  }
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)}MB';
}
