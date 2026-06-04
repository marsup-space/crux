import 'package:nocterm/nocterm.dart';
import 'package:textmate_highlight/textmate_highlight.dart' as tm;

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
  'keyword': Color.fromRGB(197, 134, 192),
  'storage': Color.fromRGB(197, 134, 192),
  'entity.name.function': Color.fromRGB(220, 220, 170),
  'entity.name.type': Color.fromRGB(78, 201, 176),
  'entity.name.class': Color.fromRGB(78, 201, 176),
  'support.function': Color.fromRGB(220, 220, 170),
  'support.class': Color.fromRGB(78, 201, 176),
  'string': Color.fromRGB(206, 145, 120),
  'string.quoted': Color.fromRGB(206, 145, 120),
  'string.template': Color.fromRGB(206, 145, 120),
  'comment': Color.fromRGB(92, 99, 112),
  'constant': Color.fromRGB(86, 156, 214),
  'constant.numeric': Color.fromRGB(181, 206, 168),
  'variable': Color.fromRGB(156, 220, 254),
  'variable.parameter': Color.fromRGB(156, 220, 254),
  'tag': Color.fromRGB(78, 201, 176),
  'attribute.name': Color.fromRGB(156, 220, 254),
  'punctuation': Color.fromRGB(212, 212, 212),
  'punctuation.definition': Color.fromRGB(212, 212, 212),
  'meta': Color.fromRGB(212, 212, 212),
  'heading': Color.fromRGB(78, 201, 176),
  'emphasis': Color.fromRGB(220, 220, 170),
  'strong': Color.fromRGB(220, 220, 170),
};

Color colorForScopes(List<String> scopes) {
  for (final scope in scopes) {
    for (final fallback in _scopeFallbacks(scope)) {
      if (_scopeColorMap.containsKey(fallback)) {
        return _scopeColorMap[fallback]!;
      }
    }
  }
  return const Color.fromRGB(212, 212, 212);
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
        style: const TextStyle(color: Color.fromRGB(212, 212, 212)),
      ),
    ];
  }

  final tokens = highlighter.highlight(code);
  final spans = <InlineSpan>[];

  if (tokens.isEmpty) {
    return [
      TextSpan(
        text: code,
        style: const TextStyle(color: Color.fromRGB(212, 212, 212)),
      ),
    ];
  }

  var lastEnd = 0;
  for (final tm.HighlightedToken token in tokens) {
    if (token.start > lastEnd) {
      spans.add(
        TextSpan(
          text: code.substring(lastEnd, token.start),
          style: const TextStyle(color: Color.fromRGB(212, 212, 212)),
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
        style: const TextStyle(color: Color.fromRGB(212, 212, 212)),
      ),
    );
  }

  return spans;
}
