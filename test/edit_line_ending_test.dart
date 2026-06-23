// Tests for the `edit` tool's behavior across line-ending differences
// (LF vs CRLF vs mixed).
//
//   The matchers registered in `EditTool._matchers` are tried in
//   order: `ExactMatcher`, `IndentationMatcher`, `WhitespaceMatcher`.
//   `_findMatch` returns the first non-null result, so the question
//   of "what does the edit tool do when the file's line endings
//   don't match the oldString's line endings?" reduces to "which
//   of the three matchers, if any, returns a result first, and
//   is its `matchLength` correct?"
//
//   Findings (verified by both the integration tests below and
//   by probing each matcher in isolation):
//
//     1. `ExactMatcher` is a pure byte search. It will not match
//        if the file's CRLF/LF differs from the oldString's.
//
//     2. `IndentationMatcher` strips trailing whitespace
//        (including \r) before comparing pattern lines to content
//        lines, so it DOES match across CRLF/LF. But its
//        `matchLength` is `pattern.length`, and that is wrong
//        when the file's line endings take 2 chars and the
//        pattern's take 1 (or vice versa). The fallback span is
//        short by one byte per line boundary, which causes the
//        last character of the matched region to be EATEN by
//        the replacement. This is the bug.
//
//     3. `WhitespaceMatcher` normalizes all whitespace runs to a
//        single space and computes the actual byte span from a
//        position map. It would have handled the case correctly
//        (and the isolated-match tests below prove this), but
//        `_findMatch` only consults it if `IndentationMatcher`
//        returned null — which it doesn't, because step 2
//        above always finds a (wrong-length) match first.
//
//   These tests are split into three groups:
//
//     A. Baseline (ExactMatcher path, line endings match). This
//        is the well-behaved path and documents what "success"
//        looks like in the common case.
//
//     B. The line-ending-mismatch path. These tests document the
//        current (buggy) behavior so a regression that changes
//        the broken behavior is caught, AND so a future fix
//        can be validated by simply flipping the expected
//        strings.
//
//     C. Matcher-in-isolation tests. These bypass `_findMatch`
//        and call each matcher directly. They document the
//        building blocks so it's clear that the bug is in the
//        `IndentationMatcher.matchLength` calculation, not in
//        the dispatch order or the WhitespaceMatcher's
//        position-map math.

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:crux/src/services/tool_executor.dart';
import 'package:crux/src/services/web_provider_registry.dart';
import 'package:crux/src/storage/storage.dart';
import 'package:crux/src/tools/edit_tool.dart';
import 'package:crux/src/tools/file_read_tracker.dart';
import 'package:crux/src/tools/matchers/exact_matcher.dart';
import 'package:crux/src/tools/matchers/indentation_matcher.dart';
import 'package:crux/src/tools/matchers/whitespace_matcher.dart';
import 'package:crux/src/tools/registry.dart';
import 'package:crux/src/tools/tool_def.dart';
import 'package:crux/src/utils/file_metadata.dart';

