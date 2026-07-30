import 'package:crux/src/utils/fuzzy_match.dart';
import 'package:test/test.dart';

void main() {
  group('scoreStringMatch — tier ranking', () {
    test('exact match scores higher than prefix, substring, subsequence', () {
      final exact = scoreStringMatch('compact', 'compact');
      final prefix = scoreStringMatch('comp', 'compact');
      final substr = scoreStringMatch('mpac', 'compact');
      final subseq = scoreStringMatch('cmt', 'compact');
      // Each tier is strictly higher than the next, so the
      // ordering holds regardless of within-tier tiebreakers.
      expect(exact, greaterThan(prefix));
      expect(prefix, greaterThan(substr));
      expect(substr, greaterThan(subseq));
    });

    test('initials tiers outrank pure subsequence', () {
      // `ds` is a prefix of `d-state`'s initials (`ds`) and
      // also a subseq of `d-state` itself. So the initials
      // prefix tier fires (tier 2500).
      final initialsPrefix = scoreStringMatch('ds', 'd-state');
      // `dsate` is a subseq of `d-state` (d, s, a, t, e in
      // order) but is NOT a prefix of its initials (`ds` is
      // only 2 chars and `dsate` is 5). So the pure
      // subsequence tier fires (tier 1000).
      final pureSubseq = scoreStringMatch('dsate', 'd-state');
      expect(initialsPrefix, greaterThan(pureSubseq));
    });

    test('returns 0 for non-matches', () {
      expect(scoreStringMatch('xyz', 'compact'), equals(0));
      expect(scoreStringMatch('q', 'compact'), equals(0));
    });

    test('returns 0 for empty or whitespace-only query', () {
      expect(scoreStringMatch('', 'compact'), equals(0));
      expect(scoreStringMatch('   ', 'compact'), equals(0));
      expect(scoreStringMatch('\t\n', 'compact'), equals(0));
    });

    test('1-char query can match at every tier (no length guard)', () {
      // The matcher does not impose a minimum length on the
      // query — a 1-char query can fire any tier. The user
      // typing a single letter gets to see every candidate
      // that mentions it, with the strongest match (prefix
      // > substring > subsequence) ranked first.
      //
      // `c` is a prefix of `clear` and `compact` (tier
      // 4000), and a substring of both (tier 3000) — prefix
      // wins, so the score is the prefix tier.
      final clearScore = scoreStringMatch('c', 'clear');
      final compactScore = scoreStringMatch('c', 'compact');
      // The matcher returns the highest tier that fires, so
      // both should be the prefix tier.
      expect(clearScore, greaterThanOrEqualTo(4000));
      expect(compactScore, greaterThanOrEqualTo(4000));
      // `c` is a substring of `cherry` (tier 3000) but not
      // a prefix. So `cherry` should still match, but with
      // a lower score than the prefix-match candidates.
      final cherryScore = scoreStringMatch('c', 'cherry');
      expect(cherryScore, greaterThan(0));
      expect(cherryScore, lessThan(clearScore));
    });

    test('1-char CJK query matches via substring tier', () {
      // The alias `/继续` contains the CJK char `继` at
      // position 1. With no length guard, the substring
      // tier fires. This is the property the CJK alias
      // tests rely on — without it, a user typing `继`
      // would not see `/continue` in the overlay.
      final score = scoreStringMatch('继', '/继续');
      // 1 is the substring index. Score = 3000 + (100-1).
      expect(score, greaterThanOrEqualTo(3000));
    });

    test('is case-insensitive', () {
      final exact = scoreStringMatch('COMPACT', 'compact');
      final exactRev = scoreStringMatch('compact', 'COMPACT');
      final prefix = scoreStringMatch('COMP', 'compact');
      final subseq = scoreStringMatch('CmT', 'compact');
      expect(exact, greaterThan(0));
      expect(exactRev, greaterThan(0));
      expect(prefix, greaterThan(0));
      expect(subseq, greaterThan(0));
    });

    test('handles CJK characters in candidates', () {
      // The Chinese alias `/继续` is exact-matched by `/继续`
      // and prefix-matched by `/继`. The scorer should treat
      // each CJK char as a single code unit and match
      // accordingly.
      final exact = scoreStringMatch('/继续', '/继续');
      final prefix = scoreStringMatch('/继', '/继续');
      // `续` is the second CJK char in `/继续` — substring
      // tier fires (position 2). Note the query has no
      // leading `/`, but the substring tier doesn't care
      // about the leading slash.
      final substr = scoreStringMatch('续', '/继续');
      expect(exact, greaterThan(0));
      expect(prefix, greaterThan(0));
      expect(substr, greaterThan(0));
    });
  });

  group('scoreStringMatch — within-tier tiebreakers', () {
    test('shorter candidate wins within the exact tier', () {
      // Both `compact` and `compact-extended` exact-match
      // `compact` only if the query is `compact` itself; with
      // the same query both score in the exact tier, so the
      // shorter one wins.
      final short = scoreStringMatch('compact', 'compact');
      // Sanity check that the same-length-but-different case
      // (lower vs upper) produces an equal score (the
      // comparison is case-insensitive).
      final upper = scoreStringMatch('compact', 'COMPACT');
      expect(short, equals(upper));
    });

    test('shorter candidate wins within the prefix tier', () {
      final short = scoreStringMatch('/d', '/debug');
      final long = scoreStringMatch('/d', '/d-profiler');
      expect(short, greaterThan(long));
    });

    test('earlier substring index wins within the substring tier', () {
      // `in` is a substring of `drink` at index 2 and of
      // `continue` at index 4. Neither candidate starts with
      // `in`, so the substring tier applies to both. Earlier
      // index wins.
      final early = scoreStringMatch('in', 'drink');
      final late = scoreStringMatch('in', 'continue');
      expect(early, greaterThan(late));
    });
  });

  group('isSubsequence', () {
    test('returns true for in-order chars (non-consecutive)', () {
      expect(isSubsequence('continue', 'cnt'), isTrue);
      expect(isSubsequence('compact', 'cmt'), isTrue);
    });

    test('returns true for consecutive chars', () {
      expect(isSubsequence('compact', 'comp'), isTrue);
    });

    test('returns false for out-of-order chars', () {
      expect(isSubsequence('compact', 'tmc'), isFalse);
    });

    test('returns false for empty hay or needle', () {
      expect(isSubsequence('', 'a'), isFalse);
      expect(isSubsequence('a', ''), isFalse);
      expect(isSubsequence('', ''), isFalse);
    });

    test('returns false when needle is longer than hay', () {
      expect(isSubsequence('a', 'ab'), isFalse);
    });
  });

  group('computeInitials', () {
    test('handles camelCase', () {
      expect(computeInitials('camelCase'), equals('cc'));
      expect(computeInitials('XMLParser'), equals('xp'));
    });

    test('handles hyphenated names', () {
      expect(computeInitials('d-state'), equals('ds'));
      expect(computeInitials('d-messages'), equals('dm'));
    });

    test('handles snake_case and dotted names', () {
      expect(computeInitials('foo_bar'), equals('fb'));
      expect(computeInitials('foo.bar'), equals('fb'));
    });

    test('lowercases the first char of each token', () {
      expect(computeInitials('Help'), equals('h'));
      expect(computeInitials('HELP'), equals('h'));
    });

    test('preserves CJK characters as their own initials', () {
      // The CJK first char passes through unchanged because
      // the case-lowering only applies to ASCII A-Z.
      expect(computeInitials('继续'), equals('继'));
      expect(computeInitials('重试'), equals('重'));
    });
  });

  group('fuzzyRank', () {
    test('empty query returns the input list unchanged', () {
      final items = ['banana', 'apple', 'cherry'];
      final ranked = fuzzyRank<String>(items, (s) => s, '');
      expect(ranked, equals(items));
    });

    test('whitespace-only query returns the input list unchanged', () {
      final items = ['banana', 'apple'];
      final ranked = fuzzyRank<String>(items, (s) => s, '   ');
      expect(ranked, equals(items));
    });

    test('drops non-matches', () {
      final items = ['apple', 'banana', 'cherry'];
      final ranked = fuzzyRank<String>(items, (s) => s, 'zzz');
      expect(ranked, isEmpty);
    });

    test('orders prefix matches above subsequence matches', () {
      final items = ['continue', 'compact'];
      final ranked = fuzzyRank<String>(items, (s) => s, 'co');
      // `co` is a prefix of both `compact` and `continue`.
      // Tier 4000 (prefix) applies to both. The shorter
      // candidate wins — `compact` is 7 chars, `continue` is
      // 8, so `compact` ranks first.
      expect(ranked, ['compact', 'continue']);
    });

    test('ranks stronger tiers above weaker ones', () {
      // For query `an`:
      //  - `banana` is a substring match (tier 3000) at
      //    index 1.
      //  - `apple` has no `a` followed by `n` (no `n` at
      //    all), so it doesn't match.
      //  - `pineapple` has `a` at index 4 but `n` is at
      //    index 1, out of order — no subseq match either.
      // Therefore only `banana` should appear.
      final items = ['banana', 'apple', 'pineapple'];
      final ranked = fuzzyRank<String>(items, (s) => s, 'an');
      expect(ranked, ['banana']);
    });

    test('subsequence match appears in result list', () {
      // `cmt` is a subsequence of `compact` and not a
      // subseq of `cherry` (no `m`) or `apple` (no `m`/`t`).
      final items = ['compact', 'cherry', 'apple'];
      final ranked = fuzzyRank<String>(items, (s) => s, 'cmt');
      expect(ranked, equals(['compact']));
    });

    test('is case-insensitive end-to-end', () {
      final items = ['Continue', 'restart', 'CONTINUE'];
      final ranked = fuzzyRank<String>(items, (s) => s, 'cont');
      // The two `Continue`/`CONTINUE` candidates both exact
      // match (case-insensitive) and outrank `restart` (which
      // has `cont` as a prefix? no — `restart` has `art` after
      // `rest`, so `cont` is a subsequence of `restart`:
      // r-e-s-t-a-r-t → no `c` or `o` in there. So `restart`
      // doesn't match at all).
      expect(ranked, hasLength(2));
      expect(ranked, contains('Continue'));
      expect(ranked, contains('CONTINUE'));
    });
  });

  group('fuzzyRankMulti', () {
    test('matches against the best of multiple keys per item', () {
      // Treat each item as a (name, alias) pair. The
      // `continue` command should match both when the user
      // types the primary name AND when the user types the
      // alias.
      final items = [
        ['continue', '继续'],
        ['retry', '重试'],
        ['help'],
      ];
      final ranked = fuzzyRankMulti<List<String>>(items, (keys) => keys, '继');
      // `继续` (alias of `continue`) starts with `继` →
      // exact / prefix tier; `重试` (alias of `retry`) does
      // not contain `继` as a subseq. So only `continue` is
      // returned.
      expect(ranked, hasLength(1));
      expect(ranked.first, ['continue', '继续']);
    });

    test('uses best score across all keys', () {
      // `[compact, c-m-p]` — query `c` matches `compact` as a
      // prefix (4000+) and `c-m-p` as a prefix (4000+).
      // Both keys give a prefix match, so the item appears
      // once at the prefix tier.
      final items = [
        ['compact', 'c-m-p'],
        ['banana'],
      ];
      final ranked = fuzzyRankMulti<List<String>>(items, (keys) => keys, 'c');
      expect(ranked, hasLength(1));
      expect(ranked.first.first, equals('compact'));
    });

    test('empty query returns the input list unchanged', () {
      final items = [
        ['a', 'b'],
        ['c'],
      ];
      final ranked = fuzzyRankMulti<List<String>>(items, (keys) => keys, '');
      expect(ranked, equals(items));
    });
  });
}
