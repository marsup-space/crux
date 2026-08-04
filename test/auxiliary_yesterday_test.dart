import 'package:test/test.dart';

import 'package:crux/src/models/message.dart';
import 'package:crux/src/models/session.dart';
import 'package:crux/src/services/auxiliary_service.dart';

Session _session(int id, {String title = '', DateTime? updatedAt}) => Session(
  id: id,
  title: title,
  updatedAt: updatedAt ?? DateTime(2026, 7, 31, 12),
);

Message _msg(
  String role,
  String content, {
  DateTime? createdAt,
  int sessionId = 1,
}) => Message(
  id: 0,
  sessionId: sessionId,
  role: role,
  content: content,
  createdAt: createdAt ?? DateTime(2026, 7, 31, 12),
);

void main() {
  // The yesterday window for these tests: all of 2026-07-31 (local).
  final yesterdayStart = DateTime(2026, 7, 31);
  final todayStart = DateTime(2026, 8, 1);
  bool inWindow(DateTime t) => !t.isBefore(yesterdayStart) && t.isBefore(todayStart);

  group('buildYesterdayDigest', () {
    test('keeps user asks whole and agent replies truncated', () {
      final longReply = 'a' * 500;
      final digest = buildYesterdayDigest(
        {
          _session(1, title: 'Fix the parser'): [
            _msg('user', 'please fix the parser'),
            _msg('assistant', longReply),
          ],
        },
        inWindow,
      );

      expect(digest, isNotNull);
      expect(digest, contains('## Fix the parser'));
      expect(digest, contains('user: please fix the parser'));
      // Agent reply is truncated to 400 chars + an ellipsis.
      expect(digest, contains('agent: ${'a' * 400}…'));
      expect(digest, isNot(contains('a' * 401)));
    });

    test('drops tool, tool_call, and system roles', () {
      final digest = buildYesterdayDigest(
        {
          _session(1, title: 'Work'): [
            _msg('user', 'do a thing'),
            _msg('tool_call', 'bash ls'),
            _msg('tool', 'file1 file2'),
            _msg('assistant', 'done'),
          ],
        },
        inWindow,
      );

      expect(digest, contains('user: do a thing'));
      expect(digest, contains('agent: done'));
      expect(digest, isNot(contains('bash ls')));
      expect(digest, isNot(contains('file1 file2')));
    });

    test('excludes messages outside the yesterday window', () {
      final before = DateTime(2026, 7, 30, 23); // day before yesterday
      final digest = buildYesterdayDigest(
        {
          _session(1, title: 'Work'): [
            _msg('user', 'yesterday ask', createdAt: DateTime(2026, 7, 31, 10)),
            _msg('user', 'older ask', createdAt: before),
          ],
        },
        inWindow,
      );

      expect(digest, contains('yesterday ask'));
      expect(digest, isNot(contains('older ask')));
    });

    test('a session with no yesterday content is skipped entirely', () {
      final before = DateTime(2026, 7, 30, 12);
      final digest = buildYesterdayDigest(
        {
          _session(1, title: 'Old session'): [
            _msg('user', 'old ask', createdAt: before),
          ],
          _session(2, title: 'Active'): [
            _msg('user', 'fresh ask', createdAt: DateTime(2026, 7, 31, 9)),
          ],
        },
        inWindow,
      );

      expect(digest, isNot(contains('Old session')));
      expect(digest, contains('## Active'));
      expect(digest, contains('fresh ask'));
    });

    test('returns null when nothing has yesterday content', () {
      final before = DateTime(2026, 7, 30, 12);
      final digest = buildYesterdayDigest(
        {
          _session(1, title: 'Old'): [_msg('user', 'old', createdAt: before)],
        },
        inWindow,
      );
      expect(digest, isNull);
    });

    test('empty user/assistant content is skipped', () {
      final digest = buildYesterdayDigest(
        {
          _session(1, title: 'Work'): [
            _msg('user', '   '),
            _msg('assistant', ''),
            _msg('user', 'real ask'),
          ],
        },
        inWindow,
      );
      expect(digest, contains('real ask'));
      // Only the real ask line; no blank user:/agent: lines.
      expect(digest!.split('\n').where((l) => l == 'user: ').length, 0);
    });

    test('falls back to displayId when the title is empty', () {
      final digest = buildYesterdayDigest(
        {
          _session(7, title: ''): [_msg('user', 'ask', sessionId: 7)],
        },
        inWindow,
      );
      expect(digest, contains('## #7'));
    });
  });
}
