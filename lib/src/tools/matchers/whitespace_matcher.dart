import 'matcher.dart';

class WhitespaceMatcher extends Matcher {
  @override
  MatchResult? findMatches(String content, String pattern, bool replaceAll) {
    final normalizedContent = _normalize(content);
    final normalizedPattern = _normalize(pattern);

    final positions = <int>[];
    int start = 0;
    while (start < normalizedContent.length) {
      final idx = normalizedContent.indexOf(normalizedPattern, start);
      if (idx == -1) break;
      positions.add(idx);
      start = idx + normalizedPattern.length;
    }

    if (positions.isEmpty) return null;

    if (!replaceAll && positions.length > 1) {
      return MatchResult(
        positions: positions,
        error:
            'Found multiple matches for oldString (whitespace-normalized). Provide more surrounding context.',
      );
    }

    return MatchResult(positions: positions);
  }

  String _normalize(String s) {
    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
