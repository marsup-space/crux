import 'package:nocterm/nocterm.dart';
import 'package:textmate_highlight/textmate_highlight.dart' as tm;
import '../../theme/crux_theme.dart';

class HighlightService {
  static HighlightService? _instance;

  final tm.HighlightTheme _theme;
  final Map<String, tm.Highlighter> _highlighters = {};
  final Set<String> _loadedLanguages;

  HighlightService(this._theme, this._loadedLanguages);

  static Future<HighlightService> initialize() async {
    if (_instance != null) return _instance!;

    final languages = [
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
        return 'javascript';
      case 'ts':
        return 'typescript';
      case 'py':
        return 'python';
      case 'rs':
        return 'rust';
      case 'kt':
      case 'kts':
        return 'kotlin';
      case 'yml':
        return 'yaml';
      default:
        return lower;
    }
  }
}

const _scopeColorMap = <String, Color>{
  'keyword': CruxTheme.highlightKeyword,
  'storage': CruxTheme.highlightStorage,
  'entity.name.function': CruxTheme.highlightFunction,
  'entity.name.type': CruxTheme.highlightType,
  'entity.name.class': CruxTheme.highlightType,
  'support.function': CruxTheme.highlightFunction,
  'support.class': CruxTheme.highlightType,
  'string': CruxTheme.highlightString,
  'string.quoted': CruxTheme.highlightString,
  'string.template': CruxTheme.highlightString,
  'comment': CruxTheme.highlightComment,
  'constant': CruxTheme.highlightConstant,
  'constant.numeric': CruxTheme.highlightNumeric,
  'variable': CruxTheme.highlightVariable,
  'variable.parameter': CruxTheme.highlightVariable,
  'tag': CruxTheme.highlightTag,
  'attribute.name': CruxTheme.highlightAttribute,
  'punctuation': CruxTheme.highlightPunctuation,
  'punctuation.definition': CruxTheme.highlightPunctuation,
  'meta': CruxTheme.highlightMeta,
  'heading': CruxTheme.highlightType,
  'emphasis': CruxTheme.highlightFunction,
  'strong': CruxTheme.highlightFunction,
};

Color colorForScopes(List<String> scopes) {
  for (final scope in scopes) {
    for (final fallback in _scopeFallbacks(scope)) {
      if (_scopeColorMap.containsKey(fallback)) {
        return _scopeColorMap[fallback]!;
      }
    }
  }
  return CruxTheme.highlightDefault;
}

List<String> _scopeFallbacks(String scope) {
  final fallbacks = <String>[];
  final parts = scope.split('.');
  for (var i = 0; i < parts.length; i++) {
    fallbacks.add(parts.sublist(0, i + 1).join('.'));
  }
  return fallbacks.reversed.toList();
}

List<InlineSpan> highlightCode(String code, String language) {
  final service = HighlightService.instance;
  final tm.Highlighter? highlighter = service?.highlighterFor(language);
  if (highlighter == null) {
    return [
      TextSpan(
        text: code,
        style: const TextStyle(color: CruxTheme.highlightDefault),
      ),
    ];
  }

  final tokens = highlighter.highlight(code);
  final spans = <InlineSpan>[];

  if (tokens.isEmpty) {
    return [
      TextSpan(
        text: code,
        style: const TextStyle(color: CruxTheme.highlightDefault),
      ),
    ];
  }

  var lastEnd = 0;
  for (final tm.HighlightedToken token in tokens) {
    if (token.start > lastEnd) {
      spans.add(
        TextSpan(
          text: code.substring(lastEnd, token.start),
          style: const TextStyle(color: CruxTheme.highlightDefault),
        ),
      );
    }

    final tokenText = token.text(code);
    final color = colorForScopes(token.scopes);
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
        style: const TextStyle(color: CruxTheme.highlightDefault),
      ),
    );
  }

  return spans;
}
