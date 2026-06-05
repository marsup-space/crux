abstract class Matcher {
  MatchResult? findMatches(String content, String pattern, bool replaceAll);
}

class MatchResult {
  final List<int> positions;
  final String? error;

  const MatchResult({required this.positions, this.error});
}
