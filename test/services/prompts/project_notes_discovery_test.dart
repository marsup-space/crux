import 'dart:io';

import 'package:crux/src/services/prompts/project_notes_discovery.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempRoot;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('crux_proj_notes_');
  });

  tearDown(() {
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  group('discoverProjectNotes', () {
    test('returns null when no project notes exist anywhere', () {
      // tempRoot exists but is empty.
      final result = discoverProjectNotes(
        cwd: tempRoot.path,
        worktree: tempRoot.path,
      );
      expect(result, isNull);
    });

    test('finds AGENTS.md in cwd', () {
      File(p.join(tempRoot.path, 'AGENTS.md'))
          .writeAsStringSync('Use bun not npm.');

      final result = discoverProjectNotes(
        cwd: tempRoot.path,
        worktree: tempRoot.path,
      );

      expect(result, isNotNull);
      expect(result, contains('Instructions from:'));
      expect(result, contains('AGENTS.md'));
      expect(result, contains('Use bun not npm.'));
    });

    test('finds CLAUDE.md in cwd when AGENTS.md is absent', () {
      File(p.join(tempRoot.path, 'CLAUDE.md'))
          .writeAsStringSync('Prefer functional style.');

      final result = discoverProjectNotes(
        cwd: tempRoot.path,
        worktree: tempRoot.path,
      );

      expect(result, isNotNull);
      expect(result, contains('CLAUDE.md'));
      expect(result, contains('Prefer functional style.'));
    });

    test('mtime tiebreaker: when both exist in the same dir, newer wins',
        () {
      // Write AGENTS.md first, then CLAUDE.md a beat later. CLAUDE.md
      // should win because it has the newer mtime.
      final agents =
          File(p.join(tempRoot.path, 'AGENTS.md'))..writeAsStringSync('A');
      sleep(const Duration(milliseconds: 50));
      final claude =
          File(p.join(tempRoot.path, 'CLAUDE.md'))..writeAsStringSync('C');

      final result = discoverProjectNotes(
        cwd: tempRoot.path,
        worktree: tempRoot.path,
      );

      expect(result, isNotNull);
      expect(result, contains(claude.path));
      expect(result, contains('C'));
      expect(result, isNot(contains(agents.path)));
    });

    test('mtime tiebreaker: when AGENTS.md is the newer, AGENTS.md wins',
        () {
      // Write CLAUDE.md first, then AGENTS.md a beat later. AGENTS.md
      // should win.
      final claude =
          File(p.join(tempRoot.path, 'CLAUDE.md'))..writeAsStringSync('C');
      sleep(const Duration(milliseconds: 50));
      final agents =
          File(p.join(tempRoot.path, 'AGENTS.md'))..writeAsStringSync('A');

      final result = discoverProjectNotes(
        cwd: tempRoot.path,
        worktree: tempRoot.path,
      );

      expect(result, isNotNull);
      expect(result, contains(agents.path));
      expect(result, contains('A'));
      expect(result, isNot(contains(claude.path)));
    });

    test('first match wins walking up: a deeper file beats a higher one',
        () {
      // Create a worktree-like structure: <root>/<sub>/AGENTS.md AND
      // <root>/AGENTS.md. cwd is <root>/<sub>. The deeper one should
      // win because the walker stops at the first match.
      final root = tempRoot.path;
      final sub = Directory(p.join(root, 'sub'))..createSync();
      File(p.join(root, 'AGENTS.md')).writeAsStringSync('root instructions');
      File(p.join(sub.path, 'AGENTS.md'))
          .writeAsStringSync('sub instructions');

      final result = discoverProjectNotes(
        cwd: sub.path,
        worktree: root,
      );

      expect(result, contains('sub instructions'));
      expect(result, isNot(contains('root instructions')));
    });

    test('appends crux-addition.md when present in cwd', () {
      File(p.join(tempRoot.path, 'AGENTS.md'))
          .writeAsStringSync('AGENTS content');
      File(p.join(tempRoot.path, 'crux-addition.md'))
          .writeAsStringSync('Crux-specific addendum');

      final result = discoverProjectNotes(
        cwd: tempRoot.path,
        worktree: tempRoot.path,
      );

      expect(result, isNotNull);
      expect(result, contains('AGENTS content'));
      expect(result, contains('---'));
      expect(result, contains('Crux-specific addendum'));
      expect(result, contains('crux-addition.md'));
    });

    test('returns only crux-addition.md when no AGENTS/CLAUDE exists', () {
      File(p.join(tempRoot.path, 'crux-addition.md'))
          .writeAsStringSync('Standalone addendum');

      final result = discoverProjectNotes(
        cwd: tempRoot.path,
        worktree: tempRoot.path,
      );

      expect(result, isNotNull);
      expect(result, contains('Standalone addendum'));
      expect(result, contains('crux-addition.md'));
      expect(result, isNot(contains('---')));
    });

    test('closer crux-addition.md wins over higher one', () {
      // <root>/<sub>/crux-addition.md AND <root>/crux-addition.md.
      // cwd is <root>/<sub>. The closer one should win.
      final root = tempRoot.path;
      final sub = Directory(p.join(root, 'sub'))..createSync();
      File(p.join(root, 'crux-addition.md'))
          .writeAsStringSync('root addendum');
      File(p.join(sub.path, 'crux-addition.md'))
          .writeAsStringSync('sub addendum');

      final result = discoverProjectNotes(
        cwd: sub.path,
        worktree: root,
      );

      expect(result, contains('sub addendum'));
      expect(result, isNot(contains('root addendum')));
    });

    test('treats empty files as not present', () {
      File(p.join(tempRoot.path, 'AGENTS.md')).writeAsStringSync('   \n\n');
      File(p.join(tempRoot.path, 'crux-addition.md')).writeAsStringSync('');

      final result = discoverProjectNotes(
        cwd: tempRoot.path,
        worktree: tempRoot.path,
      );

      expect(result, isNull);
    });

    test('does not walk above worktree boundary', () {
      // File inside tempRoot, but worktree is a *deeper* directory.
      // The walker should not include tempRoot in the search.
      final worktree = Directory(p.join(tempRoot.path, 'worktree'))
        ..createSync();
      File(p.join(tempRoot.path, 'AGENTS.md'))
          .writeAsStringSync('OUTSIDE WORKTREE');

      final result = discoverProjectNotes(
        cwd: worktree.path,
        worktree: worktree.path,
      );

      expect(result, isNull);
    });
  });
}

void sleep(Duration d) {
  // Avoid pulling in dart:async for a single use. busy-wait is fine
  // in a test helper where we need real wall-clock time to elapse
  // for mtime resolution.
  final end = DateTime.now().add(d);
  while (DateTime.now().isBefore(end)) {
    // spin
  }
}