void main() {
  // -----------------------------------------------------------------
  // Group A: Baseline behavior with matching line endings.
  // -----------------------------------------------------------------

  group('A. baseline: line endings match', () {
    late Directory tempDir;
    late CruxDatabase db;
    late FileReadTracker tracker;
    late ToolRegistry registry;
    late ToolExecutor executor;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('crux_edit_le_A_');
      db = CruxDatabase.forTesting(NativeDatabase.memory());
      tracker = FileReadTracker();
      registry = ToolRegistry()
        ..registerDefaults(tracker, sessionStore: SessionStore(db), webProviderRegistry: WebProviderRegistry());
      executor = ToolExecutor(registry);
    });

    tearDown(() async {
      await db.close();
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    ToolContext ctx() => ToolContext(
      sessionId: 1,
      messageId: 1,
      abort: AbortSignal(),
      workingDirectory: tempDir.path,
    );

    test('LF file + LF oldString: matches via ExactMatcher, stays LF',
        () async {
      final filePath = '${tempDir.path}/lf.txt';
      await File(filePath).writeAsString('alpha\nbeta\ngamma');

      final file = File(filePath);
      final mtime = file.statSync().modified.millisecondsSinceEpoch;
      await tracker.recordRead(filePath, mtime);

      final result = await executor.executeTool(
        ToolCall(
          callId: 'c1',
          name: 'edit',
          input: {
            'filePath': filePath,
            'oldString': 'beta',
            'newString': 'BETA',
            'intent': 'baseline LF',
          },
        ),
        ctx(),
      );

      expect(result.output, contains('Replaced'));
      expect(await file.readAsString(), 'alpha\nBETA\ngamma');
      expect(await file.readAsBytes(), isNot(contains(0x0D)));
    });

    test('CRLF file + CRLF oldString: matches via ExactMatcher, stays CRLF',
        () async {
      final filePath = '${tempDir.path}/crlf.txt';
      await File(filePath).writeAsString('alpha\r\nbeta\r\ngamma');

      final file = File(filePath);
      final mtime = file.statSync().modified.millisecondsSinceEpoch;
      await tracker.recordRead(filePath, mtime);

      final result = await executor.executeTool(
        ToolCall(
          callId: 'c2',
          name: 'edit',
          input: {
            'filePath': filePath,
            'oldString': 'beta',
            'newString': 'BETA',
            'intent': 'baseline CRLF',
          },
        ),
        ctx(),
      );

      expect(result.output, contains('Replaced'));
      expect(await file.readAsString(), 'alpha\r\nBETA\r\ngamma');
      final bytes = await file.readAsBytes();
      for (var i = 0; i < bytes.length; i++) {
        if (bytes[i] == 0x0A) {
          expect(i, greaterThan(0), reason: 'bare LF at byte $i');
          expect(bytes[i - 1], 0x0D, reason: 'LF not preceded by CR');
        }
      }
    });
  });

  // -----------------------------------------------------------------
  // Group B: Line-ending mismatch WITHOUT .gitattributes.
  //
  // The edit tool now normalizes BOTH the file content and the
  // oldString to the file's detected line ending before
  // matching, so a CRLF file can be matched by an LF-only
  // oldString (and vice versa) without the IndentationMatcher's
  // matchLength bug firing. This group pins down the
  // post-fix behavior: the line-ending mismatch is invisible
  // to the caller. The result is the same as if the oldString
  // had used the file's line ending in the first place.
  //
  // The matcher-in-isolation tests (Group C) still document
  // the underlying matcher bug — the edit tool just sidesteps
  // it by normalizing before the matcher is ever called.
  // -----------------------------------------------------------------

  group('B. line endings mismatch (no .gitattributes)', () {
    late Directory tempDir;
    late CruxDatabase db;
    late FileReadTracker tracker;
    late ToolRegistry registry;
    late ToolExecutor executor;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('crux_edit_le_B_');
      db = CruxDatabase.forTesting(NativeDatabase.memory());
      tracker = FileReadTracker();
      registry = ToolRegistry()
        ..registerDefaults(tracker, sessionStore: SessionStore(db), webProviderRegistry: WebProviderRegistry());
      executor = ToolExecutor(registry);
    });

    tearDown(() async {
      await db.close();
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    ToolContext ctx() => ToolContext(
      sessionId: 1,
      messageId: 1,
      abort: AbortSignal(),
      workingDirectory: tempDir.path,
    );

    Future<({ToolResult result, String content, List<int> bytes})>
        runEdit({
      required String filePath,
      required String oldString,
      required String newString,
      bool replaceAll = false,
    }) async {
      final file = File(filePath);
      final mtime = file.statSync().modified.millisecondsSinceEpoch;
      await tracker.recordRead(filePath, mtime);
      final result = await executor.executeTool(
        ToolCall(
          callId: 'le',
          name: 'edit',
          input: {
            'filePath': filePath,
            'oldString': oldString,
            'newString': newString,
            'replaceAll': replaceAll,
            'intent': 'mismatch test',
          },
        ),
        ctx(),
      );
      return (
        result: result,
        content: await file.readAsString(),
        bytes: await file.readAsBytes(),
      );
    }

    test(
      'CRLF file + LF single-line oldString (no line ending in the '
      'pattern): ExactMatcher handles it — the bug only fires when '
      'the pattern itself contains a line ending that mismatches',
      () async {
        // Counterexample: when the oldString is a single token
        // with no line endings in it (e.g. "beta"), ExactMatcher
        // does a pure byte search and finds it cleanly. The
        // file's CRLF doesn't matter because the matched region
        // is in the middle of a line, between two \r\n. This is
        // the "easy" sub-case of CRLF-vs-LF: a model that
        // produces a bare-token oldString never hits the bug.
        final filePath = '${tempDir.path}/crlf_lf_single.txt';
        await File(filePath).writeAsString('alpha\r\nbeta\r\ngamma');

        final r = await runEdit(
          filePath: filePath,
          oldString: 'beta', // single token, no line endings
          newString: 'BETA',
        );

        expect(r.result.output, contains('Replaced'));
        // No bug here: the replacement is exactly the matched
        // span ("beta"), and the surrounding \r\n is preserved.
        expect(r.content, 'alpha\r\nBETA\r\ngamma');

        // Sanity: the on-disk bytes are still CRLF. The
        // normalizeToLineEnding pass at the end of the edit
        // preserves the file's convention.
        for (var i = 0; i < r.bytes.length; i++) {
          if (r.bytes[i] == 0x0A) {
            expect(i, greaterThan(0));
            expect(r.bytes[i - 1], 0x0D,
                reason: 'LF at byte $i not preceded by CR: '
                    '${r.bytes}');
          }
        }
      },
    );

    test(
      'CRLF file + LF oldString ending in \\n: edit tool normalizes '
      'both sides, the match is byte-exact, no byte is eaten',
      () async {
        // The oldString "alpha\nbeta" has a line ending; the
        // file uses CRLF. Without the fix, IndentationMatcher's
        // matchLength was `pattern.length` = 10, which is short
        // by 1 byte per line break in the pattern, and the
        // 'a' of "beta" would be eaten. With the fix, the
        // oldString is normalized to CRLF before matching, so
        // ExactMatcher does a byte-exact match on the full
        // 11-byte span.
        final filePath = '${tempDir.path}/crlf_lf_with_newline.txt';
        await File(filePath).writeAsString('alpha\r\nbeta\r\ngamma');

        final r = await runEdit(
          filePath: filePath,
          oldString: 'alpha\nbeta',
          newString: 'ALPHA\nBETA',
        );

        expect(r.result.output, contains('Replaced'));
        // The replacement covers exactly the matched span
        // ("alpha\r\nbeta" → "ALPHA\r\nBETA"); the trailing
        // "\r\ngamma" is preserved.
        expect(r.content, 'ALPHA\r\nBETA\r\ngamma');
        // All LFs in the result are preceded by CR (the file
        // stays CRLF throughout).
        for (var i = 0; i < r.bytes.length; i++) {
          if (r.bytes[i] == 0x0A) {
            expect(i, greaterThan(0));
            expect(r.bytes[i - 1], 0x0D,
                reason: 'LF at byte $i not preceded by CR: '
                    '${r.bytes}');
          }
        }
      },
    );

    test(
      'LF file + CRLF oldString (single token, no line ending in '
      'pattern): ExactMatcher handles it after normalization',
      () async {
        // The oldString is a single line with NO line ending in
        // it. ExactMatcher's byte search works because the file
        // (already in LF) byte-matches a single line of
        // content. This is the easy sub-case of mismatched
        // line endings.
        final filePath = '${tempDir.path}/lf_crlf_single.txt';
        await File(filePath).writeAsString('alpha\nbeta\ngamma');

        final r = await runEdit(
          filePath: filePath,
          oldString: 'beta',
          newString: 'BETA',
        );

        expect(r.result.output, contains('Replaced'));
        expect(r.content, 'alpha\nBETA\ngamma');
        expect(r.bytes, isNot(contains(0x0D)));
      },
    );

    test(
      'LF file + CRLF single-line oldString (trailing \\r in '
      'pattern): a known edge case the edit tool does not yet '
      'handle — IndentationMatcher wins with a wrong-length span',
      () async {
        // KNOWN ISSUE. This test documents the residual case:
        // when the oldString is a single token followed by a
        // stray line-ending byte (a Mac-style \r on an
        // otherwise-LF file), the IndentationMatcher's
        // matchLength is `pattern.length`, which is one byte
        // longer than the actual line content. The fix would
        // either:
        //   (a) strip trailing \r from the oldString when the
        //       target line ending doesn't include \r, or
        //   (b) make IndentationMatcher compute the content
        //       span using the file's actual line ending.
        //
        // For now, this test pins the buggy behavior so a
        // future fix can be validated by flipping the expected
        // string. The .gitattributes fix doesn't apply here
        // (no .gitattributes in this test).
        final filePath = '${tempDir.path}/lf_crlf_stray.txt';
        await File(filePath).writeAsString('alpha\nbeta\ngamma');

        final r = await runEdit(
          filePath: filePath,
          oldString: 'beta\r',
          newString: 'BETA',
        );

        expect(r.result.output, contains('Replaced'));
        // CURRENT (BUGGY) RESULT: the matched span was
        // "beta\n" (5 chars, since the file's "beta\n" is the
        // only 5-byte sequence starting with "beta"); the
        // surrounding \n is consumed by the replacement.
        expect(r.content, 'alpha\nBETAgamma',
            reason: 'documents the residual edge case — '
                'flip to "alpha\nBETA\ngamma" once the fix lands');
      },
    );

    test(
      'CRLF file + LF multi-line oldString: edit is byte-exact',
      () async {
        final filePath = '${tempDir.path}/crlf_lf_multi.txt';
        await File(filePath).writeAsString('first\r\nsecond\r\nthird');

        final r = await runEdit(
          filePath: filePath,
          oldString: 'first\nsecond',
          newString: 'FIRST\nSECOND',
        );

        expect(r.result.output, contains('Replaced'));
        expect(r.content, 'FIRST\r\nSECOND\r\nthird');
        for (var i = 0; i < r.bytes.length; i++) {
          if (r.bytes[i] == 0x0A) {
            expect(i, greaterThan(0));
            expect(r.bytes[i - 1], 0x0D);
          }
        }
      },
    );

    test(
      'LF file + CRLF multi-line oldString: mirrored',
      () async {
        final filePath = '${tempDir.path}/lf_crlf_multi.txt';
        await File(filePath).writeAsString('first\nsecond\nthird');

        final r = await runEdit(
          filePath: filePath,
          oldString: 'first\r\nsecond',
          newString: 'FIRST\r\nSECOND',
        );

        expect(r.result.output, contains('Replaced'));
        expect(r.content, 'FIRST\nSECOND\nthird');
        // The newString was CRLF, but the file is LF — the
        // normalizeToLineEnding pass at the end of the edit
        // converts it back to LF. So the file stays LF.
        expect(r.bytes, isNot(contains(0x0D)));
      },
    );

    test(
      'CRLF file + LF oldString that exactly spans two lines: '
      'no surrounding byte is eaten',
      () async {
        final filePath = '${tempDir.path}/span.txt';
        await File(filePath).writeAsString('a\r\nb\r\nc\r\nd\r\ne');

        final r = await runEdit(
          filePath: filePath,
          oldString: 'b\nc',
          newString: 'B',
        );

        expect(r.result.output, contains('Replaced'));
        expect(r.content, 'a\r\nB\r\nd\r\ne');
        // The file has 4 lines (a, B, d, e), joined by 3
        // line endings. The match correctly preserved all
        // three surrounding \r\n.
        expect(r.content.split('\n').length, 4,
            reason: '4 lines: a, B, d, e — got: ${r.content}');
      },
    );

    test(
      'replaceAll with line-ending mismatch: every occurrence '
      'is replaced, no byte is eaten',
      () async {
        final filePath = '${tempDir.path}/replaceall.txt';
        await File(filePath).writeAsString(
          'foo\r\nbar\r\nfoo\r\nbaz\r\nfoo',
        );

        final r = await runEdit(
          filePath: filePath,
          oldString: 'foo',
          newString: 'FOO',
          replaceAll: true,
        );

        expect(r.result.output, contains('Replaced 3 occurrence'),
            reason: 'got: ${r.result.output}');
        expect(r.content, 'FOO\r\nbar\r\nFOO\r\nbaz\r\nFOO');
      },
    );
  });

  // -----------------------------------------------------------------
  // Group C: matcher-in-isolation tests.
  //
  // Bypasses `_findMatch` and calls each matcher directly. This
  // isolates the bug to `IndentationMatcher.matchLength` and
  // proves the `WhitespaceMatcher` math is correct.
  // -----------------------------------------------------------------

  group('C. individual matchers across line endings', () {
    final exact = ExactMatcher();
    final indent = IndentationMatcher();
    final whitespace = WhitespaceMatcher();

    test('ExactMatcher: strict byte match — no cross-ending match',
        () {
      expect(
        exact.findMatches('a\r\nb', 'a\nb', false),
        isNull,
        reason: 'CRLF content vs LF pattern must not match',
      );
      expect(
        exact.findMatches('a\nb', 'a\r\nb', false),
        isNull,
        reason: 'LF content vs CRLF pattern must not match',
      );
      // Matching endings DO match.
      expect(
        exact.findMatches('a\r\nb', 'a\r\nb', false),
        isNotNull,
      );
      expect(
        exact.findMatches('a\nb', 'a\nb', false),
        isNotNull,
      );
    });

    test(
      'IndentationMatcher: matches across CRLF/LF, but matchLength '
      'is short by one byte per line break in the pattern',
      () {
        // Content is CRLF, pattern is LF. IndentationMatcher
        // matches (because trimRight eats the \r), but the
        // matchLength is `pattern.length` = 3, so the span
        // covered is content[3..6] = "b\r\n" — missing "c".
        final result = indent.findMatches(
          'a\r\nb\r\nc\r\nd\r\ne',
          'b\nc',
          false,
        );
        expect(result, isNotNull);
        expect(result!.positions, [3]);
        expect(result.matchLength, isNull,
            reason: 'IndentationMatcher does not set matchLength; '
                'caller defaults to pattern.length');
        // Demonstrating the consequence: the edit tool
        // computes the replacement span as
        // position + pattern.length = 3 + 3 = 6.
        // content.substring(3, 6) is "b\r\n", not "b\r\nc".
        const pattern = 'b\nc';
        final start = result.positions.first;
        final end = start + pattern.length;
        expect('a\r\nb\r\nc\r\nd\r\ne'.substring(start, end), 'b\r\n',
            reason: 'THIS is the bug: the matched-and-replaced span '
                'is 1 byte short, so the next char ("c") gets eaten');
      },
    );

    test(
      'WhitespaceMatcher: matches across CRLF/LF AND computes the '
      'correct byte span — proving the underlying math is fine',
      () {
        // Same input as the IndentationMatcher test above, but
        // WhitespaceMatcher correctly reports a 4-char span.
        final result = whitespace.findMatches(
          'a\r\nb\r\nc\r\nd\r\ne',
          'b\nc',
          false,
        );
        expect(result, isNotNull);
        expect(result!.positions, [3]);
        expect(result.matchLength, 4,
            reason: 'WhitespaceMatcher must report the actual byte '
                'span (4 chars: "b", \\r, \\n, "c")');
        final start = result.positions.first;
        final end = start + result.matchLength!;
        expect('a\r\nb\r\nc\r\nd\r\ne'.substring(start, end), 'b\r\nc',
            reason: 'WhitespaceMatcher replaces the right span');
      },
    );

    test(
      'WhitespaceMatcher: trailing-line-ending patterns are short by '
      'one byte (the .trim() in _normalize eats the trailing CR/LF)',
      () {
        // A second, more subtle bug: the WhitespaceMatcher's
        // _normalize() calls .trim() on the pattern, which
        // strips the trailing CRLF. The position map is then
        // built from the un-trimmed content, but the match
        // length is computed against the trimmed pattern. The
        // result: a pattern ending in CRLF matches, but the
        // matchLength doesn't include the trailing CRLF.
        //
        // This bug is different from IndentationMatcher's bug:
        // - IndentationMatcher: missing 1 byte per line break
        //   in the pattern (so "first\nsecond" misses 1 byte
        //   for the \n).
        // - WhitespaceMatcher: missing 1 byte total, and only
        //   for the trailing line ending.
        //
        // In practice this rarely matters because the
        // IndentationMatcher's bug wins in the fallback chain
        // (it returns a non-null result first). But it's worth
        // pinning down so a future fix to IndentationMatcher
        // doesn't accidentally make WhitespaceMatcher's bug
        // visible to integration tests.
        final result = whitespace.findMatches(
          'aaa\r\nbbb',
          'aaa\r\n', // CRLF in the pattern
          false,
        );
        expect(result, isNotNull);
        // CURRENT (BUGGY) RESULT: matchLength = 3, so the
        // matched-and-replaced span is "aaa" (3 bytes), not
        // "aaa\r\n" (5 bytes). The trailing \r\n is left in
        // the file untouched.
        final start = result!.positions.first;
        final end = start + result.matchLength!;
        expect('aaa\r\nbbb'.substring(start, end), 'aaa',
            reason: 'documents the WhitespaceMatcher trailing-'
                'line-ending bug; should be "aaa\\r\\n" once fixed');
      },
    );

    test(
      'WhitespaceMatcher: non-trailing line endings in the pattern '
      'are handled correctly (position map is right for them)',
      () {
        // Pin down the part of WhitespaceMatcher that DOES work:
        // line endings in the middle of the pattern. The position
        // map captures the \r position (e.g. map[5]=5 for
        // "first\r\nsecond..."), so the matched span correctly
        // includes the full "\r\n" bytes between non-trailing
        // text. Only the trailing-line-ending case in the
        // previous test is buggy.
        final result = whitespace.findMatches(
          'first\r\nsecond\r\nthird',
          'first\nsecond', // \n in the middle
          false,
        );
        expect(result, isNotNull);
        expect(result!.positions, [0]);
        expect(result.matchLength, 13,
            reason: 'should report the actual byte span: '
                '"first\\r\\nsecond" is 13 chars');
        expect(
          'first\r\nsecond\r\nthird'.substring(0, result.matchLength!),
          'first\r\nsecond',
        );
      },
    );
  });

  // -----------------------------------------------------------------
  // A small inline EditTool sanity check that the tool is registered
  // and matches what the executor does (guards against the test
  // accidentally exercising a different tool implementation).
  // -----------------------------------------------------------------
  test('sanity: EditTool is registered under the name "edit"', () {
    final registry = ToolRegistry()
      ..registerDefaults(
        FileReadTracker(),
        sessionStore: SessionStore(CruxDatabase.forTesting(NativeDatabase.memory())),
        webProviderRegistry: WebProviderRegistry(),
      );
    expect(registry.lookup('edit'), isA<EditTool>());
  });

  // -----------------------------------------------------------------
  // Group D: .gitattributes drives the target line ending.
  //
  // The fix lives in `lib/src/utils/gitattributes.dart` and
  // `targetLineEndingFor` in `file_metadata.dart`. When a
  // `.gitattributes` declares `eol=crlf` / `eol=lf` / `text`
  // for a file, the edit tool normalizes the file's content to
  // the declared target BEFORE matching, so the LF/CRLF
  // mismatch goes away at the source instead of relying on
  // the matchers' lenient fallback path.
  //
  // Without a `.gitattributes` the behavior matches group B
  // (the matcher bug is still there for files that lack
  // gitattributes coverage). This group proves the
  // .gitattributes-driven case works correctly.
  //
  // The .gitattributes lookup is a process-wide singleton
  // (`gitAttributesLookup` in file_metadata.dart), so the
  // tests in this group manipulate it directly to inject
  // fixtures and clear the cache between cases.
  // -----------------------------------------------------------------

  group('D. .gitattributes drives the target line ending', () {
    late Directory tempDir;
    late CruxDatabase db;
    late FileReadTracker tracker;
    late ToolRegistry registry;
    late ToolExecutor executor;

    setUp(() async {
      // Drop the cache so each test sees a clean slate; the
      // lookup is a process-wide singleton.
      gitAttributesLookup.clearCache();
      tempDir = await Directory.systemTemp.createTemp('crux_edit_le_D_');
      db = CruxDatabase.forTesting(NativeDatabase.memory());
      tracker = FileReadTracker();
      registry = ToolRegistry()
        ..registerDefaults(tracker, sessionStore: SessionStore(db), webProviderRegistry: WebProviderRegistry());
      executor = ToolExecutor(registry);
    });

    tearDown(() async {
      await db.close();
      gitAttributesLookup.clearCache();
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    ToolContext ctx() => ToolContext(
      sessionId: 1,
      messageId: 1,
      abort: AbortSignal(),
      workingDirectory: tempDir.path,
    );

    /// Write a .gitattributes into the temp dir with [content].
    Future<void> writeGitAttributes(String content) async {
      final f = File(p.join(tempDir.path, '.gitattributes'));
      await f.writeAsString(content);
    }

    Future<({ToolResult result, String content, List<int> bytes})>
        runEdit({
      required String filePath,
      required String oldString,
      required String newString,
    }) async {
      final file = File(filePath);
      final mtime = file.statSync().modified.millisecondsSinceEpoch;
      await tracker.recordRead(filePath, mtime);
      final result = await executor.executeTool(
        ToolCall(
          callId: 'ga',
          name: 'edit',
          input: {
            'filePath': filePath,
            'oldString': oldString,
            'newString': newString,
            'intent': 'gitattributes test',
          },
        ),
        ctx(),
      );
      return (
        result: result,
        content: await file.readAsString(),
        bytes: await file.readAsBytes(),
      );
    }

    test(
      'eol=crlf in .gitattributes: LF file is normalized to CRLF '
      'before matching, and the multi-line LF oldString matches cleanly',
      () async {
        await writeGitAttributes('*.txt eol=crlf\n');
        final filePath = '${tempDir.path}/doc.txt';
        // The file is mis-saved as LF (should be CRLF per
        // .gitattributes). The agent passes an LF oldString
        // (typical for a Unix-trained tool prompt).
        await File(filePath).writeAsString('first\nsecond\nthird');

        final r = await runEdit(
          filePath: filePath,
          oldString: 'first\nsecond',
          newString: 'FIRST\nSECOND',
        );

        expect(r.result.output, contains('Replaced'),
            reason: 'with the target line ending applied, the '
                'oldString should match cleanly, got: '
                '${r.result.output}');
        // The file is now correctly CRLF (the target), and the
        // replacement took the right bytes (no eating).
        expect(r.content, 'FIRST\r\nSECOND\r\nthird');
        for (var i = 0; i < r.bytes.length; i++) {
          if (r.bytes[i] == 0x0A) {
            expect(i, greaterThan(0));
            expect(r.bytes[i - 1], 0x0D);
          }
        }
      },
    );

    test(
      'eol=lf in .gitattributes: CRLF file is normalized to LF '
      'before matching; the CRLF oldString matches cleanly',
      () async {
        await writeGitAttributes('*.txt eol=lf\n');
        final filePath = '${tempDir.path}/doc.txt';
        await File(filePath).writeAsString('first\r\nsecond\r\nthird');

        final r = await runEdit(
          filePath: filePath,
          oldString: 'first\r\nsecond',
          newString: 'FIRST\r\nSECOND',
        );

        expect(r.result.output, contains('Replaced'));
        // The file is now correctly LF.
        expect(r.content, 'FIRST\nSECOND\nthird');
        expect(r.bytes, isNot(contains(0x0D)));
      },
    );

    test(
      'eol=crlf in .gitattributes: even the trailing-line-ending '
      'case (the WhitespaceMatcher bug) is fixed, because the '
      'oldString is normalized to CRLF too at the matcher level',
      () async {
        await writeGitAttributes('*.txt eol=crlf\n');
        final filePath = '${tempDir.path}/doc.txt';
        await File(filePath).writeAsString('aaa\r\nbbb');

        // The trailing \r\n in the oldString would have hit the
        // WhitespaceMatcher's trailing-CR bug, but with the file
        // pre-normalized to CRLF, ExactMatcher matches it
        // byte-exactly.
        final r = await runEdit(
          filePath: filePath,
          oldString: 'aaa\r\n',
          newString: 'AAA',
        );

        expect(r.result.output, contains('Replaced'));
        expect(r.content, 'AAAbbb');
      },
    );

    test(
      'eol=lf in .gitattributes: file written as LF on disk, even '
      'when the agent passes CRLF in newString',
      () async {
        await writeGitAttributes('*.txt eol=lf\n');
        final filePath = '${tempDir.path}/doc.txt';
        await File(filePath).writeAsString('hello');

        final r = await runEdit(
          filePath: filePath,
          oldString: 'hello',
          newString: 'HI\r\nWORLD',
        );

        expect(r.result.output, contains('Replaced'));
        // The newString's internal CRLF is converted to LF on
        // write, so the file stays LF throughout.
        expect(r.content, 'HI\nWORLD');
        expect(r.bytes, isNot(contains(0x0D)));
      },
    );

    test(
      'text attribute (no eol=) is treated as eol=lf',
      () async {
        // The plain `text` attribute is git's "this is text,
        // normalize to LF" marker; we honor that.
        await writeGitAttributes('*.txt text\n');
        final filePath = '${tempDir.path}/doc.txt';
        // Mis-saved as CRLF; should be LF per .gitattributes.
        await File(filePath).writeAsString('hello\r\nworld');

        final r = await runEdit(
          filePath: filePath,
          oldString: 'hello\r\nworld',
          newString: 'HELLO\nWORLD',
        );

        expect(r.result.output, contains('Replaced'));
        // The file is written in LF (the text attribute's target).
        expect(r.content, 'HELLO\nWORLD');
        expect(r.bytes, isNot(contains(0x0D)));
      },
    );

    test(
      'binary attribute: file is left alone, even when the agent '
      'passes LF/CRLF in oldString',
      () async {
        // The .gitattributes marks this file binary. The edit
        // tool should NOT normalize the line endings — a binary
        // file has no concept of line endings. (In practice, the
        // edit tool's matchers are unlikely to find a match in
        // a binary blob, but the important guarantee is that we
        // don't corrupt it by silently rewriting line endings.)
        await writeGitAttributes('*.bin binary\n');
        final filePath = '${tempDir.path}/blob.bin';
        // The "content" contains line endings that look like
        // text, but the file is declared binary.
        await File(filePath).writeAsBytes(
            [0x68, 0x69, 0x0D, 0x0A, 0x68, 0x69, 0x69]); // "hi\r\nhii"

        final r = await runEdit(
          filePath: filePath,
          oldString: 'hi\r\nhii',
          newString: 'replaced',
        );

        // The edit may or may not match (the bytes are the same
        // either way); the important assertion is that the
        // file's bytes are NOT silently rewritten.
        if (r.result.output.contains('Replaced')) {
          // If the edit took, the file should still be the
          // exact bytes the user requested — no CRLF
          // normalization.
          expect(r.bytes, utf8.encode('replaced'),
              reason: 'binary file should not be line-ending '
                  'normalized on write');
        } else {
          // If the edit didn't match, the file should be
          // untouched.
          expect(r.bytes, [0x68, 0x69, 0x0D, 0x0A, 0x68, 0x69, 0x69],
              reason: 'binary file with no match should be '
                  'left untouched, got: ${r.bytes}');
        }
      },
    );

    test(
      '.gitattributes lookup walks upward: a .gitattributes in a '
      'parent directory applies to nested files',
      () async {
        // Project root with a .gitattributes; nested dir has the
        // file we edit.
        final nested = Directory(p.join(tempDir.path, 'src', 'lib'))
          ..createSync(recursive: true);
        await File(p.join(tempDir.path, '.gitattributes'))
            .writeAsString('**/*.dart eol=crlf\n');
        final filePath = p.join(nested.path, 'main.dart');
        await File(filePath).writeAsString('void main() {}\n');

        final r = await runEdit(
          filePath: filePath,
          oldString: 'void main() {}\n',
          newString: 'void main() { print("hi"); }\n',
        );

        expect(r.result.output, contains('Replaced'));
        // The file is in CRLF after the edit (per the
        // upward .gitattributes lookup).
        expect(r.content, 'void main() { print("hi"); }\r\n');
        for (var i = 0; i < r.bytes.length; i++) {
          if (r.bytes[i] == 0x0A) {
            expect(i, greaterThan(0));
            expect(r.bytes[i - 1], 0x0D);
          }
        }
      },
    );

    test(
      'later matching rule wins (gitattributes "last match wins" '
      'semantics): a more specific pattern can override a broader one',
      () async {
        // *.txt says eol=lf, but special.txt says eol=crlf.
        // special.txt should be CRLF.
        await writeGitAttributes('*.txt eol=lf\nspecial.txt eol=crlf\n');
        final filePath = '${tempDir.path}/special.txt';
        await File(filePath).writeAsString('a\nb\nc');

        final r = await runEdit(
          filePath: filePath,
          oldString: 'a\nb',
          newString: 'A\nB',
        );

        expect(r.result.output, contains('Replaced'));
        // The last matching rule was eol=crlf; the file is in CRLF.
        expect(r.content, 'A\r\nB\r\nc');
        for (var i = 0; i < r.bytes.length; i++) {
          if (r.bytes[i] == 0x0A) {
            expect(i, greaterThan(0));
            expect(r.bytes[i - 1], 0x0D);
          }
        }
      },
    );

    test(
      'no .gitattributes: edit tool falls back to file\'s detected '
      'line ending (the original behavior is preserved)',
      () async {
        // No .gitattributes in tempDir.
        final filePath = '${tempDir.path}/plain.txt';
        await File(filePath).writeAsString('hello\nworld');

        final r = await runEdit(
          filePath: filePath,
          oldString: 'hello\nworld',
          newString: 'HELLO\nWORLD',
        );

        expect(r.result.output, contains('Replaced'));
        // LF in, LF out (no gitattributes to drive a change).
        expect(r.content, 'HELLO\nWORLD');
        expect(r.bytes, isNot(contains(0x0D)));
      },
    );
  });
}
