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

Map<String, Color> _scopeColorMap(CruxThemeData theme) => {
  'keyword': theme.highlightKeyword,
  'keyword.operator': theme.syntaxOperator,
  'operator': theme.syntaxOperator,
  'storage': theme.highlightStorage,
  'entity.name.function': theme.highlightFunction,
  'entity.name.type': theme.highlightType,
  'entity.name.class': theme.highlightType,
  'support.function': theme.highlightFunction,
  'support.class': theme.highlightType,
  'string': theme.highlightString,
  'string.quoted': theme.highlightString,
  'string.template': theme.highlightString,
  'comment': theme.highlightComment,
  'constant': theme.highlightConstant,
  'constant.numeric': theme.highlightNumeric,
  'variable': theme.highlightVariable,
  'variable.parameter': theme.highlightVariable,
  'tag': theme.highlightTag,
  'attribute.name': theme.highlightAttribute,
  'punctuation': theme.highlightPunctuation,
  'punctuation.definition': theme.highlightPunctuation,
  'meta': theme.highlightMeta,
  'heading': theme.highlightType,
  'emphasis': theme.highlightFunction,
  'strong': theme.highlightFunction,
};

Color colorForScopes(List<String> scopes, CruxThemeData theme) {
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

/// Highlight an entire code block without caching.
/// Used for one-off highlighting where caching isn't needed.
List<InlineSpan> highlightCode(
  String code,
  String language,
  CruxThemeData theme,
) {
  return _highlightCodeUncached(code, language, theme);
}

/// Cache for code block highlighting results.
/// Keyed by (language, code_text) so that completed code blocks
/// don't need to be re-highlighted during streaming.
final Map<(String, String), List<InlineSpan>> _blockHighlightCache = {};

/// Maximum number of cached block highlights. Prevents unbounded
/// memory growth during long sessions.
const _maxBlockCacheSize = 512;

/// Highlight an entire code block as a unit, preserving TextMate's
/// stateful parsing for correct handling of multiline constructs
/// (triple-quoted strings, block comments, etc.).
///
/// This is the preferred method for code block rendering. It produces
/// a flat list of InlineSpans that may span multiple lines. The caller
/// is responsible for splitting them by line for rendering (adding
/// gutter prefixes, etc.).
///
/// Results are cached by (language, code_text) so that completed
/// code blocks don't need to be re-highlighted during streaming.
List<InlineSpan> highlightCodeBlock(
  String code,
  String language,
  CruxThemeData theme,
) {
  final cacheKey = (language, code);
  final cached = _blockHighlightCache[cacheKey];
  if (cached != null) return cached;

  final result = _highlightCodeUncached(code, language, theme);

  // Evict oldest entries if cache is too large.
  if (_blockHighlightCache.length >= _maxBlockCacheSize) {
    final keys = _blockHighlightCache.keys.take(_maxBlockCacheSize ~/ 4);
    for (final k in keys) {
      _blockHighlightCache.remove(k);
    }
  }
  _blockHighlightCache[cacheKey] = result;
  return result;
}

List<InlineSpan> _highlightCodeUncached(
  String code,
  String language,
  CruxThemeData theme,
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
