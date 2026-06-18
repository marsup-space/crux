// Regression tests for parallel calls to the same file through the
// per-file lock in `lib/src/tools/file_lock.dart`.
//
// Both [EditTool] and [WriteTool] do non-atomic read → mutate →
// write on the file's bytes. Without per-file serialization, two
// concurrent calls race: both read the original content, both
// compute their replacement on that original, both write — only
// the last write survives, and partial writes can corrupt the file.
//
// The fix wraps the read/modify/write in `fileLock(resolved).run`,
// which chains concurrent operations on the same path in FIFO
// order. Operations on DIFFERENT paths remain unblocked.
//
// This file runs the same two regression scenarios for both
// `edit` and `write`:
//
//   1. The "parallel via Future.wait" test fires N operations
//      concurrently and asserts every operation applies cleanly.
//      It MUST pass — the lock guarantees it.
//
//   2. The "sequential for-await" test mirrors chat_service.dart's
//      dispatch loop. It MUST also pass — and is the natural
//      regression net if anyone "optimizes" the dispatch loop to
//      `Future.wait` (which the lock now makes safe to do).
//
// If test 1 ever starts failing, the per-file lock has regressed
// or been bypassed — investigate before relying on parallel edits.
// If test 2 fails but test 1 passes, the dispatch loop's exact
// shape changed in a way the lock didn't cover — review.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'package:crux/src/services/tool_executor.dart';
import 'package:crux/src/storage/storage.dart';
import 'package:crux/src/tools/file_read_tracker.dart';
import 'package:crux/src/tools/registry.dart';
import 'package:crux/src/tools/tool_def.dart';

