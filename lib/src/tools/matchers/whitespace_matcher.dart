import 'matcher.dart';

class WhitespaceMatcher extends Matcher {
  @override
  MatchResult? findMatches(String content, String pattern, bool replaceAll) {
    final normalizedContent = _normalize(content);
    final normalizedPattern = _normalize(pattern);

    final map = _buildPositionMap(content);

    final positions = <int>[];
    final lengths = <int>[];
    int start = 0;
    while (start < normalizedContent.length) {
      final idx = normalizedContent.indexOf(normalizedPattern, start);
      if (idx == -1) break;
      final startOrig = map[idx];
      final endOrig = _computeEndOrig(
        content,
        map,
        idx + normalizedPattern.length,
      );
      positions.add(startOrig);
      lengths.add(endOrig - startOrig);
      start = idx + normalizedPattern.length;
    }

    if (positions.isEmpty) return null;

    if (!replaceAll && positions.length > 1) {
      return MatchResult(
        positions: positions,
        error: 'Found multiple matches for oldString (whitespace-normalized). Provide more surrounding context.',
      );
    }

    return MatchResult(positions: positions, matchLength: lengths.first);
  }

  int _computeEndOrig(String content, List<int> map, int endNorm) {
    if (endNorm >= map.length) {
      final lastOrigPos = map.last;
      if (_isWs(content[lastOrigPos])) {
        int end = lastOrigPos + 1;
        while (end < content.length && _isWs(content[end])) {
          end++;
        }
        return end;
      }
      return lastOrigPos + 1;
    }
    return map[endNorm];
  }

  List<int> _buildPositionMap(String content) {
    final map = <int>[];
    int i = 0;
    final len = content.length;

    while (i < len && _isWs(content[i])) {
      i++;
    }

    bool prevWasSpace = false;
    while (i < len) {
      if (_isWs(content[i])) {
        if (!prevWasSpace) {
          map.add(i);
          prevWasSpace = true;
        }
        i++;
      } else {
        map.add(i);
        prevWasSpace = false;
        i++;
      }
    }

    while (map.isNotEmpty && _isWs(content[map.last])) {
      map.removeLast();
    }

    return map;
  }

  bool _isWs(String ch) {
    return ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r';
  }

  String _normalize(String s) {
    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
