import 'dart:async';
import 'dart:io';

import 'package:nocterm/nocterm.dart';

import '../components/tool_detail_utils.dart';
import '../lsp/manager.dart' show LspManager;
import '../models/message.dart';
import '../theme/crux_theme.dart';
import '../utils/fuzzy_match.dart';
import '../utils/token_estimate.dart' show estimateToolRoundTripTokens;
import 'file_read_tracker.dart';
import 'tool_def.dart';

const _defaultLimit = 2000;
const _maxLineLength = 2000;

class ReadTool extends ToolDef {
  final FileReadTracker? _tracker;
  final LspManager? _lsp;

  ReadTool({FileReadTracker? tracker, LspManager? lsp})
    : _tracker = tracker,
      _lsp = lsp;
  @override
  String get name => 'read';

  @override
  CollapsedSummary collapsedSummary(
    Map<String, dynamic> args,
    ToolResult result,
  ) {
    final lines = '\n'.allMatches(result.output).length + 1;
    final size = result.output.length;
    final sizeStr = size > 1024
        ? '${(size / 1024).toStringAsFixed(1)}KB'
        : '${size}B';
    final total = estimateToolRoundTripTokens(
      toolName: name,
      args: args,
      resultOutput: result.output,
    );
    // `read` isn't a LargePayloadTool, so args-only == total.
    return CollapsedSummary(
      text: '$lines lines, $sizeStr',
      argsTokens: total,
      totalTokens: total,
    );
  }