void main() {
  late Directory tempDir;
  late CruxDatabase db;
  late FileReadTracker tracker;
  late ToolRegistry registry;
  late ToolExecutor executor;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('crux_par_');
    db = CruxDatabase.forTesting(NativeDatabase.memory());
    tracker = FileReadTracker();
    registry = ToolRegistry()..registerDefaults(tracker);
    executor = ToolExecutor(registry);
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  ToolContext ctx() => ToolContext(
        sessionId: 1,
        messageId: 1,
        abort: AbortSignal(),
        workingDirectory: tempDir.path,
      );

  /// Mark a file as already read by the agent, mimicking the
  /// real-world flow where the model calls `read` first and then
  /// batches follow-up calls. Without this, the first call would
  /// correctly trip the "file not read before write" guard — the
  /// desired safety behavior, but orthogonal to what these tests
  /// verify (parallel-dispatch safety of the application itself).
  Future<void> markRead(String filePath) async {
    final file = File(filePath);
    final mtime = file.statSync().modified.millisecondsSinceEpoch;
    await tracker.recordRead(filePath, mtime);
  }

  // ─────────────────────────────────────────────────────────────────
  // edit
  // ─────────────────────────────────────────────────────────────────

  group('parallel edit calls to the same file', () {
    Future<List<ToolResult>> runEdits(List<Map<String, dynamic>> inputs) {
      final calls = <ToolCall>[];
      for (var i = 0; i < inputs.length; i++) {
        calls.add(ToolCall(
          callId: 'call_$i',
          name: 'edit',
          input: inputs[i],
        ));
      }
      return Future.wait(
        calls.map((c) => executor.executeTool(c, ctx())),
      );
    }

    test(
      'five concurrent edits to the same file all apply '
      '(Future.wait simulates parallel dispatch)',
      () async {
        // Build a file with five distinct, non-overlapping markers.
        // Each edit targets exactly one marker; if all five edits
        // apply, the file's final content has all five replacements
        // and zero original markers remaining.
        final filePath = '${tempDir.path}/combo.txt';
        final original = [
          'MARK_ALPHA keep',
          'MARK_BETA keep',
          'MARK_GAMMA keep',
          'MARK_DELTA keep',
          'MARK_EPSILON keep',
        ].join('\n');
        await File(filePath).writeAsString(original);
        await markRead(filePath);

        final edits = <Map<String, dynamic>>[
          {
            'filePath': filePath,
            'oldString': 'MARK_ALPHA',
            'newString': 'GONE_A',
            'intent': 'replace marker alpha',
          },
          {
            'filePath': filePath,
            'oldString': 'MARK_BETA',
            'newString': 'GONE_B',
            'intent': 'replace marker beta',
          },
          {
            'filePath': filePath,
            'oldString': 'MARK_GAMMA',
            'newString': 'GONE_C',
            'intent': 'replace marker gamma',
          },
          {
            'filePath': filePath,
            'oldString': 'MARK_DELTA',
            'newString': 'GONE_D',
            'intent': 'replace marker delta',
          },
          {
            'filePath': filePath,
            'oldString': 'MARK_EPSILON',
            'newString': 'GONE_E',
            'intent': 'replace marker epsilon',
          },
        ];

        final results = await runEdits(edits);

        // Each call must report a successful replacement.
        for (final r in results) {
          expect(
            r.output,
            contains('Replaced'),
            reason: 'every parallel edit must report success, got: ${r.output}',
          );
        }

        // File contents: every original marker gone, every new
        // replacement present.
        final after = await File(filePath).readAsString();
        expect(after, isNot(contains('MARK_ALPHA')));
        expect(after, isNot(contains('MARK_BETA')));
        expect(after, isNot(contains('MARK_GAMMA')));
        expect(after, isNot(contains('MARK_DELTA')));
        expect(after, isNot(contains('MARK_EPSILON')));
        expect(after, contains('GONE_A'));
        expect(after, contains('GONE_B'));
        expect(after, contains('GONE_C'));
        expect(after, contains('GONE_D'));
        expect(after, contains('GONE_E'));

        // Sanity: line count preserved (no edits accidentally
        // dropped or duplicated lines).
        expect(
          '\n'.allMatches(after).length + 1,
          5,
          reason: 'line count should be unchanged, got:\n$after',
        );
      },
    );

    test(
      'the chat_service dispatch pattern (sequential for-await) '
      'applies all edits — confirming the production path is safe',
      () async {
        // Belt-and-suspenders: prove that the exact code shape used
        // by chat_service.dart (a `for` loop with `await` on each
        // iteration) applies every edit when targeting the same
        // file. This is the property that makes the production
        // loop safe; the previous test probes the upper bound of
        // what the executor can survive.
        final filePath = '${tempDir.path}/seq.txt';
        await File(filePath).writeAsString(
          'one\ntwo\nthree\nfour\nfive',
        );
        await markRead(filePath);

        final edits = <Map<String, dynamic>>[
          {'filePath': filePath, 'oldString': 'one', 'newString': 'ONE'},
          {'filePath': filePath, 'oldString': 'two', 'newString': 'TWO'},
          {'filePath': filePath, 'oldString': 'three', 'newString': 'THREE'},
          {'filePath': filePath, 'oldString': 'four', 'newString': 'FOUR'},
          {'filePath': filePath, 'oldString': 'five', 'newString': 'FIVE'},
        ];

        // Mirror chat_service.dart's dispatch loop exactly.
        final results = <ToolResult>[];
        for (var i = 0; i < edits.length; i++) {
          final call = ToolCall(
            callId: 'seq_$i',
            name: 'edit',
            input: edits[i],
          );
          results.add(await executor.executeTool(call, ctx()));
        }

        for (final r in results) {
          expect(r.output, contains('Replaced'));
        }

        final after = await File(filePath).readAsString();
        expect(after, 'ONE\nTWO\nTHREE\nFOUR\nFIVE');
      },
    );
  });

  // ─────────────────────────────────────────────────────────────────
  // write
  // ─────────────────────────────────────────────────────────────────

  group('parallel write calls to the same file', () {
    Future<List<ToolResult>> runWrites(List<Map<String, dynamic>> inputs) {
      final calls = <ToolCall>[];
      for (var i = 0; i < inputs.length; i++) {
        calls.add(ToolCall(
          callId: 'call_$i',
          name: 'write',
          input: inputs[i],
        ));
      }
      // Fire all writes concurrently — the worst case for a
      // read-then-write cycle that lacks serialization.
      return Future.wait(
        calls.map((c) => executor.executeTool(c, ctx())),
      );
    }

    test(
      'five concurrent writes to the same file all apply in '
      'emission order (Future.wait simulates parallel dispatch)',
      () async {
        // Build a file with five distinct payloads. Each write
        // targets the same path; if all five writes apply in
        // emission order, the file's final content is the LAST
        // payload written (later writes win, but every payload
        // was at least *applied* — the lock guarantees no write
        // is silently dropped). The intermediate `result.output`
        // strings should each show a successful write.
        final filePath = '${tempDir.path}/overwrite.txt';
        await File(filePath).writeAsString('initial');
        await markRead(filePath);

        const payloads = [
          'PAYLOAD_A',
          'PAYLOAD_B',
          'PAYLOAD_C',
          'PAYLOAD_D',
          'PAYLOAD_E',
        ];

        final inputs = payloads
            .map(
              (p) => <String, dynamic>{
                'filePath': filePath,
                'content': p,
                'intent': 'write $p',
              },
            )
            .toList();

        final results = await runWrites(inputs);

        // Every write must report success.
        for (final r in results) {
          expect(
            r.output,
            contains('File written'),
            reason: 'every parallel write must report success, got: ${r.output}',
          );
        }

        // Final content is exactly the LAST payload (emission
        // order = application order). If the lock failed, the
        // final content would be one of the earlier payloads
        // (whichever wrote last in the race).
        final after = await File(filePath).readAsString();
        expect(
          after,
          payloads.last,
          reason: 'final file content must be the last emitted payload, got: $after',
        );
      },
    );

    test(
      'the chat_service dispatch pattern (sequential for-await) '
      'applies all writes — confirming the production path is safe',
      () async {
        final filePath = '${tempDir.path}/seq.txt';
        await File(filePath).writeAsString('start');
        await markRead(filePath);

        const payloads = ['ONE', 'TWO', 'THREE', 'FOUR', 'FIVE'];

        // Mirror chat_service.dart's dispatch loop exactly.
        final results = <ToolResult>[];
        for (var i = 0; i < payloads.length; i++) {
          final call = ToolCall(
            callId: 'seq_$i',
            name: 'write',
            input: {
              'filePath': filePath,
              'content': payloads[i],
              'intent': 'write ${payloads[i]}',
            },
          );
          results.add(await executor.executeTool(call, ctx()));
        }

        for (final r in results) {
          expect(r.output, contains('File written'));
        }

        final after = await File(filePath).readAsString();
        expect(after, payloads.last);
      },
    );
  });
}
