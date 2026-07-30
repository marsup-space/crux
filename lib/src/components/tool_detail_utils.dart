import 'dart:math' as math;

import 'package:nocterm/nocterm.dart';

import '../theme/crux_theme.dart';
import 'ui/highlighted_markdown_text.dart';

/// Shared building blocks used by the tool detail pane and any
/// tool that wants to render its own pretty tab (currently
/// [ReadTool]). Lifted out of [ToolDetailPane]'s private state
/// so per-tool implementations can reuse the same look — file
/// header, dim placeholder text, and the syntax-highlighted
/// scrollable code block — without having to copy the markup.

/// File path header used by write, edit, read.
Component fileHeader(String filePath, String intent, CruxThemeData theme) {
  final spans = <TextSpan>[];
  spans.add(
    TextSpan(
      text: '📄 ', // file icon
      style: TextStyle(color: theme.foreground),
    ),
  );
  spans.add(
    TextSpan(
      text: filePath,
      style: TextStyle(color: theme.foreground, fontWeight: FontWeight.bold),
    ),
  );
  if (intent.isNotEmpty) {
    spans.add(
      TextSpan(
        text: '  $intent',
        style: TextStyle(
          color: theme.onSurfaceDim,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
    child: Row(
      children: [
        Expanded(
          child: RichText(text: TextSpan(children: spans)),
        ),
      ],
    ),
  );
}

/// Italic, dimmed placeholder line — used for `(empty)`,
/// `(no output)`, etc. Keeps the visual language consistent
/// across the tool detail tabs.
Component dimText(String text, CruxThemeData theme) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
    child: Text(
      text,
      style: TextStyle(color: theme.onSurfaceDim, fontStyle: FontStyle.italic),
    ),
  );
}

/// Full-width scrollable code block with syntax highlighting.
/// [controller] is required so callers can share a
/// [ScrollController] across the whole tab and the bar
/// thumb stays in sync with the scroll position.
Component scrollableCodeBlock(
  String content,
  String language,
  CruxThemeData theme, {
  required ScrollController controller,
}) {
  final fence = language.isNotEmpty
      ? '```$language\n$content\n```'
      : '```\n$content\n```';
  return Scrollbar(
    controller: controller,
    thumbVisibility: true,
    thumbColor: theme.onSurfaceDim.withOpacity(0.4),
    trackColor: theme.surfaceVariant.withOpacity(0.3),
    child: SingleChildScrollView(
      controller: controller,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
        child: HighlightedMarkdownText(
          fence,
          styleSheet: HighlightMarkdownStyleSheet.fromTheme(theme),
        ),
      ),
    ),
  );
}

// ── Unified line diff ────────────────────────────────────────────────

/// The role of one rendered row in a unified line diff.
enum DiffLineKind {
  /// A line present in both old and new (unchanged context).
  context,

  /// A line present only in the old string (deleted).
  removed,

  /// A line present only in the new string (inserted).
  added,

  /// A gap marker standing in for a collapsed run of unchanged
  /// lines; [DiffLine.elidedCount] carries the hidden line count.
  gap,
}

/// One row of a unified line diff produced by [computeLineDiff].
class DiffLine {
  const DiffLine(this.kind, this.text, {this.elidedCount = 0});

  final DiffLineKind kind;

  /// The line content for [DiffLineKind.context], [DiffLineKind.removed],
  /// and [DiffLineKind.added]. Empty for [DiffLineKind.gap].
  final String text;

  /// Number of unchanged lines a [DiffLineKind.gap] row stands in for.
  final int elidedCount;
}

