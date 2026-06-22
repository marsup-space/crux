// Tests for the shell-tool fallback guard.
//
// The feature has three moving parts, each covered by a group below:
//
//   1. **Detector** — pure function that classifies a shell command
//      into a [ShellGuardKind] (`read` / `glob` / `grep` /
//      `codeSearch` / `none`) or returns null for shell-native
//      commands. Pinned patterns include:
//        * cat/head/tail/sed/wc → read
//        * ls/find/tree/du → glob
//        * grep/rg/ack → grep
//        * `rg "concept" | head` / `find … | head` → codeSearch
//        * bash/cmd/PowerShell verbs all covered (POSIX + Windows)
//        * env-var prefixes (`FOO=bar cat file`) handled
//        * heredocs / redirections (`cat <<EOF`, `cat < file`)
//          correctly skipped
//        * pipelines without a dedicated-tool verb (builds, git,
//          process control) return null
//
//   2. **Severity escalation** — `currentStreak → severity`
//      mapping (mild/firm/reject), pinned so the three-tier
//      escalation the user asked for never gets out of sync.
//
//   3. **Rendering** — the embedded reminder (mild/firm) and the
//      rejection body (reject) have stable, parseable shapes:
//        * embedded reminder wraps in tier-specific marker tag
//        * embedded reminder throws if called for the reject
//          tier (defensive — same contract as single-call hint)
//        * rejection body is the full output of a rejected call,
//          no marker tag, no embedded-reminder throw
//        * bubble label carries the ordinal (1st/2nd/3rd) + tier
//          verb (use/switch/blocked)
//
//   4. **End-to-end persistence** — given a session with a
//      tool round that triggered a violation, the chat service
//      persists a `shell_guard` row with the right
//      `parallelCount` (the post-call streak) and the canonical
//      label.

import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'package:crux/src/models/message.dart';
import 'package:crux/src/tools/shell_guard.dart';
import 'package:crux/src/storage/storage.dart';

// =============================================================================
// 1. Detector
// =============================================================================

