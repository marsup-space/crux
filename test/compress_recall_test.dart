// Tests for the tool-argument offload flow:
//   - ToolExecutor.compressCallForPersistence replaces large args
//     in the persisted tool_call with a stand-in pointer and saves
//     the full bytes to offloaded_content.
//   - RecallTool recovers the full bytes via getOffloadedContent,
//     and returns a fallback message when the row is gone.
//
// These tests use a real (in-process) CruxDatabase so the full
// save/roundtrip path is exercised, not a mock.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'package:crux/src/services/tool_executor.dart';
import 'package:crux/src/storage/storage.dart';
import 'package:crux/src/tools/registry.dart';
import 'package:crux/src/tools/file_read_tracker.dart';

void main() {
  late Directory tempDir;
  late CruxDatabase db;
  late SessionStore store;
  late ToolRegistry registry;
  late ToolExecutor executor;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('crux_offload_');
    // In-memory DB so each test gets a clean schema and parallel
    // test files don't race on the user's on-disk data dir.
    db = CruxDatabase.forTesting(NativeDatabase.memory());
    store = SessionStore(db);
    registry = ToolRegistry()..registerDefaults(FileReadTracker());
    executor = ToolExecutor(registry, store.messageStore);
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('compressCallForPersistence', () {
    test('write.content is never off-loaded, even at large sizes',
        () async {
      // Create a session to scope the offloaded_content row.
      final session = await store.create(model: 'test/test');

      // Generate content larger than the 2 KB threshold.
      final largeContent = 'x' * 5000;
      final call = ToolCall(
        callId: 'call_abc',
        name: 'write',
        input: {'filePath': 'foo.py', 'content': largeContent, 'intent': '...'},
      );

      final compressed = await executor.compressCallForPersistence(
        call,
        session.id,
      );

      // WriteTool opted out of the LargePayloadTool offload
      // pipeline, so the input is returned unchanged — the full
      // content stays in the conversation context for the LLM
      // to reference on subsequent turns without a recall.
      expect(compressed.callId, 'call_abc');
      expect(compressed.name, 'write');
      expect(compressed.input['filePath'], 'foo.py');
      expect(compressed.input['intent'], '...');
      expect(compressed.input['content'], largeContent,
          reason: 'write content must be preserved verbatim');
      // No offloaded_content row should exist for this call.
      expect(
        await store.messageStore.getOffloadedContent(
          session.id,
          'call_abc_content',
        ),
        isNull,
      );
    });

    test('write.content is left untouched at small sizes too', () async {
      final session = await store.create(model: 'test/test');
      final smallContent = 'hello world'; // 11 bytes, well under 2 KB
      final call = ToolCall(
        callId: 'call_small',
        name: 'write',
        input: {'filePath': 'foo.py', 'content': smallContent, 'intent': '...'},
      );

      final compressed = await executor.compressCallForPersistence(
        call,
        session.id,
      );

      // WriteTool doesn't offload at any size, so the input is
      // the same object (no stand-in). This is a regression test
      // — previously a "small write" was the escape hatch, but
      // we removed the entire offload for `write` since the
      // escape hatch didn't exist in practice (small changes go
      // through `edit`).
      expect(compressed.input['content'], smallContent);
      expect(
        await store.messageStore.getOffloadedContent(session.id, 'call_small'),
        isNull,
      );
    });

    test('large edit.oldString and edit.newString both get off-loaded',
        () async {
      final session = await store.create(model: 'test/test');
      final oldString = 'a' * 3000;
      final newString = 'b' * 3000;
      final call = ToolCall(
        callId: 'call_edit',
        name: 'edit',
        input: {
          'filePath': 'foo.py',
          'oldString': oldString,
          'newString': newString,
          'intent': '...',
        },
      );

      final compressed = await executor.compressCallForPersistence(
        call,
        session.id,
      );

      expect(compressed.input['oldString'], contains('offloaded'));
      expect(compressed.input['newString'], contains('offloaded'));
      expect(compressed.input['oldString'], contains('call_edit_oldString'));
      expect(compressed.input['newString'], contains('call_edit_newString'));
      expect(compressed.input['filePath'], 'foo.py');

      // Both args are independently recoverable via their composite
      // keys (callId + '_' + argKey). No overwriting because the
      // offloaded_content PK is (session_id, call_id) and the
      // composite key includes the arg name.
      final recoveredOld = await store.messageStore.getOffloadedContent(
        session.id,
        'call_edit_oldString',
      );
      final recoveredNew = await store.messageStore.getOffloadedContent(
        session.id,
        'call_edit_newString',
      );
      expect(recoveredOld, oldString);
      expect(recoveredNew, newString);
    });

    test('non-LargePayloadTool call is returned unchanged', () async {
      final session = await store.create(model: 'test/test');
      // bash has a 'command' arg that may be small or large, but
      // bash is not a LargePayloadTool, so nothing should be
      // off-loaded.
      final largeCommand = 'ls ' * 1000; // 3000 bytes
      final call = ToolCall(
        callId: 'call_bash',
        name: 'bash',
        input: {'command': largeCommand, 'description': 'list stuff'},
      );

      final compressed = await executor.compressCallForPersistence(
        call,
        session.id,
      );

      // Returned call is identical to the input (same content).
      expect(compressed.input['command'], largeCommand);
      expect(
        await store.messageStore.getOffloadedContent(session.id, 'call_bash'),
        isNull,
      );
    });

    test('non-String arg values are left untouched', () async {
      // If the LLM ever sends a non-String for an offloadable arg
      // (e.g. an int), the compressor should skip it gracefully
      // rather than crashing.
      final session = await store.create(model: 'test/test');
      final call = ToolCall(
        callId: 'call_weird',
        name: 'write',
        input: {
          'filePath': 'foo.py',
          // content is normally String; if it's missing or wrong
          // type, the compressor must not blow up.
          'content': null,
          'intent': '...',
        },
      );

      final compressed = await executor.compressCallForPersistence(
        call,
        session.id,
      );
      expect(compressed.input['content'], isNull);
      expect(
        await store.messageStore.getOffloadedContent(session.id, 'call_weird'),
        isNull,
      );
    });

    // compressCallForPersistence always compresses large args when
    // called directly; the *caller* (chat_service.dart) is
    // responsible for skipping compression when the tool's
    // read-before-write guard fires (result.metadata['guardTriggered']).
    // See the guard trigger check in chat_service.dart at line 709:
    //   if (tool is LargePayloadTool && guardTriggers.contains(callId))
    //     compressedToolCalls.add(call); // original — not compressed
    //
    // Note: as of the write-offload removal, this guard-skip path
    // only applies to `edit` (the only remaining LargePayloadTool).
  });

  group('session lifecycle', () {
    test('deleteSession cascades to offloaded_content', () async {
      final session = await store.create(model: 'test/test');
      await store.messageStore.saveOffloadedContent(
        sessionId: session.id,
        callId: 'call_z',
        toolName: 'write',
        byteSize: 7,
        lineCount: 1,
        content: 'goodbye',
      );

      // Confirm the row exists.
      expect(
        await store.messageStore.getOffloadedContent(session.id, 'call_z'),
        'goodbye',
      );

      // Delete the session; the FK CASCADE on offloaded_content
      // should clean up the row.
      await store.deleteSession(session.id);
      expect(
        await store.messageStore.getOffloadedContent(session.id, 'call_z'),
        isNull,
      );
    });

    test('archiveSession calls cleanOffloadedContent automatically', () async {
      final session = await store.create(model: 'test/test');
      await store.messageStore.saveOffloadedContent(
        sessionId: session.id,
        callId: 'call_a',
        toolName: 'write',
        byteSize: 100,
        lineCount: 1,
        content: 'x' * 100,
      );

      // Archive the session — should drop the offloaded bytes but
      // keep the session row itself.
      await store.archiveSession(session.id);
      expect(
        await store.messageStore.getOffloadedContent(session.id, 'call_a'),
        isNull,
      );
      // Session survives archive (just hidden from sidebar).
      final stillThere = await store.getById(session.id);
      expect(stillThere, isNotNull);
      expect(stillThere!.archivedAt, isNotNull);
    });
  });

  group('cleanOffloadedContent (direct)', () {
    test('returns the sum of byte_size across all rows deleted', () async {
      final session = await store.create(model: 'test/test');
      await store.messageStore.saveOffloadedContent(
        sessionId: session.id,
        callId: 'call_1',
        toolName: 'write',
        byteSize: 100,
        lineCount: 1,
        content: 'x' * 100,
      );
      await store.messageStore.saveOffloadedContent(
        sessionId: session.id,
        callId: 'call_2',
        toolName: 'write',
        byteSize: 250,
        lineCount: 1,
        content: 'y' * 250,
      );
      await store.messageStore.saveOffloadedContent(
        sessionId: session.id,
        callId: 'call_3',
        toolName: 'edit',
        byteSize: 50,
        lineCount: 1,
        content: 'z' * 50,
      );

      final freed = await store.messageStore.cleanOffloadedContent(session.id);
      expect(freed, 100 + 250 + 50); // 400
    });

    test('removes every row for the session', () async {
      final session = await store.create(model: 'test/test');
      for (final id in ['a', 'b', 'c']) {
        await store.messageStore.saveOffloadedContent(
          sessionId: session.id,
          callId: id,
          toolName: 'write',
          byteSize: 10,
          lineCount: 1,
          content: 'x' * 10,
        );
      }

      await store.messageStore.cleanOffloadedContent(session.id);

      for (final id in ['a', 'b', 'c']) {
        expect(
          await store.messageStore.getOffloadedContent(session.id, id),
          isNull,
          reason: 'row $id should be gone after clean',
        );
      }
    });

    test('does not touch other sessions rows', () async {
      final sessionA = await store.create(model: 'test/test');
      final sessionB = await store.create(model: 'test/test');
      await store.messageStore.saveOffloadedContent(
        sessionId: sessionA.id,
        callId: 'a_only',
        toolName: 'write',
        byteSize: 10,
        lineCount: 1,
        content: 'x' * 10,
      );
      await store.messageStore.saveOffloadedContent(
        sessionId: sessionB.id,
        callId: 'b_only',
        toolName: 'write',
        byteSize: 20,
        lineCount: 1,
        content: 'y' * 20,
      );

      // Clean only session A. Session B's row must survive.
      final freed = await store.messageStore.cleanOffloadedContent(sessionA.id);
      expect(freed, 10);
      expect(
        await store.messageStore.getOffloadedContent(sessionA.id, 'a_only'),
        isNull,
      );
      expect(
        await store.messageStore.getOffloadedContent(sessionB.id, 'b_only'),
        'y' * 20,
      );
    });

    test('returns 0 for a session with no offloaded rows', () async {
      final session = await store.create(model: 'test/test');
      final freed = await store.messageStore.cleanOffloadedContent(session.id);
      expect(freed, 0);
    });

    test('is idempotent — second call returns 0', () async {
      final session = await store.create(model: 'test/test');
      await store.messageStore.saveOffloadedContent(
        sessionId: session.id,
        callId: 'once',
        toolName: 'write',
        byteSize: 5,
        lineCount: 1,
        content: 'hello',
      );

      final first = await store.messageStore.cleanOffloadedContent(session.id);
      expect(first, 5);
      final second = await store.messageStore.cleanOffloadedContent(session.id);
      expect(second, 0);
    });
  });

  group('getAllOffloadedContentForCall', () {
    test('recovers write.content by callId prefix', () async {
      final session = await store.create(model: 'test/test');
      await store.messageStore.saveOffloadedContent(
        sessionId: session.id,
        callId: 'call_write_content',
        toolName: 'write',
        byteSize: 5000,
        lineCount: 50,
        content: 'x' * 5000,
        intent: 'test write',
      );

      final rows = await store.messageStore.getAllOffloadedContentForCall(
        session.id,
        'call_write',
      );
      expect(rows.length, 1);
      expect(rows.first.callId, 'call_write_content');
      expect(rows.first.content, 'x' * 5000);
    });

    test('recovers edit.oldString and edit.newString by callId prefix',
        () async {
      final session = await store.create(model: 'test/test');
      await store.messageStore.saveOffloadedContent(
        sessionId: session.id,
        callId: 'call_edit_oldString',
        toolName: 'edit',
        byteSize: 3000,
        lineCount: 30,
        content: 'a' * 3000,
      );
      await store.messageStore.saveOffloadedContent(
        sessionId: session.id,
        callId: 'call_edit_newString',
        toolName: 'edit',
        byteSize: 3000,
        lineCount: 30,
        content: 'b' * 3000,
      );

      final rows = await store.messageStore.getAllOffloadedContentForCall(
        session.id,
        'call_edit',
      );
      expect(rows.length, 2);
      final callIds = rows.map((r) => r.callId).toSet();
      expect(callIds, containsAll(['call_edit_oldString', 'call_edit_newString']));
    });

    test('returns empty list when no rows match', () async {
      final session = await store.create(model: 'test/test');
      final rows = await store.messageStore.getAllOffloadedContentForCall(
        session.id,
        'nonexistent',
      );
      expect(rows, isEmpty);
    });

    test('does not return rows from other sessions', () async {
      final sessionA = await store.create(model: 'test/test');
      final sessionB = await store.create(model: 'test/test');
      await store.messageStore.saveOffloadedContent(
        sessionId: sessionA.id,
        callId: 'call_shared_content',
        toolName: 'write',
        byteSize: 5000,
        lineCount: 50,
        content: 'session A content',
      );

      // Session B should not see session A's rows.
      final rowsB = await store.messageStore.getAllOffloadedContentForCall(
        sessionB.id,
        'call_shared',
      );
      expect(rowsB, isEmpty);

      // Session A should see its own rows.
      final rowsA = await store.messageStore.getAllOffloadedContentForCall(
        sessionA.id,
        'call_shared',
      );
      expect(rowsA.length, 1);
    });
  });
}
