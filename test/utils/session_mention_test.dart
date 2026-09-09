import 'package:crux/src/models/session.dart';
import 'package:crux/src/utils/session_mention.dart';
import 'package:test/test.dart';

void main() {
  group('findActiveSessionMention — basic shape', () {
    test('just `#` at the cursor is an active mention with empty query', () {
      final pos = findActiveSessionMention('#', 1);
      expect(pos, isNotNull);
      expect(pos!.hashOffset, 0);
      expect(pos.queryStart, 1);
      expect(pos.cursor, 1);
      expect(pos.query, '');
    });

    test('`#foo` after the `o` is an active mention', () {
      final pos = findActiveSessionMention('#foo', 4);
      expect(pos, isNotNull);
      expect(pos!.hashOffset, 0);
      expect(pos.query, 'foo');
    });

    test('`#123` matches a numeric id query', () {
      final pos = findActiveSessionMention('#123', 4);
      expect(pos, isNotNull);
      expect(pos!.query, '123');
    });

    test('no `#` in the text → null', () {
      expect(findActiveSessionMention('hello world', 11), isNull);
    });

    test('empty text → null', () {
      expect(findActiveSessionMention('', 0), isNull);
    });

    test('cursor at 0 → null', () {
      expect(findActiveSessionMention('#foo', 0), isNull);
    });
  });

  group('findActiveSessionMention — space directly after #', () {
    test('`# ` (space directly after) is NOT a mention', () {
      expect(findActiveSessionMention('# ', 2), isNull);
    });

    test('`#\t` (tab directly after) is NOT a mention', () {
      expect(findActiveSessionMention('#\t', 2), isNull);
    });

    test('` # ` mid-sentence is NOT a mention', () {
      expect(findActiveSessionMention('look at # here', 13), isNull);
    });
  });

  group('findActiveSessionMention — spaces inside the query', () {
    test('space inside a multi-word title keeps the mention', () {
      final pos = findActiveSessionMention('#my session title', 18);
      expect(pos, isNotNull);
      expect(pos!.hashOffset, 0);
      expect(pos.query, 'my session title');
    });

    test('trailing space after a title word keeps the mention', () {
      final pos = findActiveSessionMention('#my ', 4);
      expect(pos, isNotNull);
      expect(pos!.query, 'my ');
    });

    test('mid-sentence mention with a space inside', () {
      final pos = findActiveSessionMention('see #my session', 16);
      expect(pos, isNotNull);
      expect(pos!.hashOffset, 4);
      expect(pos.query, 'my session');
    });
  });

  group('findActiveSessionMention — identifier rejection', () {
    test('`foo#123` is not a mention (identifier before #)', () {
      expect(findActiveSessionMention('foo#123', 7), isNull);
    });

    test('` #foo` *is* a mention (space before #)', () {
      final pos = findActiveSessionMention(' #foo', 5);
      expect(pos, isNotNull);
      expect(pos!.hashOffset, 1);
      expect(pos.query, 'foo');
    });
  });

  group('findActiveSessionMention — punctuation terminators', () {
    test('comma after the # ends the mention', () {
      expect(findActiveSessionMention('#foo,', 5), isNull);
    });

    test('semicolon after the # ends the mention', () {
      expect(findActiveSessionMention('#foo;', 5), isNull);
    });

    test('paren after the # ends the mention', () {
      expect(findActiveSessionMention('#foo)', 5), isNull);
    });

    test('mention only activates for the latest #', () {
      final pos = findActiveSessionMention('#a and #b', 9);
      expect(pos, isNotNull);
      expect(pos!.hashOffset, 7);
      expect(pos.query, 'b');
    });
  });

  group('rankSessionMentions', () {
    Session session(int id, String title, {DateTime? archivedAt}) =>
        Session(id: id, title: title, archivedAt: archivedAt);

    test('empty query returns every session, non-archived first', () {
      final archived = session(3, 'Old', archivedAt: DateTime(2020));
      final active = session(1, 'New');
      final ranked = rankSessionMentions([archived, active], '');
      expect(ranked.first.session.id, 1);
      expect(ranked.last.session.id, 3);
    });

    test('archived session with same title ranks below non-archived', () {
      final active = session(1, 'Build a TUI chat app');
      final archived = session(
        3,
        'Build a TUI chat app',
        archivedAt: DateTime(2020),
      );
      final ranked = rankSessionMentions([archived, active], 'Build a TUI');
      expect(ranked.first.session.id, 1);
      expect(ranked.last.session.id, 3);
    });

    test('matching by id surfaces the session', () {
      final a = session(12, 'Some unrelated title');
      final b = session(7, 'Another title');
      final ranked = rankSessionMentions([a, b], '12');
      expect(ranked.first.session.id, 12);
    });

    test('archived session is still included (not dropped)', () {
      final archived = session(3, 'Archived Thing', archivedAt: DateTime(2020));
      final ranked = rankSessionMentions([archived], 'Archived');
      expect(ranked, hasLength(1));
      expect(ranked.first.session.id, 3);
      expect(ranked.first.isArchived, isTrue);
    });
  });

  group('rewriteSessionMentionsFromChips', () {
    test('rewrites a `#<id>` chip to `ses://<id>`', () {
      expect(
        rewriteSessionMentionsFromChips('#123', [
          const MentionChip(start: 0, content: '#123'),
        ]),
        'ses://123',
      );
    });

    test('rewrites a `#<id>:<title>` chip and drops the title', () {
      expect(
        rewriteSessionMentionsFromChips('#123:Build a TUI chat app', [
          const MentionChip(start: 0, content: '#123:Build a TUI chat app'),
        ]),
        'ses://123',
      );
    });

    test('rewrites a mid-sentence chip', () {
      expect(
        rewriteSessionMentionsFromChips('fix in #123 now', [
          const MentionChip(start: 7, content: '#123'),
        ]),
        'fix in ses://123 now',
      );
    });

    test('rewrites multiple chips', () {
      expect(
        rewriteSessionMentionsFromChips('#12 and #345', [
          const MentionChip(start: 0, content: '#12'),
          const MentionChip(start: 8, content: '#345'),
        ]),
        'ses://12 and ses://345',
      );
    });

    test('leaves a chip whose content no longer matches the text', () {
      expect(
        rewriteSessionMentionsFromChips('changed text', [
          const MentionChip(start: 0, content: '#123'),
        ]),
        'changed text',
      );
    });

    test('ignores non-session chips', () {
      expect(
        rewriteSessionMentionsFromChips('@lib/main.dart', [
          const MentionChip(start: 0, content: '@lib/main.dart'),
        ]),
        '@lib/main.dart',
      );
    });
  });

  group('describeRelativeTime', () {
    test('recent, hours, days', () {
      final now = DateTime(2026, 1, 10, 12, 0, 0);
      expect(describeRelativeTime(now, now: now), 'just now');
      expect(
        describeRelativeTime(
          now.subtract(const Duration(minutes: 5)),
          now: now,
        ),
        '5m ago',
      );
      expect(
        describeRelativeTime(now.subtract(const Duration(hours: 3)), now: now),
        '3h ago',
      );
      expect(
        describeRelativeTime(now.subtract(const Duration(days: 3)), now: now),
        '3d ago',
      );
    });
  });
}
