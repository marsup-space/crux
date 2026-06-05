import 'matcher.dart';

class ExactMatcher extends Matcher {
  @override
  MatchResult? findMatches(String content, String pattern, bool replaceAll) {
    final positions = <int>[];
    int start = 0;
    while (start < content.length) {
      final idx = content.indexOf(pattern, start);
      if (idx == -1) break;
      positions.add(idx);
      start = idx + pattern.length;
    }

    if (positions.isEmpty) return null;

    if (!replaceAll && positions.length > 1) {
      return MatchResult(
        positions: positions,
        error:
            'Found multiple matches for oldString. Provide more surrounding lines in oldString to identify the correct match.',
      );
    }

    return MatchResult(positions: positions);
  }
}
