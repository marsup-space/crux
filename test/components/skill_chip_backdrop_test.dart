// Tests for `computeBackdropSegments` — the pure function that
// splits a line of text into the segments the SkillChipBackdrop
// widget renders on top of nocterm's TextField. The function is
// the testable core of the visual-chip UX; the widget itself is
// a thin render layer that consumes its output.
//
// The rules being locked in:
//   * Plain text segments have `background == null` — the
//     backdrop leaves the cell alone so the TextField's text
//     shows through.
//   * Chip segments have `background == chipBackground` — the
//     backdrop paints a colored band over those characters.
//   * If the cursor falls inside a chip, that chip is split
//     into pre-cursor + post-cursor so the TextField's cursor
//     character can show through the gap.
//   * The cursor cell itself is NEVER rendered (no segment
//     covers it) — that's the gap.
//
// We exercise the function with synthetic chip offsets so the
// tests don't depend on the discoverSkills filesystem walk.

import 'package:crux/src/components/skill_chip_backdrop.dart';
import 'package:crux/src/utils/skill_chip_parser.dart';
import 'package:nocterm/nocterm.dart' show Color;
import 'package:test/test.dart';

/// A real `Color` instance — the function under test only
/// stores the reference (it never reads color values), so any
/// `Color` works as the chip background.
final Color _chipBg = const Color(0x44475A);

SkillChipMatch _chip(int start, int end, String name) {
  return SkillChipMatch(
    dollarOffset: start,
    nameEndOffset: end,
    skillName: name,
  );
}

