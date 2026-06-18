import 'dart:convert';
import 'dart:io';

import '../utils/file_metadata.dart';
import '../utils/token_estimate.dart' show estimateToolRoundTripTokens;
import 'file_lock.dart';
import 'file_read_tracker.dart';
import 'tool_def.dart';

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
    // _existingLineCount is stashed in args by [execute] at the
    // moment we read the file's prior contents (so the summary
    // can show the actual `+added -removed` diff). When the
    // call hasn't run yet — e.g. the result is being rendered
    // before the tool has actually executed — we fall back to
    // 0, which means "no prior content" (i.e. treat it as a
    // new file) and show only the `+added lines` part.
    final existingLineCount = (args['_existingLineCount'] as int?) ?? 0;
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

  WriteTool({this.tracker});

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
    final file = File(resolved);

    if (tracker != null && file.existsSync()) {
      final guard = await tracker!.checkWriteGuard(resolved);
      if (guard != null) {
        return ToolResult(
          title: 'Read-before-write guard triggered',
          output: '${guard.header}\n\n${guard.content}',
          metadata: {'guardTriggered': true},
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
          title: 'Size-mismatch guard triggered',
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
    // Capture the prior line count for the bubble's
    // collapsedSummary (which renders the actual
    // `+added -removed` diff). Stashing it on `args` keeps the
    // data on the tool_call's input, where it survives across
    // rounds. We stash it BEFORE writing the file — once
    // we've overwritten the bytes the "existing" count would
    // be lost.
    final existingLineCount = meta.content.isEmpty
        ? 0
        : '\n'.allMatches(meta.content).length + 1;
    args['_existingLineCount'] = existingLineCount;
    final newLines = content.isEmpty ? 0 : '\n'.allMatches(content).length + 1;
    // Respect the target line ending from .gitattributes. If
    // the file is declared binary, `targetLineEnding` is null
    // and we write the content byte-for-byte (no normalization
    // — the agent would have to ask for a write that re-encodes
    // a binary file, which we should refuse on principle, but
    // for now we just don't break it).
    final targetLineEnding =
        targetLineEndingFor(resolved, meta.lineEnding);
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

    return ToolResult(title: 'Write file: $resolved', output: output);
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