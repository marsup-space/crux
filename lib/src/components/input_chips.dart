import 'package:nocterm/nocterm.dart';

import '../theme/crux_theme.dart';
import '../utils/skill_chip_parser.dart';
import '../utils/session_mention.dart';

/// Matches the `[ image N ]` marker the chat input inserts for
/// clipboard-attached images, so the chip renderer can style it.
final RegExp _imageMarkerPattern = RegExp(r'\[ image (\d+) \]');

/// Builds styled segments so that `$<skill-name>`, `[ image N ]`,
/// `@<path>`, and `#<session>` tokens in the input render with a chip
/// background.
///
/// Shared by the chat input and the home quick-chat input so the two
/// surfaces render mentions identically. Skill chips: any `$` followed
/// by valid skill-name chars is treated as a chip (the `$` stays in the
/// text for submit-time parsing but is styled invisible). At-mentions use
/// the same treatment — `@` is kept but invisible. Session mentions do
/// the same with `#`. Image markers use the same chip style. Non-chip
/// text uses [baseStyle].
List<StyledTextSegment>? buildInputChipSegments({
  required String text,
  required List<MentionChip> mentionChips,
  required CruxThemeData theme,
  required TextStyle baseStyle,
}) {
  if (text.isEmpty) return null;

  final chipStyle = TextStyle(
    color: theme.onColor(theme.chipBackground),
    backgroundColor: theme.chipBackground,
  );
  final invisibleTrigger = TextStyle(
    color: theme.chipBackground,
    backgroundColor: theme.chipBackground,
  );

  // Completed mentions — rendered from their recorded spans so a
  // multi-word title/path stays one chip while prose typed after
  // the mention is never swallowed into it.
  final sortedChips = List<MentionChip>.from(mentionChips)
    ..sort((a, b) => a.start.compareTo(b.start));

  MentionChip? chipAt(int pos) {
    for (final c in sortedChips) {
      if (c.start == pos) return c;
      if (c.start > pos) break;
    }
    return null;
  }

  final segments = <StyledTextSegment>[];
  var i = 0;
  while (i < text.length) {
    final completedChip = chipAt(i);
    if (completedChip != null) {
      final end = completedChip.start + completedChip.content.length;
      if (completedChip.start >= 0 &&
          end <= text.length &&
          text.substring(completedChip.start, end) == completedChip.content) {
        final content = completedChip.content;
        if (content.isNotEmpty) {
          segments.add(StyledTextSegment(content[0], invisibleTrigger));
          if (content.length > 1) {
            segments.add(StyledTextSegment(content.substring(1), chipStyle));
          }
        }
        i = end;
        continue;
      }
    }

    final ch = text[i];

    // Image marker: `[ image N ]`
    if (ch == '[' && _imageMarkerPattern.hasMatch(text.substring(i))) {
      final m = _imageMarkerPattern.firstMatch(text.substring(i))!;
      final marker = m.group(0)!;
      segments.add(StyledTextSegment(marker, chipStyle));
      i += marker.length;
      continue;
    }

    // Skill chip: `$name`
    if (ch == r'$' &&
        (i == 0 || !isSkillNameChar(text[i - 1])) &&
        i + 1 < text.length &&
        isSkillNameChar(text[i + 1])) {
      var j = i + 1;
      while (j < text.length && isSkillNameChar(text[j])) {
        j++;
      }
      segments.add(StyledTextSegment(r'$', invisibleTrigger));
      segments.add(StyledTextSegment(text.substring(i + 1, j), chipStyle));
      i = j;
      continue;
    }

    // At-mention: `@path` (not preceded by identifier char). The
    // char directly after the `@` must be a non-space path char —
    // `@ ` is a literal at-sign, not a file mention.
    if (ch == '@' &&
        (i == 0 || !_isIdentifierChar(text[i - 1])) &&
        i + 1 < text.length &&
        _isPathChar(text[i + 1]) &&
        text[i + 1] != ' ') {
      var j = i + 1;
      while (j < text.length && _isPathChar(text[j])) {
        j++;
      }
      segments.add(StyledTextSegment('@', invisibleTrigger));
      segments.add(StyledTextSegment(text.substring(i + 1, j), chipStyle));
      i = j;
      continue;
    }

    // Session mention: `#<query>` (not preceded by identifier char).
    // The char directly after the `#` must not be a space — `# ` is
    // a literal hash, not a mention.
    if (ch == '#' &&
        (i == 0 || !_isIdentifierChar(text[i - 1])) &&
        i + 1 < text.length &&
        !isSessionMentionSpace(text[i + 1])) {
      var j = i + 1;
      while (j < text.length && !isSessionMentionTerminator(text[j])) {
        j++;
      }
      segments.add(StyledTextSegment('#', invisibleTrigger));
      segments.add(StyledTextSegment(text.substring(i + 1, j), chipStyle));
      i = j;
      continue;
    }

    // Regular text — collect until the next chip/marker.
    var j = i + 1;
    while (j < text.length) {
      if (chipAt(j) != null) break;
      if (text[j] == r'$' &&
          (j == 0 || !isSkillNameChar(text[j - 1])) &&
          j + 1 < text.length &&
          isSkillNameChar(text[j + 1])) {
        break;
      }
      if (text[j] == '@' &&
          (j == 0 || !_isIdentifierChar(text[j - 1])) &&
          j + 1 < text.length &&
          _isPathChar(text[j + 1]) &&
          text[j + 1] != ' ') {
        break;
      }
      if (text[j] == '#' &&
          (j == 0 || !_isIdentifierChar(text[j - 1])) &&
          j + 1 < text.length &&
          !isSessionMentionSpace(text[j + 1])) {
        break;
      }
      if (text[j] == '[' && _imageMarkerPattern.hasMatch(text.substring(j))) {
        break;
      }
      j++;
    }
    segments.add(StyledTextSegment(text.substring(i, j), baseStyle));
    i = j;
  }
  return segments;
}

bool _isIdentifierChar(String c) {
  if (c.isEmpty) return false;
  final cc = c.codeUnitAt(0);
  return (cc >= 0x30 && cc <= 0x39) || // 0-9
      (cc >= 0x41 && cc <= 0x5A) || // A-Z
      (cc >= 0x61 && cc <= 0x7A) || // a-z
      cc == 0x5F || // _
      cc == 0x2D; // -
}

bool _isPathChar(String c) {
  if (c.isEmpty) return false;
  final cc = c.codeUnitAt(0);
  return (cc >= 0x30 && cc <= 0x39) || // 0-9
      (cc >= 0x41 && cc <= 0x5A) || // A-Z
      (cc >= 0x61 && cc <= 0x7A) || // a-z
      cc == 0x5F || // _
      cc == 0x2D || // -
      cc == 0x2E || // .
      cc == 0x2F || // /
      cc == 0x20; // space (multi-word paths)
}
