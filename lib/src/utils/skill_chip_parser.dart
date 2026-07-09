/// Shared logic for finding an in-progress `$` skill chip in the
/// chat input's text buffer.
///
/// Mirrors [findActiveMentionInText] (the at-mention parser) but
/// for the `$` trigger. A "skill chip" is a `$<name>` token in
/// the text where `<name>` is a valid skill identifier
/// (`[a-z0-9][a-z0-9-]*` per the open standard). The picker uses
/// the parser to know which skill list to show and which fragment
/// the user is currently typing.
///
/// The parser does **not** validate that `<name>` matches a real
/// skill — that's the picker's job. The parser only knows about
/// the `$<chars>` shape, so it can hand a typed prefix to the
/// picker for matching.
library;

/// Position of an in-progress `$` skill chip in text being edited.
///
/// Returned by [findActiveSkillChip] when [text] contains a `$`
/// at or before [cursor] with no terminator between it and the
/// cursor.
class SkillChipPosition {
  /// Offset of the `$` in [text].
  final int dollarOffset;

  /// Offset where the query begins (== dollarOffset + 1).
  final int queryStart;

  /// Cursor position (== end of query).
  final int cursor;

  /// Text between the `$` and the cursor.
  final String query;

  const SkillChipPosition({
    required this.dollarOffset,
    required this.queryStart,
    required this.cursor,
    required this.query,
  });
}

/// True if [c] is a character that can appear inside a skill
/// name. Matches the open-standard regex `[a-z0-9-]`.
bool isSkillNameChar(String c) {
  if (c.isEmpty) return false;
  final cc = c.codeUnitAt(0);
  return (cc >= 0x30 && cc <= 0x39) || // 0-9
      (cc >= 0x61 && cc <= 0x7A) || // a-z
      cc == 0x2D; // -
}

/// Find an in-progress `$` skill chip ending at [cursor]. Returns
/// `null` if there is no chip the user is currently editing.
///
/// "Active" means: there's a `$` at or before the cursor, every
/// char between the `$` and the cursor is a [isSkillNameChar]
/// (so the chip is unbroken), and the cursor sits at the end of
/// the chip (i.e. the user is typing the name, not editing in
/// the middle).
///
/// Unlike the at-mention parser, this does NOT reject
/// `$`-after-identifier-char: a chip in the middle of a word is
/// still a chip. If the user types `foo$bar`, the `$bar` is
/// recognized as a chip — the picker will simply find no
/// matching skill for `bar` and dismiss.
SkillChipPosition? findActiveSkillChip(String text, int cursor) {
  final clamped = cursor.clamp(0, text.length);
  if (clamped == 0) return null;

  // Walk back from cursor-1 looking for a `$` whose intervening
  // chars are all skill-name chars. The first non-skill-name
  // char we hit (other than `$`) ends the search.
  var dollarOffset = -1;
  for (var i = clamped - 1; i >= 0; i--) {
    final ch = text[i];
    if (ch == r'$') {
      dollarOffset = i;
      break;
    }
    if (!isSkillNameChar(ch)) {
      // Hit a terminator (space, punctuation, etc.) — no
      // active chip.
      return null;
    }
  }
  if (dollarOffset < 0) return null;

  // The chip must be the LAST thing the user is editing — i.e.
  // the cursor sits at the end of the `$<chars>` token. We can
  // tell because the previous scan stopped on the first
  // non-skill-name char to the left of the cursor; if that char
  // was the `$`, the chip is the last token. (If we ran off the
  // start of the string, the chip is also at the boundary.)
  //
  // The `for` loop above also ensures every char between `$` and
  // cursor is a skill-name char (or the `$` itself), so a chip
  // in the middle of a word would have failed the
  // non-skill-name check on a letter like `f` in `foo$bar`.
  final query = text.substring(dollarOffset + 1, clamped);
  return SkillChipPosition(
    dollarOffset: dollarOffset,
    queryStart: dollarOffset + 1,
    cursor: clamped,
    query: query,
  );
}

/// Find every `$<skill-name>` token in [text], where [skillNames]
/// is the set of known skill identifiers. Returns the
/// is the set of known skill identifiers. Returns the
/// (dollarOffset, endOffset, skillName) triples in left-to-right
/// order. Used by the submit-time substitution to find complete
/// chips (not in-progress ones).
///
/// A token is a complete chip when:
///   * The char before `$` is not a skill-name char (so `foo$bar`
///     does not count as the chip `$bar`).
///   * The chars after `$` form a valid skill name AND match one
///     of [skillNames].
///   * The char after the name is not a skill-name char (so
///     `$pr-reviewfoo` does not match the skill `pr-review`).
List<SkillChipMatch> findAllSkillChips(
  String text,
  Set<String> skillNames,
) {
  final matches = <SkillChipMatch>[];
  for (var i = 0; i < text.length; i++) {
    if (text[i] != r'$') continue;
    // Reject `$` after a skill-name char.
    if (i > 0 && isSkillNameChar(text[i - 1])) continue;
    // Read the candidate name.
    var j = i + 1;
    while (j < text.length && isSkillNameChar(text[j])) {
      j++;
    }
    if (j == i + 1) continue; // just `$` with nothing after
    final candidate = text.substring(i + 1, j);
    if (!skillNames.contains(candidate)) continue;
    // The char after the name must not be a skill-name char.
    if (j < text.length && isSkillNameChar(text[j])) continue;
    matches.add(SkillChipMatch(
      dollarOffset: i,
      nameEndOffset: j,
      skillName: candidate,
    ));
  }
  return matches;
}

/// A complete `$<skill-name>` chip found in text. [dollarOffset]
/// points at the `$`; [nameEndOffset] is one past the last
/// character of the skill name (so `text.substring(dollarOffset,
/// nameEndOffset)` is the full `$<name>` token).
class SkillChipMatch {
  final int dollarOffset;
  final int nameEndOffset;
  final String skillName;

  const SkillChipMatch({
    required this.dollarOffset,
    required this.nameEndOffset,
    required this.skillName,
  });
}