void main() {
  group('detectShellGuard — POSIX (bash)', () {
    test('returns null for shell-native commands', () {
      // No violation verbs — pure builds / git / package managers
      // / process control. Must NOT trigger the guard.
      //
      // `ps -ef | grep node` and `env | grep PATH` are NOT in
      // this list even though they're arguably legitimate shell
      // patterns — the detector still flags them because `grep`
      // is in the violation set. See the dedicated test below.
      const commands = <String>[
        'git status',
        'git diff --stat',
        'flutter analyze && flutter test',
        'dart run bin/main.dart 2>&1 | tail -50',
        'npm install',
        'pip install requests',
        'dart pub add foo',
        'brew install ripgrep',
        'lsof -i :8080',
        'kill -9 1234',
        'echo "hello"',
        'pwd',
        'curl -sSL https://example.com | head',
        'which rg',
      ];
      for (final cmd in commands) {
        final v = detectShellGuard(
          cmd,
          isWindows: false,
          currentStreak: 0,
        );
        expect(v, isNull, reason: 'should not flag: "$cmd"');
      }
    });

    test('flags grep even in stdin-filtering pipelines (accepted false positive)',
        () {
      // `ps -ef | grep node` and `env | grep PATH` are the
      // canonical "filter output" patterns — the user wants to
      // narrow another command's output, not search file
      // contents. The detector still flags them as `grep`
      // because grep is in the violation set regardless of args.
      // Accepted false positive: the LLM just sees a mild-tier
      // reminder and can choose to ignore it.
      const cases = <String>[
        'ps -ef | grep node',
        'env | grep PATH',
        'flutter test 2>&1 | grep FAIL',
      ];
      for (final cmd in cases) {
        final v = detectShellGuard(
          cmd,
          isWindows: false,
          currentStreak: 0,
        );
        expect(v, isNotNull, reason: 'should flag: "$cmd"');
        expect(v!.kind, ShellGuardKind.grep, reason: 'cmd="$cmd"');
      }
    });

    test('skips grep when command starts with cd (chained workflow)', () {
      // The user's most common shell pattern: `cd /path && grep …`
      // The cd is setup, the grep is the actual work. The LLM
      // is doing chained shell work, not using bash as a fallback
      // for the grep tool. Skip the grep verdict.
      const cases = <String>[
        'cd /Users/developer/Projects/crux && grep -rn "TODO" lib/',
        'cd /path && grep "auth" src/',
        'cd /path && rg "TODO" lib/',
      ];
      for (final cmd in cases) {
        final v = detectShellGuard(
          cmd,
          isWindows: false,
          currentStreak: 0,
        );
        expect(v, isNull, reason: 'should not flag: "$cmd"');
      }
    });

    test('skips grep in multi-line shell scripts (verification workflow)', () {
      // The user's multi-line verification script example.
      // Splitting on newlines gives 4+ segments, all with the
      // first segment being `cd` (a shell-script verb). The grep
      // is one step in a larger workflow and should NOT trigger
      // the guard.
      final cmd = '''cd /Users/developer/Projects/crux
echo "=== Final check: any remaining semble_search references? ==="
grep -rn "semble_search\\|SembleSearchTool" lib test --include=*.dart 2>/dev/null
echo "(should be empty)"''';
      final v = detectShellGuard(
        cmd,
        isWindows: false,
        currentStreak: 0,
      );
      expect(v, isNull);
    });

    test('flags cat even when preceded by cd (cat is unambiguous)', () {
      // `cd /path && cat file` — the cat is a violation regardless
      // of the cd prefix. cat/head/ls are NOT exempt from the
      // shell-script leniency because they're unambiguously
      // about file inspection.
      final v = detectShellGuard(
        'cd /path && cat file.txt',
        isWindows: false,
        currentStreak: 0,
      );
      expect(v, isNotNull);
      expect(v!.kind, ShellGuardKind.read);
    });

    test('flags ls even when preceded by cd (ls is unambiguous)', () {
      final v = detectShellGuard(
        'cd /path && ls lib/',
        isWindows: false,
        currentStreak: 0,
      );
      expect(v, isNotNull);
      expect(v!.kind, ShellGuardKind.glob);
    });

    test('skips grep when command starts with echo', () {
      const cases = <String>[
        'echo "hello" && grep "foo" lib/',
        'echo "checking..." ; grep -r "TODO" .',
      ];
      for (final cmd in cases) {
        final v = detectShellGuard(
          cmd,
          isWindows: false,
          currentStreak: 0,
        );
        expect(v, isNull, reason: 'should not flag: "$cmd"');
      }
    });

    test('still flags grep when it is the FIRST segment (not in a script)',
        () {
      // `grep …` alone (no preceding cd/echo/etc.) IS a
      // bash+grep fallback — the LLM should have used the
      // `grep` tool. The shell-script leniency only kicks in
      // when the command starts with a shell-script verb.
      const cases = <String>[
        'grep -rn "TODO" lib/',
        'rg "auth" lib/',
        'grep foo && echo done', // echo is second, not first
      ];
      for (final cmd in cases) {
        final v = detectShellGuard(
          cmd,
          isWindows: false,
          currentStreak: 0,
        );
        expect(v, isNotNull, reason: 'should flag: "$cmd"');
        expect(v!.kind, ShellGuardKind.grep, reason: 'cmd="$cmd"');
      }
    });

    test('cat / head / tail / less → read', () {
      const cases = <String>[
        'cat lib/main.dart',
        'head -n 20 lib/main.dart',
        'tail -100 build.log',
        'less CHANGELOG.md',
        'more README.md',
        'bat pubspec.yaml',
      ];
      for (final cmd in cases) {
        final v = detectShellGuard(
          cmd,
          isWindows: false,
          currentStreak: 0,
        );
        expect(v, isNotNull, reason: 'should flag: "$cmd"');
        expect(v!.kind, ShellGuardKind.read, reason: 'cmd="$cmd"');
        expect(v.toolName, 'read', reason: 'cmd="$cmd"');
      }
    });

    test('sed -n / awk / cut / sort / uniq → read', () {
      const cases = <String>[
        'sed -n "100,120p" lib/main.dart',
        "awk '{print \$1}' data.txt",
        'cut -f1 -d, file.csv',
        'sort file.txt',
        'uniq input.txt',
      ];
      for (final cmd in cases) {
        final v = detectShellGuard(
          cmd,
          isWindows: false,
          currentStreak: 0,
        );
        expect(v, isNotNull, reason: 'should flag: "$cmd"');
        expect(v!.kind, ShellGuardKind.read, reason: 'cmd="$cmd"');
      }
    });

    test('ls / find / tree / du → glob', () {
      const cases = <String>[
        'ls lib/',
        'ls -la lib/',
        'find . -name "*.dart"',
        'tree lib/src',
        'du -sh build/',
      ];
      for (final cmd in cases) {
        final v = detectShellGuard(
          cmd,
          isWindows: false,
          currentStreak: 0,
        );
        expect(v, isNotNull, reason: 'should flag: "$cmd"');
        expect(v!.kind, ShellGuardKind.glob, reason: 'cmd="$cmd"');
        expect(v.toolName, 'glob', reason: 'cmd="$cmd"');
      }
    });

    test('grep / rg / ack / ag → grep', () {
      const cases = <String>[
        'grep -rn "TODO" lib/',
        'grep "auth" src/auth.ts',
        'rg "TODO|FIXME" lib/',
        'rg auth lib/',
        'ack "foo" src/',
        'ag pattern lib/',
      ];
      for (final cmd in cases) {
        final v = detectShellGuard(
          cmd,
          isWindows: false,
          currentStreak: 0,
        );
        expect(v, isNotNull, reason: 'should flag: "$cmd"');
        expect(v!.kind, ShellGuardKind.grep, reason: 'cmd="$cmd"');
        expect(v.toolName, 'grep', reason: 'cmd="$cmd"');
      }
    });

    test('rg/grep "concept" | head → semantic_search (NOT grep)', () {
      // Only rg/grep/ack (search verbs) trigger the semantic_search
      // anti-pattern. List verbs (ls/find/tree) + truncator fall
      // through to the verb classifier and are flagged as glob
      // — see the dedicated test below for those.
      const cases = <String>[
        'rg "auth" lib/ | head -10',
        'rg "auth" lib/ | head',
        'grep -r "auth" lib/ | head -20',
        'ack "foo" lib/ | tail -5',
      ];
      for (final cmd in cases) {
        final v = detectShellGuard(
          cmd,
          isWindows: false,
          currentStreak: 0,
        );
        expect(v, isNotNull, reason: 'should flag: "$cmd"');
        expect(v!.kind, ShellGuardKind.codeSearch, reason: 'cmd="$cmd"');
        expect(v.toolName, 'semantic_search', reason: 'cmd="$cmd"');
      }
    });

    test(
      'ls | head and find | head are flagged as glob (NOT semantic_search)',
      () {
        // `ls ... | head` and `find ... | head` are
        // list/truncate patterns, not code search. Mixing list
        // verbs into the semantic-search check produced false
        // positives on common verification scripts like
        // `ls -la build/ && echo '---' && binary --version | head -5`.
        const cases = <String>[
          'ls -la build/releases/crux-macos-arm64/ | head -5',
          'ls lib/ | head',
          'find . -name "*.dart" | head -30',
          'tree lib/src/ | head -20',
          'du -sh * | sort -h | head -5',
        ];
        for (final cmd in cases) {
          final v = detectShellGuard(
            cmd,
            isWindows: false,
            currentStreak: 0,
          );
          expect(v, isNotNull, reason: 'should flag: "$cmd"');
          expect(v!.kind, ShellGuardKind.glob, reason: 'cmd="$cmd"');
          expect(v.toolName, 'glob', reason: 'cmd="$cmd"');
        }
      },
    );

    test(
      'user\'s verification script (ls && echo && binary | head) → glob',
      () {
        // The exact command from the user's screenshot —
        // a verification script that lists build artifacts and
        // pipes the binary's --version output to head. The
        // detector correctly identifies it as a glob violation
        // (because of the leading `ls`), not a code-search
        // violation. The trailing `| head` doesn't change the
        // classification.
        const cmd =
            'ls -la build/releases/crux-macos-arm64/ && '
            "echo '---' && "
            'ls build/releases/crux-macos-arm64/bin/ && '
            "echo '---' && "
            'build/releases/crux-macos-arm64/bin/crux --version 2>&1 | head -5';
        final v = detectShellGuard(
          cmd,
          isWindows: false,
          currentStreak: 0,
        );
        expect(v, isNotNull);
        expect(v!.kind, ShellGuardKind.glob);
        expect(v.toolName, 'glob');
      },
    );

    test('wc / md5sum / file / stat / diff → read', () {
      const cases = <String>[
        'wc -l lib/main.dart',
        'md5sum pubspec.lock',
        'file README.md',
        'stat build/output.bin',
        'diff a.txt b.txt',
        'cmp a.bin b.bin',
      ];
      for (final cmd in cases) {
        final v = detectShellGuard(
          cmd,
          isWindows: false,
          currentStreak: 0,
        );
        expect(v, isNotNull, reason: 'should flag: "$cmd"');
        expect(v!.kind, ShellGuardKind.read, reason: 'cmd="$cmd"');
      }
    });

    test('env-var prefix is handled (FOO=bar cat file → read)', () {
      final v = detectShellGuard(
        'FOO=bar LANG=en_US cat lib/main.dart',
        isWindows: false,
        currentStreak: 0,
      );
      expect(v, isNotNull);
      expect(v!.kind, ShellGuardKind.read);
    });

    test('absolute-path verb is handled (/bin/cat foo → read)', () {
      final v = detectShellGuard(
        '/bin/cat lib/main.dart',
        isWindows: false,
        currentStreak: 0,
      );
      expect(v, isNotNull);
      expect(v!.kind, ShellGuardKind.read);
    });

    test('heredoc is NOT flagged (cat <<EOF …)', () {
      final v = detectShellGuard(
        'cat <<EOF > file.txt\nhello\nEOF',
        isWindows: false,
        currentStreak: 0,
      );
      // The first segment starts with `cat` but the next
      // character is `<` (the heredoc redirect). The detector
      // skips segments that start with `<`, so the violation
      // is not raised. (The verb IS still `cat` if you parse
      // past the redirect — but we deliberately skip these to
      // avoid flagging legitimate file-writing operations.)
      expect(v, isNull);
    });

    test('stdin redirect is NOT flagged (cat < file)', () {
      final v = detectShellGuard(
        'cat < some_pipe',
        isWindows: false,
        currentStreak: 0,
      );
      expect(v, isNull);
    });

    test('chained command picks first violation (cat x; ls y)', () {
      final v = detectShellGuard(
        'cat lib/a.dart; ls lib/',
        isWindows: false,
        currentStreak: 0,
      );
      expect(v, isNotNull);
      // First segment wins — `cat` is the read verb.
      expect(v!.kind, ShellGuardKind.read);
    });

    test('chained with && picks first violation', () {
      final v = detectShellGuard(
        'cat lib/a.dart && echo done',
        isWindows: false,
        currentStreak: 0,
      );
      expect(v, isNotNull);
      expect(v!.kind, ShellGuardKind.read);
    });

    test('piped commands pick the first violation verb', () {
      // `cat | grep` — the user really wants grep, but the
      // first segment is `cat` which signals file inspection.
      // Either answer (read OR grep) is defensible; we pick
      // read because the leftmost verb is the "source of truth".
      final v = detectShellGuard(
        'cat lib/a.dart | grep TODO',
        isWindows: false,
        currentStreak: 0,
      );
      expect(v, isNotNull);
      expect(v!.kind, ShellGuardKind.read);
    });

    test('long command is truncated in verdict.command', () {
      final longPath = 'lib/${'a/' * 100}file.dart';
      final cmd = 'cat $longPath';
      final v = detectShellGuard(
        cmd,
        isWindows: false,
        currentStreak: 0,
      );
      expect(v, isNotNull);
      // Truncation marker (the `…` glyph) signals the
      // command was longer than the embed-friendly limit.
      expect(v!.command.length, lessThanOrEqualTo(201));
      expect(v.command, endsWith('…'));
    });

    test('empty command returns null', () {
      final v = detectShellGuard(
        '',
        isWindows: false,
        currentStreak: 0,
      );
      expect(v, isNull);
      final v2 = detectShellGuard(
        '   ',
        isWindows: false,
        currentStreak: 0,
      );
      expect(v2, isNull);
    });

    group('quote-aware segmentation (the false-positive bug fix)', () {
      // Regression test for the case where a multi-line commit
      // message containing `|` characters (as prose like
      // `pipes (|)`, `| head`, etc.) was mis-split by the
      // naive splitter, triggering false-positive guard fires
      // on parts of the commit message text.
      test(
        'does NOT flag git commit with multi-line message containing | as prose',
        () {
          final cmd = '''git commit -m 'feat(tools): shell-tool fallback guard

Catches the LLM using bash/cmd/powershell for ops that have a dedicated
tool (read/grep/glob/semantic_search) and applies a three-tier escalation.

The detector covers:
  * read:    cat/head/tail/less/sed/wc/file/stat/diff/…
  * glob:    ls/find/tree/du + Get-ChildItem/dir on Windows
  * grep:    grep/rg/ack/ag + Select-String/findstr on Windows
  * codeSearch: rg "concept" | head, find … | head → semantic_search

Smart skips: input redirects/heredocs (< anywhere), no-arg tail,
env-var prefixes (FOO=bar cat f), absolute-path verbs (/bin/cat).' ''';
          final v = detectShellGuard(
            cmd,
            isWindows: false,
            currentStreak: 0,
          );
          expect(v, isNull, reason: 'should not flag a commit message');
        },
      );

      test('does NOT flag double-quoted strings with pipes', () {
        // `echo "hello | world"` — the `|` is inside double
        // quotes, not an actual pipe. The whole thing is one
        // segment, verb is `echo` (not a violation).
        final v = detectShellGuard(
          'echo "hello | world"',
          isWindows: false,
          currentStreak: 0,
        );
        expect(v, isNull);
      });

      test('does NOT flag single-quoted strings with pipes', () {
        final v = detectShellGuard(
          "echo 'rg \"x\" lib/ | head'",
          isWindows: false,
          currentStreak: 0,
        );
        expect(v, isNull);
      });

      test(
        'still flags when pipe is OUTSIDE quotes (mixed quoted/unquoted)',
        () {
          // The OUTER `|` is unquoted and should split; the
          // INNER `|` is inside single quotes and should NOT.
          // Result: two segments: `cmd 'a|b'` and `cat file`.
          // cat has a path argument → flagged as read.
          final v = detectShellGuard(
            "cmd 'a|b' | cat file.txt",
            isWindows: false,
            currentStreak: 0,
          );
          expect(v, isNotNull);
          expect(v!.kind, ShellGuardKind.read);
        },
      );

      test(
        'semantic_search pipe anti-pattern does NOT match when pipe is inside quotes',
        () {
          // Without quote-awareness, the inner `|` would split
          // the segments and `rg ... | head` would match.
          // With quote-awareness, the whole `'rg ... | head'`
          // is one segment with verb `rg`, not `head`, so the
          // left/right adjacency check doesn't fire.
          final v = detectShellGuard(
            "echo 'rg \"concept\" lib/ | head'",
            isWindows: false,
            currentStreak: 0,
          );
          expect(v, isNull);
        },
      );

      test('handles escaped pipe outside quotes (\\| does not split)', () {
        // Backslash-escaped pipe outside any string: POSIX
        // shell treats `\|` as a literal `|` argument, not a
        // pipe. The detector should respect this and not
        // split.
        final v = detectShellGuard(
          r'echo a \| b',
          isWindows: false,
          currentStreak: 0,
        );
        expect(v, isNull);
      });

      test('handles && and || correctly even inside quotes', () {
        // The `&&` inside quotes is NOT an operator; the
        // `||` outside quotes IS an operator. Result: two
        // segments (`echo 'a && b'`) and (`cat file`).
        final v = detectShellGuard(
          "echo 'a && b' || cat file.txt",
          isWindows: false,
          currentStreak: 0,
        );
        expect(v, isNotNull);
        expect(v!.kind, ShellGuardKind.read);
      });
    });
  });

  group('detectShellGuard — Windows (cmd + PowerShell)', () {
    test('Get-Content / cat (PowerShell alias) → read', () {
      const cases = <String>[
        'Get-Content lib/main.dart',
        'gc README.md',
        'cat pubspec.yaml',
        'type notes.txt',
        'more big.log',
      ];
      for (final cmd in cases) {
        final v = detectShellGuard(
          cmd,
          isWindows: true,
          currentStreak: 0,
        );
        expect(v, isNotNull, reason: 'should flag: "$cmd"');
        expect(v!.kind, ShellGuardKind.read, reason: 'cmd="$cmd"');
      }
    });

    test('Get-ChildItem / dir / ls (PowerShell) → glob', () {
      const cases = <String>[
        'Get-ChildItem lib/',
        'gci src/',
        'dir *.cs',
        'ls build/',
      ];
      for (final cmd in cases) {
        final v = detectShellGuard(
          cmd,
          isWindows: true,
          currentStreak: 0,
        );
        expect(v, isNotNull, reason: 'should flag: "$cmd"');
        expect(v!.kind, ShellGuardKind.glob, reason: 'cmd="$cmd"');
      }
    });

    test('Select-String / findstr → grep', () {
      const cases = <String>[
        'Select-String -Path "*.cs" -Pattern "TODO"',
        'sls "auth" lib/',
        'findstr /R "TODO" *.cs',
        'find "auth" src/',
      ];
      for (final cmd in cases) {
        final v = detectShellGuard(
          cmd,
          isWindows: true,
          currentStreak: 0,
        );
        expect(v, isNotNull, reason: 'should flag: "$cmd"');
        expect(v!.kind, ShellGuardKind.grep, reason: 'cmd="$cmd"');
      }
    });

    test('Select-String | Select-Object → semantic_search', () {
      final v = detectShellGuard(
        r'Select-String -Path "*.cs" -Pattern "TODO" | Select-Object -First 10',
        isWindows: true,
        currentStreak: 0,
      );
      expect(v, isNotNull);
      expect(v!.kind, ShellGuardKind.codeSearch);
    });
  });

  // ===========================================================================
  // 2. Severity escalation
  // ===========================================================================

  group('detectShellGuard — severity escalation', () {
    test('streak=0 → mild (1st violation)', () {
      final v = detectShellGuard(
        'cat lib/main.dart',
        isWindows: false,
        currentStreak: 0,
      );
      expect(v, isNotNull);
      expect(v!.severity, ShellGuardSeverity.mild);
      expect(v.streakAfter, 1);
    });

    test('streak=1 → firm (2nd violation)', () {
      final v = detectShellGuard(
        'cat lib/main.dart',
        isWindows: false,
        currentStreak: 1,
      );
      expect(v, isNotNull);
      expect(v!.severity, ShellGuardSeverity.firm);
      expect(v.streakAfter, 2);
    });

    test('streak=2 → reject (3rd violation)', () {
      final v = detectShellGuard(
        'cat lib/main.dart',
        isWindows: false,
        currentStreak: 2,
      );
      expect(v, isNotNull);
      expect(v!.severity, ShellGuardSeverity.reject);
      expect(v.streakAfter, 3);
    });

    test('streak>=3 → reject (4th+ violation still blocked)', () {
      final v4 = detectShellGuard(
        'cat lib/main.dart',
        isWindows: false,
        currentStreak: 3,
      );
      expect(v4, isNotNull);
      expect(v4!.severity, ShellGuardSeverity.reject);
      expect(v4.streakAfter, 4);

      final v99 = detectShellGuard(
        'cat lib/main.dart',
        isWindows: false,
        currentStreak: 99,
      );
      expect(v99, isNotNull);
      expect(v99!.severity, ShellGuardSeverity.reject);
    });
  });

  // ===========================================================================
  // 3. Rendering
  // ===========================================================================

  group('renderShellGuardEmbedded (mild/firm tiers)', () {
    test('mild tier wraps in the standard marker tag', () {
      final v = detectShellGuard(
        'cat lib/main.dart',
        isWindows: false,
        currentStreak: 0,
      )!;
      final out = renderShellGuardEmbedded(v);
      expect(
        out,
        contains(shellGuardEmbeddedMarker(ShellGuardSeverity.mild)),
      );
      expect(out, contains('cat lib/main.dart')); // command echoed
    });

    test('firm tier wraps in the — firm marker tag', () {
      final v = detectShellGuard(
        'cat lib/main.dart',
        isWindows: false,
        currentStreak: 1,
      )!;
      final out = renderShellGuardEmbedded(v);
      expect(
        out,
        contains(shellGuardEmbeddedMarker(ShellGuardSeverity.firm)),
      );
    });

    test('reject tier throws (must use renderShellGuardRejection)', () {
      final v = detectShellGuard(
        'cat lib/main.dart',
        isWindows: false,
        currentStreak: 2,
      )!;
      expect(() => renderShellGuardEmbedded(v), throwsStateError);
    });

    test('embedded reminder mentions semantic_search prominently', () {
      final v = detectShellGuard(
        'cat lib/main.dart',
        isWindows: false,
        currentStreak: 0,
      )!;
      final out = renderShellGuardEmbedded(v);
      expect(out, contains('semantic_search'));
    });

    test('embedded reminder suggests the correct dedicated tool', () {
      final v = detectShellGuard(
        'cat lib/main.dart',
        isWindows: false,
        currentStreak: 0,
      )!;
      final out = renderShellGuardEmbedded(v);
      expect(out, contains('`read`'));
    });

    test('semantic_search verdict highlights the semantic-search benefit', () {
      final v = detectShellGuard(
        'rg "auth" lib/ | head -10',
        isWindows: false,
        currentStreak: 0,
      )!;
      expect(v.kind, ShellGuardKind.codeSearch);
      final out = renderShellGuardEmbedded(v);
      expect(out, contains('semantic_search'));
      expect(out, contains('semantic search'));
    });
  });

  group('renderShellGuardRejection (reject tier)', () {
    test('mild/firm tiers throw (must use renderShellGuardEmbedded)', () {
      final mild = detectShellGuard(
        'cat lib/main.dart',
        isWindows: false,
        currentStreak: 0,
      )!;
      expect(() => renderShellGuardRejection(mild), throwsStateError);
      final firm = detectShellGuard(
        'cat lib/main.dart',
        isWindows: false,
        currentStreak: 1,
      )!;
      expect(() => renderShellGuardRejection(firm), throwsStateError);
    });

    test('reject tier renders a clear BLOCKED message', () {
      final v = detectShellGuard(
        'cat lib/main.dart',
        isWindows: false,
        currentStreak: 2,
      )!;
      final out = renderShellGuardRejection(v);
      expect(out, contains('BLOCKED'));
      expect(out, contains('three or more times'));
      expect(out, contains('`read`'));
    });

    test('reject tier echoes the offending command', () {
      final v = detectShellGuard(
        'cat lib/main.dart',
        isWindows: false,
        currentStreak: 2,
      )!;
      final out = renderShellGuardRejection(v);
      expect(out, contains('cat lib/main.dart'));
    });

    test('reject tier emphasises semantic_search (per the user request)', () {
      final v = detectShellGuard(
        'rg "auth" lib/ | head -10',
        isWindows: false,
        currentStreak: 2,
      )!;
      final out = renderShellGuardRejection(v);
      expect(out, contains('semantic_search'));
    });
  });

  group('renderShellGuardBubbleLabel (user-facing)', () {
    test('mild → "1st · use `read` instead"', () {
      final v = detectShellGuard(
        'cat lib/main.dart',
        isWindows: false,
        currentStreak: 0,
      )!;
      expect(
        renderShellGuardBubbleLabel(v),
        'shell-tool fallback · 1st · use `read` instead',
      );
    });

    test('firm → "2nd · switch to `read`"', () {
      final v = detectShellGuard(
        'cat lib/main.dart',
        isWindows: false,
        currentStreak: 1,
      )!;
      expect(
        renderShellGuardBubbleLabel(v),
        'shell-tool fallback · 2nd · switch to `read`',
      );
    });

    test('reject → "3rd · blocked — use `read`"', () {
      final v = detectShellGuard(
        'cat lib/main.dart',
        isWindows: false,
        currentStreak: 2,
      )!;
      expect(
        renderShellGuardBubbleLabel(v),
        'shell-tool fallback · 3rd · blocked — use `read`',
      );
    });

    test('4th+ uses the ordinal-suffix form', () {
      final v = detectShellGuard(
        'cat lib/main.dart',
        isWindows: false,
        currentStreak: 3,
      )!;
      expect(
        renderShellGuardBubbleLabel(v),
        'shell-tool fallback · 4th · blocked — use `read`',
      );
    });

    test('semantic_search verdict surfaces the right tool name', () {
      final v = detectShellGuard(
        'rg "auth" lib/ | head -10',
        isWindows: false,
        currentStreak: 0,
      )!;
      expect(
        renderShellGuardBubbleLabel(v),
        'shell-tool fallback · 1st · use `semantic_search` instead',
      );
    });
  });

  // ===========================================================================
  // 4. End-to-end persistence
  // ===========================================================================

  group('MessageStore — shell_guard persistence', () {
    late CruxDatabase db;
    late SessionStore store;
    late int sessionId;

    setUp(() async {
      db = CruxDatabase.forTesting(NativeDatabase.memory());
      store = SessionStore(db);
      final session = await store.create(
        title: 'shell-guard-test',
        model: 'openai/gpt-4o',
        projectPath: '/tmp',
      );
      sessionId = session.id;
    });

    tearDown(() async {
      await db.close();
    });

    test('addMessage with role=shell_guard stores streak in parallelCount', () async {
      final v = detectShellGuard(
        'cat lib/main.dart',
        isWindows: false,
        currentStreak: 0,
      )!;
      final msg = await store.messageStore.addMessage(
        sessionId,
        role: 'shell_guard',
        content: renderShellGuardBubbleLabel(v),
        parallelCount: v.streakAfter,
      );
      expect(msg.role, 'shell_guard');
      expect(msg.parallelCount, 1);
      expect(msg.content, 'shell-tool fallback · 1st · use `read` instead');
    });

    test('reject-tier bubble stores streak=3 and the BLOCKED label', () async {
      final v = detectShellGuard(
        'cat lib/main.dart',
        isWindows: false,
        currentStreak: 2,
      )!;
      final msg = await store.messageStore.addMessage(
        sessionId,
        role: 'shell_guard',
        content: renderShellGuardBubbleLabel(v),
        parallelCount: v.streakAfter,
      );
      expect(msg.role, 'shell_guard');
      expect(msg.parallelCount, 3);
      expect(msg.content, contains('blocked'));
    });

    test('shell_guard row appears after a tool_call row in order', () async {
      await store.messageStore.addMessage(
        sessionId,
        role: 'user',
        content: 'show me main.dart',
      );
      await store.messageStore.addToolRound(
        sessionId,
        roundText: '',
        toolCalls: [
          // Model calls bash with `cat` — the guard fires.
          ToolCallData(
            callId: 'a',
            name: 'bash',
            input: {'command': 'cat lib/main.dart'},
          ),
        ],
        results: [
          (
            callId: 'a',
            output: '...cat output...\n\n[Crux system note — shell-tool fallback]\n...',
            meta: '{"shellGuard":true,"shellGuardKind":"read","shellGuardSeverity":"mild","shellGuardStreakAfter":1}',
          ),
        ],
      );
      final v = detectShellGuard(
        'cat lib/main.dart',
        isWindows: false,
        currentStreak: 0,
      )!;
      await store.messageStore.addMessage(
        sessionId,
        role: 'shell_guard',
        content: renderShellGuardBubbleLabel(v),
        parallelCount: v.streakAfter,
      );

      final msgs = await store.messageStore.getMessages(sessionId);
      // The renderer relies on this order to draw the bubble
      // inline directly below the matching tool-call list.
      expect(msgs.map((m) => m.role).toList(), [
        'user',
        'tool_call',
        'tool',
        'shell_guard',
      ]);
      expect(msgs.last.parallelCount, 1);
    });

    test('multiple shell_guard rows in one session (escalation scenario)',
        () async {
      // Simulate the three-tier escalation: 1st (mild) →
      // 2nd (firm) → 3rd (reject). Three bubbles, three
      // different parallelCount values.
      for (final streakBefore in [0, 1, 2]) {
        final v = detectShellGuard(
          'cat lib/main.dart',
          isWindows: false,
          currentStreak: streakBefore,
        )!;
        await store.messageStore.addMessage(
          sessionId,
          role: 'shell_guard',
          content: renderShellGuardBubbleLabel(v),
          parallelCount: v.streakAfter,
        );
      }
      final msgs = (await store.messageStore.getMessages(sessionId))
          .where((m) => m.role == 'shell_guard')
          .toList();
      expect(msgs.length, 3);
      expect(
        msgs.map((m) => m.parallelCount).toList(),
        [1, 2, 3],
      );
      expect(
        msgs.map((m) => m.content).toList(),
        [
          'shell-tool fallback · 1st · use `read` instead',
          'shell-tool fallback · 2nd · switch to `read`',
          'shell-tool fallback · 3rd · blocked — use `read`',
        ],
      );
    });
  });
}