/// Compute a unified, line-level diff between [oldText] and [newText]
/// using a longest-common-subsequence over lines (no external deps).
///
/// Lines common to both sides come out as [DiffLineKind.context],
/// deletions as [DiffLineKind.removed], insertions as
/// [DiffLineKind.added]. Any unchanged run longer than
/// `2 * contextLines + 1` collapses into a single [DiffLineKind.gap]
/// marker that keeps [contextLines] lines of context on each side —
/// this is what lets a 200-line identical middle render as
/// `⋮ 196 unchanged lines` instead of a wall of context.
List<DiffLine> computeLineDiff(
  String oldText,
  String newText, {
  int contextLines = 2,
}) {
  final oldLines = _splitDiffLines(oldText);
  final newLines = _splitDiffLines(newText);
  final m = oldLines.length;
  final n = newLines.length;

  // LCS length table: dp[i][j] = length of the longest common
  // subsequence of oldLines[i..] and newLines[j..].
  final dp = List.generate(m + 1, (_) => List.filled(n + 1, 0));
  for (var i = m - 1; i >= 0; i--) {
    for (var j = n - 1; j >= 0; j--) {
      dp[i][j] = oldLines[i] == newLines[j]
          ? dp[i + 1][j + 1] + 1
          : math.max(dp[i + 1][j], dp[i][j + 1]);
    }
  }

  // Backtrack the table into an op stream. Ties prefer a removal so
  // the deleted block prints above the inserted block (matching how
  // `git diff` orders a replaced hunk).
  final raw = <DiffLine>[];
  var i = 0;
  var j = 0;
  while (i < m && j < n) {
    if (oldLines[i] == newLines[j]) {
      raw.add(DiffLine(DiffLineKind.context, oldLines[i]));
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      raw.add(DiffLine(DiffLineKind.removed, oldLines[i]));
      i++;
    } else {
      raw.add(DiffLine(DiffLineKind.added, newLines[j]));
      j++;
    }
  }
  while (i < m) {
    raw.add(DiffLine(DiffLineKind.removed, oldLines[i]));
    i++;
  }
  while (j < n) {
    raw.add(DiffLine(DiffLineKind.added, newLines[j]));
    j++;
  }

  // Collapse long unchanged runs into gap markers.
  final result = <DiffLine>[];
  var k = 0;
  while (k < raw.length) {
    if (raw[k].kind != DiffLineKind.context) {
      result.add(raw[k]);
      k++;
      continue;
    }
    var runEnd = k;
    while (runEnd < raw.length && raw[runEnd].kind == DiffLineKind.context) {
      runEnd++;
    }
    final runLength = runEnd - k;
    if (runLength > 2 * contextLines + 1) {
      for (var c = 0; c < contextLines; c++) {
        result.add(raw[k + c]);
      }
      result.add(
        DiffLine(
          DiffLineKind.gap,
          '',
          elidedCount: runLength - 2 * contextLines,
        ),
      );
      for (var c = runLength - contextLines; c < runLength; c++) {
        result.add(raw[k + c]);
      }
    } else {
      for (var c = 0; c < runLength; c++) {
        result.add(raw[k + c]);
      }
    }
    k = runEnd;
  }
  return result;
}

/// Split [text] into lines for diffing. A single trailing newline
/// (the conventional end-of-file marker) does not produce a phantom
/// empty line; an empty string diffs as zero lines.
List<String> _splitDiffLines(String text) {
  if (text.isEmpty) return const [];
  final lines = text.split('\n');
  if (lines.length > 1 && lines.last.isEmpty) {
    lines.removeLast();
  }
  return lines;
}

/// Detect the syntax-highlighting language for a file path.
/// Returns the empty string when the path has no extension or
/// the extension is not in the map, which keeps [scrollableCodeBlock]
/// happy (it interprets empty `language` as "no fence tag").
String languageFromPath(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot >= path.length - 1) return '';
  final ext = path.substring(dot + 1).toLowerCase();
  return _extToLanguage[ext] ?? '';
}

const _extToLanguage = <String, String>{
  'dart': 'dart',
  'py': 'python',
  'js': 'javascript',
  'mjs': 'javascript',
  'cjs': 'javascript',
  'ts': 'typescript',
  'tsx': 'typescript',
  'jsx': 'javascript',
  'rs': 'rust',
  'go': 'go',
  'java': 'java',
  'kt': 'kotlin',
  'kts': 'kotlin',
  'swift': 'swift',
  'html': 'html',
  'htm': 'html',
  'css': 'css',
  'scss': 'css',
  'json': 'json',
  'yaml': 'yaml',
  'yml': 'yaml',
  'sql': 'sql',
  'sh': 'bash',
  'bash': 'bash',
  'zsh': 'bash',
  'toml': 'toml',
  'xml': 'xml',
  'md': 'markdown',
  'c': 'c',
  'cpp': 'cpp',
  'cc': 'cpp',
  'cxx': 'cpp',
  'h': 'c',
  'hpp': 'cpp',
  'rb': 'ruby',
  'php': 'php',
  'lua': 'lua',
  'pl': 'perl',
  'r': 'r',
  'scala': 'scala',
  'ex': 'elixir',
  'exs': 'elixir',
  'erl': 'erlang',
  'hs': 'haskell',
  'clj': 'clojure',
  'vue': 'html',
  'svelte': 'html',
};
