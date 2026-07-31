// Tests for [isUnresolvedSlashToken] — the classifier that decides
// whether a leading-`/` input is a real (or in-progress) slash command
// or just plain text that happens to start with a slash, like a pasted
// filesystem path.
//
// This guards the chat-input escape hatch: a pasted path such as
// `/Users/foo/file` must drop the input out of command mode so the user
// can prepend text and submit it as a normal message, while genuine
// command typing (`/he` → `/help`) keeps the picker alive.

import 'package:test/test.dart';

import 'package:crux/src/components/input_keys.dart';

void main() {
  group('isUnresolvedSlashToken', () {
    test('returns false for non-slash text', () {
      expect(isUnresolvedSlashToken('hello'), isFalse);
      expect(isUnresolvedSlashToken(''), isFalse);
      expect(isUnresolvedSlashToken('foo/bar'), isFalse);
    });

    test('returns false for a bare slash', () {
      expect(isUnresolvedSlashToken('/'), isFalse);
    });

    test('returns false for an exact registered command', () {
      expect(isUnresolvedSlashToken('/help'), isFalse);
      expect(isUnresolvedSlashToken('/model'), isFalse);
      expect(isUnresolvedSlashToken('/quit'), isFalse);
    });

    test('returns false for a command with arguments', () {
      expect(isUnresolvedSlashToken('/model kimi/k2'), isFalse);
      expect(isUnresolvedSlashToken('/rename my new title'), isFalse);
    });

    test('returns false for a prefix of a real command (mid-typing)', () {
      expect(isUnresolvedSlashToken('/he'), isFalse); // /help
      expect(isUnresolvedSlashToken('/m'), isFalse); // /model, /mo…
      expect(isUnresolvedSlashToken('/cont'), isFalse); // /continue
    });

    test('returns false for command aliases', () {
      expect(isUnresolvedSlashToken('/exit'), isFalse); // alias of /quit
      expect(isUnresolvedSlashToken('/重试'), isFalse); // alias of /retry
    });

    test('returns true for a pasted absolute path', () {
      expect(isUnresolvedSlashToken('/Users/foo/file.txt'), isTrue);
      expect(isUnresolvedSlashToken('/etc/passwd'), isTrue);
      expect(isUnresolvedSlashToken('/var/log/system.log'), isTrue);
    });

    test('returns true for a pasted path with trailing text', () {
      expect(isUnresolvedSlashToken('/Users/foo/file.txt some note'), isTrue);
    });

    test('returns true for a mistyped command-like token', () {
      // Not a command and not a prefix of any command.
      expect(isUnresolvedSlashToken('/zzz'), isTrue);
      expect(isUnresolvedSlashToken('/hellp'), isTrue);
    });
  });
}
