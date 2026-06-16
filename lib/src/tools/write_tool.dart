import 'dart:convert';
import 'dart:io';

import '../utils/file_metadata.dart';
import '../utils/offload_standin.dart'
    show containsOffloadStandIn, lineCountOfArg, parseOffloadStandIn;
import '../utils/token_estimate.dart' show estimateToolRoundTripTokens;
import 'file_read_tracker.dart';
import 'tool_def.dart';

class WriteTool extends LargePayloadTool with IntentionalTool {
  @override
  List<String> get offloadableArgs => ['content'];

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
    final newLines = lineCountOfArg(content);
    // When [content] is an offload stand-in pointer, the raw
    // length is the length of the metadata string (~100 chars),
    // not the original payload. Recover the real size from the
    // stand-in's `sizeStr` field; only fall back to the raw
    // length when the value isn't a stand-in.
    final standIn = parseOffloadStandIn(content);
    final sizeStr = standIn != null
        ? standIn.sizeStr
        : (() {
            final size = content.length;
            return size > 1024
                ? '${(size / 1024).toStringAsFixed(1)}KB'
                : '${size}B';
          })();
    // Total cost = args (with the *as-persisted* content, which
    // may be a stand-in if offload happened) + the tool's result.
    final totalTokens = estimateToolRoundTripTokens(
      toolName: name,
      args: args,
      resultOutput: content,
    );
    // Args-only cost is what the strikethrough compares against.
    // We compute it on the *as-passed* args, which is the same
    // thing the chat service's preCompressTokens calculation
    // uses (it also runs at the compress boundary, so the args
    // are still full there).
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
      'Overwrites a file with new content. After a successful call, the '
      'content is moved from the conversation context to the '
      'offloaded_content table if it exceeds the offload threshold; the '
      'result message reports the composite key when this happens so it '
      'can be referenced on subsequent turns if needed.';

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'properties': {
      'filePath': {'type': 'string', 'description': 'Path to file'},
      'content': {
        'type': 'string',
        'description': 'Content to write',
      },
      'intent': {
        'type': 'string',
        'description': 'What this file is for / why you are writing it. Be concise.',
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
    if (containsOffloadStandIn(content)) {
      return ToolResult.error(
        'Refusing to write offloaded-content stand-in text into a file. '
        'The `content` argument contains a `[offloaded: ...]` history '
        'placeholder, not the original file bytes. Re-read the file or '
        'provide the real content before calling `write`.',
      );
    }

    final resolved = resolvePath(filePath, ctx.workingDirectory);
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
    // data on the tool_call's input, where it survives the
    // compress-for-persistence step. We stash it BEFORE
    // writing the file — once we've overwritten the bytes
    // the "existing" count would be lost.
    //
    // Edge case: if [content] was offloaded, [lineCountOfArg]
    // would treat it as a stand-in pointer. We guarded against
    // that by reading the prior contents from disk (not from
    // [content]) — the line count here is of the OLD file, so
    // the only value that could be a stand-in is [content],
    // which we don't use for the prior line count.
    final existingLineCount = meta.content.isEmpty
        ? 0
        : '\n'.allMatches(meta.content).length + 1;
    args['_existingLineCount'] = existingLineCount;
    final newLines = content.isEmpty
        ? 0
        : '\n'.allMatches(content).length + 1;
    final body = normalizeToLineEnding(content, meta.lineEnding);
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
      output = '$output (intent: \'$intent\'), $diffLabel, ${_formatBytes(content.length)}';
    } else {
      output = '$output, $diffLabel, ${_formatBytes(content.length)}';
    }

    final offloaded = argsToOffload(args);
    if (offloaded.isNotEmpty && ctx.callId != null) {
      final toolIntent = (this as IntentionalTool).intentFromArgs(args);
      output = '$output\n\n${buildOffloadNote(callId: ctx.callId!, offloadedArgs: offloaded, intent: toolIntent)}';
    }

    return ToolResult(
      title: 'Write file: $resolved',
      output: output,
    );
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
    final newLines =
        newContent.isEmpty ? 0 : '\n'.allMatches(newContent).length + 1;

    final isLarge = existingLines >= kLargeLineThreshold ||
        existingBytes >= kLargeByteThreshold;
    if (!isLarge) return null;

    final isTinyByBytes = newBytes <= existingBytes * kTinyFraction;
    final isTinyByLines = existingLines > 0 &&
        newLines <= existingLines * kTinyLineFraction;
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
