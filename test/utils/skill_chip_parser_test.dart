// Tests for the skill chip parser.
//
// Two surfaces covered:
//   1. findActiveSkillChip — used by the picker to detect the
//      in-progress `dollar<query>` the user is typing at the cursor.
//   2. findAllSkillChips — used by the submit pipeline to find
//      complete `dollar<skill-name>` chips in the final text.
//
// The parser is a pure function: same inputs always produce the
// same output. These tests pin the exact behavior so a refactor
// can't silently change what counts as a "chip".
//
// (Note: this file deliberately avoids putting the dollar sign
// in single-quoted string literals — Dart interprets `$` as the
// start of an interpolation even inside a backticked word. Raw
// strings — `r'...'` — are used wherever the parser input is
// itself a literal dollar-token.)

import 'package:crux/src/utils/skill_chip_parser.dart';
import 'package:test/test.dart';

void main() {
  group('findActiveSkillChip — basic shape', () {
    test('just dollar at the cursor is an active chip with empty query', () {
      final pos = findActiveSkillChip(r'$', 1);
      expect(pos, isNotNull);
      expect(pos!.dollarOffset, 0);
      expect(pos.queryStart, 1);
      expect(pos.cursor, 1);
      expect(pos.query, '');
    });

    test('dollar-foo after the o is an active chip with query foo', () {
      final pos = findActiveSkillChip(r'$foo', 4);
      expect(pos, isNotNull);
      expect(pos!.query, 'foo');
      expect(pos.dollarOffset, 0);
    });

    test('dollar-pr-review is a valid in-progress chip', () {
      final pos = findActiveSkillChip(r'$pr-review', 10);
      expect(pos, isNotNull);
      expect(pos!.query, 'pr-review');
    });

    test(
      'dollar-pr_review is rejected — underscore is not a skill-name char',
      () {
        // Skill names match `[a-z0-9-]`. Underscore is a
        // common-but-wrong habit; the parser rejects it.
        final pos = findActiveSkillChip(r'$pr_review', 10);
        expect(pos, isNull);
      },
    );

    test('dollar-PrReview is rejected — uppercase is not allowed', () {
      final pos = findActiveSkillChip(r'$PrReview', 9);
      expect(pos, isNull);
    });

    test('no dollar in the text returns null', () {
      expect(findActiveSkillChip('hello world', 11), isNull);
    });

    test('empty text returns null', () {
      expect(findActiveSkillChip('', 0), isNull);
    });

    test('cursor at 0 returns null', () {
      expect(findActiveSkillChip(r'$foo', 0), isNull);
    });
  });

  group('findActiveSkillChip — in-the-middle of a word', () {
    test('foo-dollar-bar — the dollar-bar part is an active chip', () {
      // The parser does not reject chips that begin in the
      // middle of a word: a chip in `foo$bar` is just the
      // trailing `$bar` token. The picker will not find a
      // matching skill for `bar` and dismiss naturally.
      final pos = findActiveSkillChip(r'foo$bar', 7);
      expect(pos, isNotNull);
      expect(pos!.dollarOffset, 3);
      expect(pos.query, 'bar');
    });

    test('dollar-foo bar — space after name ends the chip', () {
      // The user has typed `$foo ` (with trailing space); the
      // cursor is past the space. The space is a terminator, so
      // there is no active chip — the user has moved on.
      expect(findActiveSkillChip(r'$foo bar', 8), isNull);
    });

    test('dollar-foo, — comma after name ends the chip', () {
      expect(findActiveSkillChip(r'$foo,', 5), isNull);
    });
  });

  group('findAllSkillChips — complete-chip detection', () {
    test('finds a single chip in plain prose', () {
      final matches = findAllSkillChips(r'please review $pr-review by EOD', {
        'pr-review',
      });
      expect(matches, hasLength(1));
      expect(matches.first.skillName, 'pr-review');
      expect(matches.first.dollarOffset, 14);
      expect(matches.first.nameEndOffset, 24);
    });

    test('finds multiple chips in any order', () {
      final matches = findAllSkillChips(
        r'audit with $security-audit and review via $pr-review',
        {'pr-review', 'security-audit'},
      );
      expect(matches, hasLength(2));
      expect(matches[0].skillName, 'security-audit');
      expect(matches[1].skillName, 'pr-review');
    });

    test('leaves a literal 50-dollar alone when no skill is named 50', () {
      final matches = findAllSkillChips(r'how much does it cost? $50', {
        'pr-review',
      });
      expect(matches, isEmpty);
    });

    test('rejects a chip whose name is a prefix of another word', () {
      // `$pr-reviewfoo` — the chars after the name are
      // skill-name chars, so the chip is not a complete match.
      // This stops the substitution from incorrectly expanding
      // a longer token that just happens to start with a
      // skill name.
      final matches = findAllSkillChips(r'$pr-reviewfoo', {'pr-review'});
      expect(matches, isEmpty);
    });

    test('rejects a chip preceded by a skill-name char', () {
      // `foo$pr-review` — the `$` is preceded by `o`, a
      // skill-name char, so the chip is rejected. (This is a
      // narrower rule than the at-mention parser, which also
      // rejects email-style; the at-mention email case doesn't
      // apply to skills because skill names don't have dots.)
      final matches = findAllSkillChips(r'foo$pr-review', {'pr-review'});
      expect(matches, isEmpty);
    });

    test('rejects a chip whose name is unknown', () {
      final matches = findAllSkillChips(r'$unknown-skill', {'pr-review'});
      expect(matches, isEmpty);
    });

    test('a lone dollar is not a chip', () {
      final matches = findAllSkillChips(r'$', {'pr-review'});
      expect(matches, isEmpty);
    });

    test('a dollar followed by a non-name char is not a chip', () {
      final matches = findAllSkillChips(r'$(', {'pr-review'});
      expect(matches, isEmpty);
    });
  });

  group('isSkillNameChar', () {
    test('letters, digits, and hyphen are skill-name chars', () {
      for (final c in ['a', 'z', '0', '9', '-']) {
        expect(
          isSkillNameChar(c),
          isTrue,
          reason: 'expected `$c` to be a name char',
        );
      }
    });

    test('uppercase, whitespace, punctuation are not', () {
      for (final c in ['A', 'Z', ' ', '\t', '_', '.', '/', '!', '?']) {
        expect(
          isSkillNameChar(c),
          isFalse,
          reason: 'expected `$c` to not be a name char',
        );
      }
    });

    test('empty string is not a name char', () {
      expect(isSkillNameChar(''), isFalse);
    });
  });
}
