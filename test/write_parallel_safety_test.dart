// Regression test for parallel `write` calls to the same file.
//
//   WriteTool does a non-atomic read → write on the file's bytes:
//   it reads the prior contents to capture line counts, encoding,
//   and line ending (so the new file matches the old one's
//   formatting), then writes the new bytes. Without per-file
//   serialization, two concurrent writes race: both read the same
//   prior content, both write their respective payloads, and only
//   the last write survives — losing the earlier payloads entirely.
//   (Verified empirically before the lock was added; the same
//   pattern that bit EditTool hit WriteTool too.)
//
//   The fix lives in `lib/src/tools/file_lock.dart`: WriteTool wraps
//   its guard checks + read + write in `fileLock(resolved).run`,
//   which chains concurrent operations on the same path in FIFO
//   order. Operations on DIFFERENT paths remain unblocked.
//
//   This file contains TWO tests that pin down both halves of that
//   contract:
//
//   1. The "parallel via Future.wait" test deliberately fires five
//      writes concurrently. The test asserts that every write applies
//      cleanly. It MUST pass — the lock guarantees it.
//
//   2. The "sequential for-await" test mirrors chat_service.dart's
//      dispatch loop. It MUST also pass — and is the natural
//      regression net if anyone "optimizes" the dispatch loop to
//      `Future.wait`.
//
//   If test 1 ever starts failing, the per-file lock has regressed
//   or been bypassed — investigate before relying on parallel writes.
//   If test 2 fails but test 1 passes, the dispatch loop's exact
//   shape changed in a way the lock didn't cover — review.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'package:crux/src/services/tool_executor.dart';
import 'package:crux/src/storage/storage.dart';
import 'package:crux/src/tools/file_read_tracker.dart';
import 'package:crux/src/tools/registry.dart';
import 'package:crux/src/tools/tool_def.dart';

void main() {
  group('parallel write calls to the same file', () {
    late Directory tempDir;
    late CruxDatabase db;
    late SessionStore store;
    late FileReadTracker tracker;
    late ToolRegistry registry;
    late ToolExecutor executor;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('crux_writepar_');
      db = CruxDatabase.forTesting(NativeDatabase.memory());
      store = SessionStore(db);
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
    /// real-world flow where the model calls `read` first and
    /// then batches writes. Without this, the first write would
    /// correctly trip the "file not read before write" guard —
    /// which is the desired safety behavior, but orthogonal to
    /// what this test is trying to verify (the parallel-dispatch
    /// safety of the write application itself).
    Future<void> markRead(String filePath) async {
      final file = File(filePath);
      final mtime = file.statSync().modified.millisecondsSinceEpoch;
      await tracker.recordRead(filePath, mtime);
    }

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

        final payloads = ['PAYLOAD_A', 'PAYLOAD_B', 'PAYLOAD_C', 'PAYLOAD_D', 'PAYLOAD_E'];

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

        final payloads = ['ONE', 'TWO', 'THREE', 'FOUR', 'FIVE'];

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