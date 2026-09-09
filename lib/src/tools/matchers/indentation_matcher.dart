import 'matcher.dart';

class IndentationMatcher extends Matcher {
  @override
  MatchResult? findMatches(String content, String pattern, bool replaceAll) {
    final contentLines = content.split('\n');
    final patternLines = pattern.split('\n');

    if (patternLines.isEmpty) return null;

    final patternBaseIndent = _leadingIndent(patternLines.first);

    final positions = <int>[];

    for (int ci = 0; ci <= contentLines.length - patternLines.length; ci++) {
      final contentBaseIndent = _leadingIndent(contentLines[ci]);

      var match = true;
      for (int pi = 0; pi < patternLines.length; pi++) {
        final contentLine = contentLines[ci + pi];
        final patternLine = patternLines[pi];

        final cIndent = _leadingIndent(contentLine);
        final pIndent = _leadingIndent(patternLine);

        final cRelativeIndent = cIndent - contentBaseIndent;
        final pRelativeIndent = pIndent - patternBaseIndent;

        final cStripped = contentLine.substring(cIndent).trimRight();
        final pStripped = patternLine.substring(pIndent).trimRight();

        if (cRelativeIndent != pRelativeIndent || cStripped != pStripped) {
          match = false;
          break;
        }
      }

      if (match) {
        var pos = 0;
        for (int i = 0; i < ci; i++) {
          pos += contentLines[i].length + 1;
        }
        positions.add(pos);
      }
    }

    if (positions.isEmpty) return null;

    if (!replaceAll && positions.length > 1) {
      return MatchResult(
        positions: positions,
        error: 'Found multiple matches for oldString (indentation-flexible). Provide more surrounding context.',
      );
    }

    return MatchResult(positions: positions);
  }

  int _leadingIndent(String line) {
    int count = 0;
    for (final ch in line.codeUnits) {
      if (ch == 32 || ch == 9) {
        count++;
      } else {
        break;
      }
    }
    return count;
  }
}