void main() {
  group('computeBackdropSegments — no chips', () {
    test('empty text returns no segments', () {
      final result = computeBackdropSegments(
        text: '',
        chips: const [],
        cursor: 0,
        chipBackground: _chipBg,
      );
      expect(result, isEmpty);
    });

    test('text with no chips returns a single transparent segment', () {
      final result = computeBackdropSegments(
        text: 'plain text',
        chips: const [],
        cursor: 5,
        chipBackground: _chipBg,
      );
      expect(result, hasLength(1));
      expect(result.first.text, 'plain text');
      expect(result.first.background, isNull);
    });
  });

  group('computeBackdropSegments — one chip', () {
    test('text with one chip and cursor before the chip', () {
      // "hello $pr-review world" — chip at [6, 16]
      final result = computeBackdropSegments(
        text: r'hello $pr-review world',
        chips: [_chip(6, 16, 'pr-review')],
        cursor: 2,
        chipBackground: _chipBg,
      );
      expect(result, hasLength(3));
      expect(result[0].text, 'hello ');
      expect(result[0].background, isNull);
      expect(result[1].text, r'$pr-review');
      expect(result[1].background, _chipBg);
      expect(result[2].text, ' world');
      expect(result[2].background, isNull);
    });

    test('cursor inside a chip splits it into pre + post', () {
      // "hi $pr-review ok" — chip at [3, 13). The cursor at
      // global position 5 lands on the 'r' inside "$pr-review"
      // (chipText[2]). The cell at the cursor is left as a gap;
      // the chip is split into the chars before ("$p") and the
      // chars after ("-review").
      final result = computeBackdropSegments(
        text: r'hi $pr-review ok',
        chips: [_chip(3, 13, 'pr-review')],
        cursor: 5,
        chipBackground: _chipBg,
      );
      expect(result, hasLength(4));
      expect(result[0].text, 'hi ');
      expect(result[0].background, isNull);
      expect(result[1].text, r'$p');
      expect(result[1].background, _chipBg);
      expect(result[2].text, '-review');
      expect(result[2].background, _chipBg);
      expect(result[3].text, ' ok');
      expect(result[3].background, isNull);
    });

    test('cursor at the first cell of a chip splits off the dollar', () {
      // Cursor lands on the '$' itself — the cell at the cursor
      // becomes a gap; the rest of the chip (just the name) is
      // post-cursor.
      final result = computeBackdropSegments(
        text: r'$foo',
        chips: [_chip(0, 4, 'foo')],
        cursor: 0,
        chipBackground: _chipBg,
      );
      // Segment: "foo" (chip, post-cursor) — the '$' at cursor=0
      // is the gap, so the backdrop renders "foo" with the chip
      // background, and the TextField's cursor character lands on
      // the dollar cell.
      expect(result, hasLength(1));
      expect(result[0].text, 'foo');
      expect(result[0].background, _chipBg);
    });

    test('cursor at the last cell of a chip keeps the chip whole minus the last char', () {
      // cursor=3 means the cell at index 3 is the gap; chip is
      // [0, 4) = "$foo" — the cell at index 3 is 'o', so the
      // chip segment becomes "$f" (chars 0..2).
      final result = computeBackdropSegments(
        text: r'$foo',
        chips: [_chip(0, 4, 'foo')],
        cursor: 3,
        chipBackground: _chipBg,
      );
      expect(result, hasLength(1));
      expect(result[0].text, r'$fo');
      expect(result[0].background, _chipBg);
    });
  });

  group('computeBackdropSegments — multiple chips', () {
    test('two chips with cursor outside both', () {
      // "x $a  $b y" — chips at [2, 4) and [6, 8)
      final result = computeBackdropSegments(
        text: r'x $a  $b y',
        chips: [_chip(2, 4, 'a'), _chip(6, 8, 'b')],
        cursor: 0,
        chipBackground: _chipBg,
      );
      // "x " + "$a" + "  " + "$b" + " y"
      expect(result, hasLength(5));
      expect(result[0].text, 'x ');
      expect(result[1].text, r'$a');
      expect(result[1].background, _chipBg);
      expect(result[2].text, '  ');
      expect(result[3].text, r'$b');
      expect(result[3].background, _chipBg);
      expect(result[4].text, ' y');
    });

    test('cursor at the start of the second chip splits it into just-post', () {
      // "x $a  $b y" — chips at [2, 4) and [6, 8). Cursor at
      // global position 6 lands exactly on the '$' of the
      // second chip. The split removes the '$' (gap) and
      // keeps 'b' as the post-cursor chip part. The trailing
      // ' y' is plain text (not part of the chip).
      final result = computeBackdropSegments(
        text: r'x $a  $b y',
        chips: [_chip(2, 4, 'a'), _chip(6, 8, 'b')],
        cursor: 6,
        chipBackground: _chipBg,
      );
      // Segments: 'x ' (plain) + '$a' (chip) + '  ' (plain) +
      // 'b' (chip, post-cursor part) + ' y' (plain).
      expect(result, hasLength(5));
      expect(result[0].text, 'x ');
      expect(result[0].background, isNull);
      expect(result[1].text, r'$a');
      expect(result[1].background, _chipBg);
      expect(result[2].text, '  ');
      expect(result[2].background, isNull);
      // The '$' at index 6 is the gap — it doesn't appear in
      // any segment.
      expect(result[3].text, 'b');
      expect(result[3].background, _chipBg);
      expect(result[4].text, ' y');
      expect(result[4].background, isNull);
    });
  });

  group('computeBackdropSegments — defensive', () {
    test('overlapping chips skip the second and render overlap as plain text', () {
      // This shouldn't happen in practice (the chip parser
      // dedups by name), but if it does, we don't want to
      // produce duplicate chip segments. The function skips
      // the second chip; the overlap region falls through to
      // the trailing-plain-text pass.
      final result = computeBackdropSegments(
        text: r'$a$b',
        chips: [_chip(0, 2, 'a'), _chip(1, 3, 'b')],
        cursor: 4,
        chipBackground: _chipBg,
      );
      // Segments: ('$a', chip) + ('$b', plain) — the second
      // chip was skipped, so its text is rendered as plain.
      expect(result, hasLength(2));
      expect(result[0].text, r'$a');
      expect(result[0].background, _chipBg);
      expect(result[1].text, r'$b');
      expect(result[1].background, isNull);
    });

    test('cursor at end of text after the last chip', () {
      final result = computeBackdropSegments(
        text: r'hi $foo',
        chips: [_chip(3, 7, 'foo')],
        cursor: 7,
        chipBackground: _chipBg,
      );
      // Cursor at the cell right after the chip — no splitting,
      // just "hi " + "$foo".
      expect(result, hasLength(2));
      expect(result[0].text, 'hi ');
      expect(result[1].text, r'$foo');
    });
  });
}
