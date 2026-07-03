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
      style: TextStyle(
        color: theme.onSurfaceDim,
        fontStyle: FontStyle.italic,
      ),
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