  @override
  String get description =>
      'Reads the contents of a file, a directory listing, or a '
      'specific line range of a file. Returns up to 2000 lines with '
      'line number prefixes; use offset/limit for later sections. '
      'CALL MULTIPLE IN PARALLEL — and feel free to mix with grep '
      'and glob in the same turn. When you need to read several '
      'files, list several directories, or read different ranges of '
      'the same file, issue all the read calls in the same turn '
      'rather than sequentially. This saves roundtrips. '
      'Do NOT shell out to cat / head / tail / less / sed -n via bash '
      'to do this — call this tool directly. It is faster, returns '
      'structured output, and supports line ranges directly.';

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'properties': {
      'filePath': {
        'type': 'string',
        'description': 'Path to file or directory',
      },
      'offset': {
        'type': 'integer',
        'description': 'Line number to start from (1-indexed)',
      },
      'limit': {
        'type': 'integer',
        'description': 'Max lines to read (default 2000)',
      },
    },
    'required': ['filePath'],
  };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args, ToolContext ctx) async {
    final filePath = args['filePath'] as String?;
    final offset = (args['offset'] as int?) ?? 1;
    final limit = (args['limit'] as int?) ?? _defaultLimit;

    if (filePath == null || filePath.isEmpty) {
      return ToolResult.error('Missing required parameter: filePath');
    }

    final path = resolvePath(filePath, ctx.workingDirectory);
    final type = FileSystemEntity.typeSync(path);

    if (type == FileSystemEntityType.notFound) {
      final suggestions = _suggestSimilarFiles(path);
      final relPath = relativePath(path, ctx.workingDirectory);
      final msg = suggestions.isNotEmpty
          ? 'Path not found: $relPath\nSimilar files in the same directory:\n$suggestions'
          : 'Path not found: $relPath';
      return ToolResult.error(msg);
    }

    if (type == FileSystemEntityType.directory) {
      return _readDirectory(path);
    }

    if (type == FileSystemEntityType.file) {
      return _readFile(path, offset, limit, ctx.workingDirectory);
    }

    return ToolResult.error(
      'Cannot read: ${relativePath(path, ctx.workingDirectory)} (FileSystemEntity type: $type)',
    );
  }

  ToolResult _readDirectory(String path) {
    final dir = Directory(path);
    final entries = dir.listSync();
    final sorted = entries.map((e) {
      final name = e.path.split('/').last;
      if (e is Directory) return '$name/';
      return name;
    }).toList();
    sorted.sort();
    final output = sorted.join('\n');
    return ToolResult(title: 'List directory: $path', output: output);
  }

  Future<ToolResult> _readFile(
    String path,
    int offset,
    int limit,
    String workingDirectory,
  ) async {
    final file = File(path);

    final binaryExts = {
      '.exe',
      '.dll',
      '.so',
      '.dylib',
      '.bin',
      '.obj',
      '.o',
      '.a',
      '.lib',
      '.class',
      '.jar',
      '.war',
      '.pyc',
      '.pyd',
    };
    final ext = path.contains('.') ? '.${path.split('.').last}' : '';
    if (binaryExts.contains(ext.toLowerCase())) {
      return ToolResult.error(
        'Binary file detected: ${relativePath(path, workingDirectory)}. Use bash tool for binary inspection.',
      );
    }

    final imageExts = {
      '.png',
      '.jpg',
      '.jpeg',
      '.gif',
      '.webp',
      '.bmp',
      '.ico',
      '.tiff',
      '.tif',
    };
    if (imageExts.contains(ext.toLowerCase())) {
      final size = file.lengthSync();
      final sizeStr = size > 1024 * 1024
          ? '${(size / (1024 * 1024)).toStringAsFixed(1)} MB'
          : size > 1024
          ? '${(size / 1024).toStringAsFixed(1)} KB'
          : '$size B';
      return ToolResult(
        title: 'Image file: $path',
        output:
            'Image file: ${relativePath(path, workingDirectory)} ($sizeStr)\n'
            'Format: ${ext.substring(1).toUpperCase()}\n'
            'This is an image file. Use /image to attach it to a message '
            'for models that support image input.',
      );
    }

    final snapshot = await _readStableLines(file);
    final lines = snapshot.lines;
    final mtimeMs = snapshot.mtimeMs;
    if (mtimeMs != null) {
      await _tracker?.recordRead(path, mtimeMs);
    }
    final totalLines = lines.length;

    final startLine = offset.clamp(1, totalLines) - 1;
    final endLine = (startLine + limit).clamp(0, totalLines);

    final selected = lines.sublist(startLine, endLine);
    final numbered = List.generate(selected.length, (i) {
      final line = selected[i];
      final truncatedLine = line.length > _maxLineLength
          ? '${line.substring(0, _maxLineLength)}... [truncated]'
          : line;
      return '${startLine + i + 1}: $truncatedLine';
    }).join('\n');

    final header = totalLines > endLine
        ? '[showing lines ${startLine + 1}-$endLine of $totalLines]'
        : '';

    final output = header.isNotEmpty ? '$header\n$numbered' : numbered;

    // Warm the LSP server in the background. Fire-and-forget:
    // the read tool must complete immediately without waiting
    // for the language server to start or analyze. By the time
    // the user edits the file, the analysis is already done
    // and the edit's diagnostic collection is sub-second.
    final mgr = _lsp;
    if (mgr != null) {
      unawaited(mgr.touchFileAndForget(path));
    }

    return ToolResult(title: 'Read file: $path', output: output);
  }

  Future<_TextFileSnapshot> _readStableLines(File file) async {
    FileStat afterStat;
    List<String> lines;

    for (var attempt = 0; attempt < 3; attempt++) {
      final beforeStat = file.statSync();
      lines = await file.readAsLines();
      afterStat = file.statSync();
      if (afterStat.modified == beforeStat.modified &&
          afterStat.size == beforeStat.size) {
        return _TextFileSnapshot(
          lines: lines,
          mtimeMs: afterStat.modified.millisecondsSinceEpoch,
        );
      }
    }

    return _TextFileSnapshot(lines: await file.readAsLines(), mtimeMs: null);
  }

  /// Suggest up to 5 entries in [path]'s directory that fuzzy-match
  /// the missing file's basename. Returns the newline-joined list of
  /// basenames, with directories marked by a trailing separator.
  ///
  /// Used when the agent asks to read a path that doesn't exist —
  /// the suggestion list lets it recover from typos like
  /// `read_tool.dart` (real) vs `readtools.dart` (typo). Fuzzy
  /// matching is the same algorithm the slash-command autocomplete
  /// and the @-mention file browser use (see `fuzzy_match.dart`),
  /// so the user gets consistent behavior across all three
  /// suggestion popovers.
  String _suggestSimilarFiles(String path) {
    final sep = Platform.pathSeparator;
    final lastSep = path.lastIndexOf(sep);
    if (lastSep == -1) return '';
    final dirPath = path.substring(0, lastSep);
    final target = path.substring(lastSep + 1);
    if (target.isEmpty) return '';
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return '';
    // Collect basenames with a `/` suffix for directories so the
    // suggestion output tells the user "hey, you can drill in".
    // We synthesize the entries as `name` and `name/` (matching
    // the rest of the read tool's display convention) and rank
    // them with `fuzzyRank`.
    final entries = <(String, bool)>[];
    try {
      for (final e in dir.listSync()) {
        final name = e.path.split(sep).last;
        if (name.isEmpty) continue;
        entries.add((name, e is Directory));
      }
    } on FileSystemException {
      return '';
    }
    if (entries.isEmpty) return '';
    final ranked = fuzzyRank<(String, bool)>(
      entries,
      (e) => e.$1,
      target,
    );
    return ranked
        .take(5)
        .map((e) => e.$2 ? '${e.$1}$sep' : e.$1)
        .join('\n');
  }

  @override
  String renderPruneInline({
    required ToolCallData call,
    required String pairedResult,
    required bool isError,
  }) {
    final path = call.input['filePath']?.toString() ?? '?';
    if (isError) return 'read $path → $pairedResult';
    return 'read $path';
  }

  @override
  SummaryContribution? extractPruneSummary({
    required ToolCallData call,
    required String pairedResult,
    required bool isError,
    required String workingDirectory,
  }) {
    if (isError) return null;
    final raw = call.input['filePath']?.toString();
    if (raw == null || raw.isEmpty) return null;
    // Use the tool_result content — what the model actually saw
    // — rather than re-reading from disk at compact time. The
    // chat log preserves the model's memory, not the current file
    // state. If the file changed externally between the read and
    // the compact, showing the new content would silently
    // "correct" the model's recollection without telling it; the
    // FileReadTracker's read-before-write guard is the right
    // place to surface that drift (and only when it matters,
    // i.e. before an edit/write).
    final content = truncateForInline(
      pairedResult,
      kInlineReadMaxChars,
      hint: 're-read with offset/limit to see more',
    );
    return SummaryContribution.readFile(path: raw, content: content);
  }

  Component? buildPrettyTab({
    required ToolCallData call,
    required Message? result,
    required CruxThemeData theme,
    required ScrollController scrollController,
  }) {
    final filePath = call.input['filePath']?.toString() ?? '';
    final content = result?.content ?? '';
    final language = languageFromPath(filePath);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        fileHeader(filePath, '', theme),
        if (content.isEmpty)
          dimText('  (empty)', theme)
        else
          scrollableCodeBlock(content, language, theme, controller: scrollController),
      ],
    );
  }
}

class _TextFileSnapshot {
  final List<String> lines;
  final int? mtimeMs;

  const _TextFileSnapshot({required this.lines, required this.mtimeMs});
}
