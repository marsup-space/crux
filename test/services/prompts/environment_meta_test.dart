import 'dart:io';

import 'package:crux/src/services/prompts/environment_meta.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('buildEnvironmentMeta', () {
    test('renders the four expected fields', () {
      final started = DateTime.utc(2026, 1, 15, 10, 30, 0);
      final out = buildEnvironmentMeta(
        cwd: '/Users/test/proj',
        modelId: 'claude-opus-4-6',
        providerName: 'anthropic',
        contextSize: 200000,
        sessionStarted: started,
      );

      expect(out, contains('Working directory: /Users/test/proj'));
      expect(
        out,
        contains(
          'Model: claude-opus-4-6 (provider: anthropic, '
          'context: 200000 tokens)',
        ),
      );
      expect(out, contains('Session started: 2026-01-15T10:30:00.000Z'));
      expect(out, contains('stale by design'));
    });

    test('session-started timestamp is preserved across calls', () {
      // This is the cache-stability invariant: building env meta
      // twice with the same `sessionStarted` must produce the same
      // string byte-for-byte, so the model id and the "now" the
      // env reflects don't drift across turns.
      final started = DateTime.utc(2026, 1, 15, 10, 30, 0);
      final first = buildEnvironmentMeta(
        cwd: '/Users/test/proj',
        modelId: 'claude-opus-4-6',
        providerName: 'anthropic',
        contextSize: 200000,
        sessionStarted: started,
      );
      // Force the wall clock to move on; the function should still
      // report the original session-started timestamp.
      sleep(const Duration(milliseconds: 10));
      final second = buildEnvironmentMeta(
        cwd: '/Users/test/proj',
        modelId: 'claude-opus-4-6',
        providerName: 'anthropic',
        contextSize: 200000,
        sessionStarted: started,
      );
      expect(second, equals(first));
    });

    test('detects git repo when .git directory exists in cwd', () {
      final tempRoot = Directory.systemTemp.createTempSync('crux_env_git_');
      try {
        Directory(p.join(tempRoot.path, '.git')).createSync();
        final out = buildEnvironmentMeta(
          cwd: tempRoot.path,
          modelId: 'm',
          providerName: 'p',
          contextSize: 1,
          sessionStarted: DateTime.utc(2026, 1, 1),
        );
        expect(out, contains('Is directory a git repo: yes'));
      } finally {
        tempRoot.deleteSync(recursive: true);
      }
    });

    test('detects git repo when .git is a file (worktree)', () {
      final tempRoot = Directory.systemTemp.createTempSync('crux_env_git_');
      try {
        File(p.join(tempRoot.path, '.git')).writeAsStringSync('gitdir: x');
        final out = buildEnvironmentMeta(
          cwd: tempRoot.path,
          modelId: 'm',
          providerName: 'p',
          contextSize: 1,
          sessionStarted: DateTime.utc(2026, 1, 1),
        );
        expect(out, contains('Is directory a git repo: yes'));
      } finally {
        tempRoot.deleteSync(recursive: true);
      }
    });

    test('reports no git when .git is absent', () {
      final tempRoot = Directory.systemTemp.createTempSync('crux_env_nogit_');
      try {
        final out = buildEnvironmentMeta(
          cwd: tempRoot.path,
          modelId: 'm',
          providerName: 'p',
          contextSize: 1,
          sessionStarted: DateTime.utc(2026, 1, 1),
        );
        expect(out, contains('Is directory a git repo: no'));
      } finally {
        tempRoot.deleteSync(recursive: true);
      }
    });

    test('detects git in an ancestor directory', () {
      final tempRoot = Directory.systemTemp.createTempSync('crux_env_ances_');
      try {
        Directory(p.join(tempRoot.path, '.git')).createSync();
        final sub = Directory(p.join(tempRoot.path, 'a', 'b', 'c'))
          ..createSync(recursive: true);
        final out = buildEnvironmentMeta(
          cwd: sub.path,
          modelId: 'm',
          providerName: 'p',
          contextSize: 1,
          sessionStarted: DateTime.utc(2026, 1, 1),
        );
        expect(out, contains('Is directory a git repo: yes'));
      } finally {
        tempRoot.deleteSync(recursive: true);
      }
    });
  });
}

void sleep(Duration d) {
  final end = DateTime.now().add(d);
  while (DateTime.now().isBefore(end)) {
    // spin
  }
}
