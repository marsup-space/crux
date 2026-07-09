// Tests for the skill chip substitution utility.
//
// The substitution is the single place that converts a chat input
// (with `$<skill-name>` chips) into the user message that goes
// to the LLM. The `$` is stripped, the skill name stays in the
// prose, and the skill body is appended at the end with a
// `Skill: <name>` header.

import 'package:crux/src/services/skills/skill.dart';
import 'package:crux/src/utils/skill_chip_substitution.dart';
import 'package:test/test.dart';

SkillInfo _skill(String name, {String description = '', String body = ''}) {
  return SkillInfo(
    name: name,
    description: description,
    location: '/skills/$name/SKILL.md',
    baseDirectory: '/skills/$name',
    content: body,
  );
}

void main() {
  group('expandSkillChips — empty input', () {
    test('empty input → empty user message, no skills', () {
      final result = expandSkillChips(input: '', available: const []);
      expect(result.userMessage, '');
      expect(result.includedSkills, isEmpty);
      expect(result.includedSkillInfos, isEmpty);
    });
  });

  group('expandSkillChips — no available skills', () {
    test('input is passed through verbatim when no skills are available',
        () {
      final result = expandSkillChips(
        input: r'please review $pr-review by EOD',
        available: const [],
      );
      expect(result.userMessage, r'please review $pr-review by EOD');
      expect(result.includedSkills, isEmpty);
    });

    test('unknown dollar tokens are kept as literal text', () {
      // A `$<unknown-skill>` chip is left untouched — the
      // user might be typing a skill that was removed, or
      // referring to a literal `$` amount.
      final result = expandSkillChips(
        input: r'cost is $50 today',
        available: const [],
      );
      expect(result.userMessage, r'cost is $50 today');
    });
  });

  group('expandSkillChips — single chip', () {
    test('strips the leading dollar and keeps the name in prose', () {
      final prReview = _skill('pr-review', body: 'Procedure:\n1. Read diff');
      final result = expandSkillChips(
        input: r'please review $pr-review by EOD',
        available: [prReview],
      );
      expect(result.userMessage, startsWith('please review pr-review by EOD'));
      expect(result.userMessage, isNot(contains(r'$')));
    });

    test('appends the skill body with a `Skill: <name>` header', () {
      final prReview = _skill('pr-review', body: 'Procedure:\n1. Read diff');
      final result = expandSkillChips(
        input: r'please review $pr-review by EOD',
        available: [prReview],
      );
      expect(result.userMessage, contains('\n\nSkill: pr-review\n'));
      expect(result.userMessage, contains('Procedure:'));
      expect(result.userMessage, contains('1. Read diff'));
    });

    test('records the included skill in includedSkills', () {
      final prReview = _skill('pr-review', body: 'x');
      final result = expandSkillChips(
        input: r'$pr-review',
        available: [prReview],
      );
      expect(result.includedSkills, ['pr-review']);
      expect(result.includedSkillInfos, [prReview]);
    });
  });

  group('expandSkillChips — multiple chips', () {
    test('appends all bodies in chip order, separated by blank lines', () {
      final prReview = _skill('pr-review', body: 'PR body');
      final secAudit = _skill('security-audit', body: 'SEC body');
      final result = expandSkillChips(
        input: r'check $pr-review and $security-audit',
        available: [prReview, secAudit],
      );

      // Display text: `$` stripped, names kept.
      expect(result.userMessage, startsWith('check pr-review and security-audit'));

      // Bodies appended in order, each with its own header.
      expect(result.userMessage, contains('Skill: pr-review\nPR body'));
      expect(result.userMessage, contains('Skill: security-audit\nSEC body'));
      // Order: pr-review comes before security-audit in the
      // appended block (matches chip order in the input).
      final prIdx = result.userMessage.indexOf('Skill: pr-review');
      final secIdx = result.userMessage.indexOf('Skill: security-audit');
      expect(prIdx, lessThan(secIdx));

      expect(result.includedSkills, ['pr-review', 'security-audit']);
    });

    test('chips in reverse input order come out in input order (not name order)',
        () {
      final a = _skill('a', body: 'A body');
      final b = _skill('b', body: 'B body');
      final result = expandSkillChips(
        input: r'$b and $a',
        available: [a, b],
      );
      expect(result.includedSkills, ['b', 'a']);
      final aIdx = result.userMessage.indexOf('Skill: a');
      final bIdx = result.userMessage.indexOf('Skill: b');
      expect(bIdx, lessThan(aIdx));
    });
  });

  group('expandSkillChips — non-chip dollar tokens', () {
    test('leaves a 50-dollar literal alone (no skill named 50)', () {
      final prReview = _skill('pr-review', body: 'PR');
      final result = expandSkillChips(
        input: r'cost is $50 today',
        available: [prReview],
      );
      expect(result.userMessage, contains(r'$50'));
      expect(result.includedSkills, isEmpty);
    });

    test('rejects a chip whose name is followed by more name chars', () {
      // `$pr-reviewfoo` is not a complete chip — the chars
      // after the name are still skill-name chars.
      final prReview = _skill('pr-review', body: 'PR');
      final result = expandSkillChips(
        input: r'$pr-reviewfoo',
        available: [prReview],
      );
      expect(result.userMessage, r'$pr-reviewfoo');
      expect(result.includedSkills, isEmpty);
    });

    test('rejects a chip preceded by a skill-name char', () {
      final prReview = _skill('pr-review', body: 'PR');
      final result = expandSkillChips(
        input: r'foo$pr-review',
        available: [prReview],
      );
      expect(result.userMessage, r'foo$pr-review');
    });
  });

  group('expandSkillChips — body trim', () {
    test('trims leading and trailing whitespace from the body', () {
      final prReview = _skill(
        'pr-review',
        body: '\n\n  Procedure body.  \n\n',
      );
      final result = expandSkillChips(
        input: r'$pr-review',
        available: [prReview],
      );
      // No leading/trailing blank lines around the body block.
      expect(result.userMessage, contains('Skill: pr-review\nProcedure body.'));
    });
  });
}
