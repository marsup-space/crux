import 'package:nocterm/nocterm.dart';
import 'package:textmate_highlight/textmate_highlight.dart' as tm;
import 'markdown_isolate.dart' show MarkdownThemeFields;

class HighlightService {
  static HighlightService? _instance;

  final tm.HighlightTheme _theme;
  final Map<String, tm.Highlighter> _highlighters = {};
  final Set<String> _loadedLanguages;

  HighlightService(this._theme, this._loadedLanguages);

  static Future<HighlightService> initialize() async {
    if (_instance != null) return _instance!;

    final languages = [
      // Original
      'dart',
      'python',
      'javascript',
      'typescript',
      'rust',
      'go',
      'java',
      'kotlin',
      'swift',
      'html',
      'css',
      'json',
      'yaml',
      'sql',
      // Vendored full TextMate grammars (shikijs/textmate-grammars-themes)
      'csharp',
      'cpp',
      'bash',
    ];

    await tm.Highlighter.initialize(languages);
    final theme = await tm.HighlightTheme.loadDarkTheme();
    _instance = HighlightService(theme, languages.toSet());
    return _instance!;
  }

  static HighlightService? get instance => _instance;

  tm.Highlighter? highlighterFor(String language) {
    final normalized = _normalizeLanguage(language);
    if (_highlighters.containsKey(normalized)) {
      return _highlighters[normalized];
    }
    if (!_loadedLanguages.contains(normalized)) return null;
    final highlighter = tm.Highlighter(language: normalized);
    _highlighters[normalized] = highlighter;
    return highlighter;
  }

  tm.TextStyle? styleForScopes(List<String> scopes) {
    return _theme.getStyle(scopes);
  }

  String _normalizeLanguage(String lang) {
    final lower = lang.toLowerCase().trim();
    switch (lower) {
      case 'js':
      case 'mjs':
      case 'cjs':
        return 'javascript';
      case 'ts':
      case 'tsx':
        return 'typescript';
      case 'py':
      case 'py3':
        return 'python';
      case 'rs':
        return 'rust';
      case 'kt':
      case 'kts':
        return 'kotlin';
      case 'yml':
        return 'yaml';
      case 'c#':
      case 'cs': // also the file extension — grammar id stays 'csharp'
        return 'csharp';
      case 'c++':
      case 'c': // no standalone 'c' grammar ships; C uses the cpp grammar
      case 'h':
      case 'cc':
      case 'cxx':
      case 'hpp':
      case 'hxx':
      case 'hh':
        return 'cpp';
      case 'rb':
        return 'ruby';
      case 'sh':
      case 'zsh':
      case 'shell':
        return 'bash';
      case 'patch':
        return 'diff';
      case 'diff':
      case 'git':
        return 'diff';
      case 'md':
        return 'markdown';
      case 'pl':
      case 'pm':
        return 'perl';
      case 'ex':
      case 'exs':
        return 'elixir';
      case 'erl':
      case 'hrl':
        return 'erlang';
      case 'clj':
      case 'cljs':
      case 'cljc':
      case 'edn':
        return 'clojure';
      case 'htm':
        return 'html';
      case 'svg':
      case 'xsl':
      case 'xslt':
        return 'xml';
      case 'dockerfile':
        return 'dockerfile';
      default:
        return lower;
    }
  }
}

Map<String, Color> _scopeColorMap(MarkdownThemeFields theme) => {
  'keyword': theme.highlightKeyword,
  'keyword.operator': theme.syntaxOperator,
  'operator': theme.syntaxOperator,
  'storage': theme.highlightStorage,
  'entity.name.function': theme.highlightFunction,
  'entity.name.type': theme.highlightType,
  'entity.name.class': theme.highlightType,
  'support': theme.highlightAttribute,
  'support.type': theme.highlightAttribute,
  'support.function': theme.highlightFunction,
  'support.class': theme.highlightType,
  'string': theme.highlightString,
  'string.quoted': theme.highlightString,
  'string.template': theme.highlightString,
  'comment': theme.highlightComment,
  'constant': theme.highlightConstant,
  'constant.numeric': theme.highlightNumeric,
  'constant.language.boolean': theme.highlightConstant,
  'constant.language.null': theme.highlightKeyword,
  'variable': theme.highlightVariable,
  'variable.parameter': theme.highlightVariable,
  'tag': theme.highlightTag,
  'attribute.name': theme.highlightAttribute,
  'punctuation': theme.highlightPunctuation,
  'punctuation.definition': theme.highlightPunctuation,
  'heading': theme.highlightType,
  'emphasis': theme.highlightFunction,
  'strong': theme.highlightFunction,
};

Color colorForScopes(List<String> scopes, MarkdownThemeFields theme) {
  final colors = _scopeColorMap(theme);
  for (final scope in scopes) {
    for (final fallback in _scopeFallbacks(scope)) {
      if (colors.containsKey(fallback)) {
        return colors[fallback]!;
      }
    }
  }
  return theme.highlightDefault;
}

List<String> _scopeFallbacks(String scope) {
  final fallbacks = <String>[];
  final parts = scope.split('.');
  for (var i = 0; i < parts.length; i++) {
    fallbacks.add(parts.sublist(0, i + 1).join('.'));
  }
  return fallbacks.reversed.toList();
}

List<InlineSpan> highlightCode(
  String code,
  String language,
  MarkdownThemeFields theme,
) {
  final service = HighlightService.instance;
  final tm.Highlighter? highlighter = service?.highlighterFor(language);
  if (highlighter == null) {
    return [
      TextSpan(
        text: code,
        style: TextStyle(color: theme.highlightDefault),
      ),
    ];
  }

  final tokens = highlighter.highlight(code);
  final spans = <InlineSpan>[];

  if (tokens.isEmpty) {
    return [
      TextSpan(
        text: code,
        style: TextStyle(color: theme.highlightDefault),
      ),
    ];
  }

  var lastEnd = 0;
  for (final tm.HighlightedToken token in tokens) {
    if (token.start > lastEnd) {
      spans.add(
        TextSpan(
          text: code.substring(lastEnd, token.start),
          style: TextStyle(color: theme.highlightDefault),
        ),
      );
    }

    final tokenText = token.text(code);
    final color = colorForScopes(token.scopes, theme);
    final tmStyle = service?.styleForScopes(token.scopes);
    final fontWeight = tmStyle?.bold == true
        ? FontWeight.bold
        : FontWeight.normal;
    final fontStyle = tmStyle?.italic == true
        ? FontStyle.italic
        : FontStyle.normal;

    spans.add(
      TextSpan(
        text: tokenText,
        style: TextStyle(
          color: color,
          fontWeight: fontWeight,
          fontStyle: fontStyle,
        ),
      ),
    );
    lastEnd = token.end;
  }

  if (lastEnd < code.length) {
    spans.add(
      TextSpan(
        text: code.substring(lastEnd),
        style: TextStyle(color: theme.highlightDefault),
      ),
    );
  }

  return spans;
}
