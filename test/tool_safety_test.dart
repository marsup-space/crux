// Regression tests for two LLM-tooling foot-guns observed in
// session 1208 "Debug FPS counter in side panel":
//
//   1. The offload stand-in pointer (`compressCallForPersistence`)
//      used the format `[N lines, BKB]` — visually similar to a
//      numbered `read` line, so the LLM would copy it into a
//      subsequent `edit` / `write` and corrupt the file. The fix
//      makes the stand-in unambiguous and includes the recall
//      callId so the LLM has a way to recover the bytes.
//
//   2. `WriteTool` happily overwrote a 16.9KB / 463-line file
//      with a 19-char payload, because nothing checked that the
//      new content was "approximately the size of the existing
//      file." The fix adds a size guard that fires only when the
//      shape clearly looks like an edit-mistake and provides a
//      `force: true` escape hatch.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'package:crux/src/services/tool_executor.dart';
import 'package:crux/src/storage/storage.dart';
import 'package:crux/src/tools/edit_tool.dart';
import 'package:crux/src/tools/file_read_tracker.dart';
import 'package:crux/src/tools/registry.dart';
import 'package:crux/src/tools/tool_def.dart';
import 'package:crux/src/tools/write_tool.dart';

void main() {
  group('compressCallForPersistence stand-in format', () {
    late CruxDatabase db;
    late SessionStore store;
    late ToolRegistry registry;
    late ToolExecutor executor;

    setUp(() {
      db = CruxDatabase.forTesting(NativeDatabase.memory());
      store = SessionStore(db);
      registry = ToolRegistry()..registerDefaults(FileReadTracker());
      executor = ToolExecutor(registry, store);
    });

    tearDown(() async {
      await db.close();
    });

    test(
        'large write.content stand-in does not look like a numbered file line',
        () async {
      // Bug repro: stand-in used to be `[73 lines, 2.6KB]`, which
      // is visually adjacent to a `read` line numbered as
      // `430: [73 lines, 2.6KB]super.dispose();`. The LLM
      // sometimes pasted the stand-in into a subsequent edit,
      // polluting the file. The new format must NOT start with
      // `[\d+ lines` (the file-line-looking pattern).
      final session = await store.create(model: 'test/test');
      final largeContent = 'x' * 5000;
      final call = ToolCall(
        callId: 'call_abc',
        name: 'write',
        input: {
          'filePath': 'foo.py',
          'content': largeContent,
          'intent': '...',
        },
      );

      final compressed = await executor.compressCallForPersistence(
        call,
        session.id,
      );

      final standIn = compressed.input['content'] as String;
      expect(standIn, isNot(equals(largeContent)));
      expect(standIn, contains('KB'),
          reason: 'size should be reported in the stand-in');
      // The dangerous pattern: starts with `[<digits> lines`.
      // If this ever matches, the LLM can mistake it for a `read`
      // line prefix and paste it into a file.
      expect(
        RegExp(r'^\[\d+ lines').hasMatch(standIn),
        isFalse,
        reason: 'stand-in must not look like a `read` line prefix',
      );
    });

    test('stand-in includes the recall callId so LLM can recover bytes',
        () async {
      // Docstring at `tool_executor.dart` and `tables.dart`
      // promises the stand-in includes `recall: <callId>`, but
      // the implementation only emitted `[N lines, BKB]`. The
      // LLM had no way to recover the bytes. The fix restores
      // the documented contract.
      final session = await store.create(model: 'test/test');
      final largeContent = 'x' * 5000;
      final call = ToolCall(
        callId: 'call_abc',
        name: 'write',
        input: {
          'filePath': 'foo.py',
          'content': largeContent,
          'intent': '...',
        },
      );

      final compressed = await executor.compressCallForPersistence(
        call,
        session.id,
      );

      final standIn = compressed.input['content'] as String;
      expect(standIn, contains('call_abc'),
          reason: 'stand-in must reference the callId for recall');
      // And the composite key (callId + arg name) is what's
      // stored in offloaded_content, so it must also be visible
      // so the LLM can name it correctly when recovering.
      expect(standIn, contains('call_abc_content'),
          reason: 'stand-in must reference the composite key');
    });

    test(
        'large edit.oldString and edit.newString both produce unambiguous stand-ins',
        () async {
      // Each arg of an edit is off-loaded independently and gets
      // its own stand-in. They must both be unambiguous and must
      // each reference their own composite key so the LLM can
      // pick the right one when recalling.
      final session = await store.create(model: 'test/test');
      final call = ToolCall(
        callId: 'call_edit',
        name: 'edit',
        input: {
          'filePath': 'foo.py',
          'oldString': 'a' * 3000,
          'newString': 'b' * 3000,
          'intent': '...',
        },
      );

      final compressed = await executor.compressCallForPersistence(
        call,
        session.id,
      );

      final oldStandIn = compressed.input['oldString'] as String;
      final newStandIn = compressed.input['newString'] as String;
      expect(RegExp(r'^\[\d+ lines').hasMatch(oldStandIn), isFalse);
      expect(RegExp(r'^\[\d+ lines').hasMatch(newStandIn), isFalse);
      expect(oldStandIn, contains('call_edit_oldString'));
      expect(newStandIn, contains('call_edit_newString'));
      expect(oldStandIn, isNot(equals(newStandIn)));
    });
  });

  group('WriteTool size guard (regression: session 1208 silent truncation)',
      () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('crux_writesize_');
    });

    tearDown(() async {
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

    test(
        'refuses to overwrite a large existing file with a tiny payload',
        () async {
      // Bug repro: agent called `write` with 19 chars on a
      // 16.9KB / 463-line file, the tool wrote all 19 chars and
      // nuked the rest. The new guard must reject this and point
      // the LLM at `edit`.
      final filePath = '${tempDir.path}/big.dart';
      final existing =
          List.generate(463, (i) => 'line $i of the existing file').join('\n');
      await File(filePath).writeAsString(existing);
      final originalSize = await File(filePath).length();
      final originalLineCount =
          await File(filePath).readAsString().then((s) => '\n'.allMatches(s).length + 1);

      final result = await WriteTool().execute(
        {
          'filePath': filePath,
          'content': 'super.dispose();',
          'intent': '...',
        },
        ctx(),
      );

      // File is untouched.
      final afterSize = await File(filePath).length();
      expect(afterSize, originalSize,
          reason: 'guard must not have written anything');
      // Error points the LLM at `edit`.
      expect(result.output.toLowerCase(), contains('edit'),
          reason: 'guard error should suggest the `edit` tool');
      // Error reports the size gap so the LLM sees the mismatch.
      expect(result.output, contains('$originalLineCount'),
          reason: 'guard error should report the existing line count');
    });

    test('guard does NOT fire when the new content is similar in size',
        () async {
      // Sanity: a legitimate full-file rewrite that happens to
      // change size a little (e.g. trailing newline, reflow)
      // must not be refused.
      final filePath = '${tempDir.path}/medium.dart';
      final existing = List.generate(200, (i) => 'line $i').join('\n');
      await File(filePath).writeAsString(existing);

      // New content is ~80% of the old — clearly a rewrite, not
      // a snippet.
      final newContent =
          List.generate(160, (i) => 'rewritten line $i').join('\n');
      final result = await WriteTool().execute(
        {
          'filePath': filePath,
          'content': newContent,
          'intent': '...',
        },
        ctx(),
      );

      final after = await File(filePath).readAsString();
      expect(after, newContent);
      expect(result.output.toLowerCase(),
          isNot(contains('looks like an edit')),
          reason: 'guard should not have fired on a similar-size rewrite');
    });

    test('guard does NOT fire when the file does not exist', () async {
      // Brand-new file: writing any size is legitimate.
      final filePath = '${tempDir.path}/new.dart';
      final result = await WriteTool().execute(
        {
          'filePath': filePath,
          'content': 'tiny new file',
          'intent': '...',
        },
        ctx(),
      );

      expect(await File(filePath).readAsString(), 'tiny new file');
      expect(result.output.toLowerCase(),
          isNot(contains('looks like an edit')));
    });

    test('guard does NOT fire on small existing files', () async {
      // Tiny config files: agent may legitimately overwrite a
      // 6-line file with 1 line (e.g. replacing the entire
      // contents with a different setting).
      final filePath = '${tempDir.path}/small.txt';
      await File(filePath).writeAsString('a\nb\nc\nd\ne\nf\n');

      final result = await WriteTool().execute(
        {
          'filePath': filePath,
          'content': 'single value',
          'intent': '...',
        },
        ctx(),
      );

      expect(await File(filePath).readAsString(), 'single value');
      expect(result.output.toLowerCase(),
          isNot(contains('looks like an edit')));
    });

    test('force:true bypasses the guard and proceeds with the write',
        () async {
      // Escape hatch for the legitimate "rewrite the whole file"
      // case (e.g. switching a file to a stub during refactor).
      final filePath = '${tempDir.path}/big2.dart';
      final existing =
          List.generate(463, (i) => 'line $i of the existing file').join('\n');
      await File(filePath).writeAsString(existing);

      final result = await WriteTool().execute(
        {
          'filePath': filePath,
          'content': 'super.dispose();',
          'intent': '...',
          'force': true,
        },
        ctx(),
      );

      expect(await File(filePath).readAsString(), 'super.dispose();');
      expect(result.output, contains('File written:'));
    });
  });

  group('buildOffloadNote (helper)', () {
    test('returns empty string when no args are offloaded', () {
      expect(
        buildOffloadNote(callId: 'call_x', offloadedArgs: const []),
        isEmpty,
      );
    });

    test('singular form: "the `foo` argument ... was moved ... it"', () {
      final note = buildOffloadNote(
        callId: 'call_abc',
        offloadedArgs: const ['newString'],
      );
      expect(note, contains('`newString`'));
      expect(note, contains('was moved'));
      expect(note, isNot(contains('were moved')),
          reason: 'singular: "was" not "were"');
      expect(note, contains('substitute for it'));
      expect(note, contains('`call_abc_newString`'),
          reason: 'composite key must reference the callId and arg name');
    });

    test('plural form for two offloaded args: "were moved ... them"', () {
      final note = buildOffloadNote(
        callId: 'call_xyz',
        offloadedArgs: const ['oldString', 'newString'],
      );
      expect(note, contains('`oldString` and `newString`'));
      expect(note, contains('were moved'));
      expect(note, contains('substitute for them'));
      expect(note, contains('`call_xyz_oldString`'));
      expect(note, contains('`call_xyz_newString`'));
    });

    test('three or more args use Oxford comma', () {
      final note = buildOffloadNote(
        callId: 'call_multi',
        offloadedArgs: const ['a', 'b', 'c'],
      );
      expect(note, contains('`a`, `b`, and `c`'));
    });
  });

  group('EditTool result message includes the offload note', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('crux_edit_offload_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    ToolContext ctxWithCallId(String callId) => ToolContext(
          sessionId: 1,
          messageId: 1,
          abort: AbortSignal(),
          callId: callId,
          workingDirectory: tempDir.path,
        );

    Future<void> writeFile(String name, String content) async {
      await File('${tempDir.path}/$name').writeAsString(content);
    }

    test('small edit (no offload) does not append the offload note',
        () async {
      await writeFile('small.txt', 'hello world\n');
      final result = await EditTool().execute(
        {
          'filePath': '${tempDir.path}/small.txt',
          'oldString': 'hello',
          'newString': 'goodbye',
          'intent': 'rename greeting',
        },
        ctxWithCallId('call_small'),
      );

      expect(result.output, contains('Edit applied to'));
      expect(result.output, contains('rename greeting'));
      expect(result.output, contains('Replaced 1 occurrence'));
      expect(result.output, isNot(contains('offloaded_content')),
          reason: 'no offload happened, no note should appear');
    });

    test('large newString triggers an offload note for newString only',
        () async {
      await writeFile('big.txt', 'AAA_BBB_CCC');
      final result = await EditTool().execute(
        {
          'filePath': '${tempDir.path}/big.txt',
          'oldString': 'BBB',
          'newString': 'b' * 5000,
          'intent': 'rewrite the file',
        },
        ctxWithCallId('call_edit_x'),
      );

      expect(result.output, contains('Edit applied to'));
      expect(result.output, contains('call_edit_x_newString'),
          reason: 'composite key must appear so the LLM can name it');
      expect(result.output, contains('`newString`'),
          reason: 'the note must name which argument was offloaded');
      expect(result.output, isNot(contains('`oldString`')),
          reason: 'oldString was small and must NOT be listed');
    });

    test('both oldString and newString over the threshold are both listed',
        () async {
      await writeFile('huge.txt', 'a' * 5000 + 'SENTINEL' + 'b' * 5000);
      final oldStr = 'a' * 5000;
      final newStr = 'B' * 5000;
      final result = await EditTool().execute(
        {
          'filePath': '${tempDir.path}/huge.txt',
          'oldString': oldStr,
          'newString': newStr,
          'intent': 'swap large block',
        },
        ctxWithCallId('call_edit_y'),
      );

      expect(result.output, contains('`oldString` and `newString`'));
      expect(result.output, contains('call_edit_y_oldString'));
      expect(result.output, contains('call_edit_y_newString'));
    });

    test('offload note is suppressed when ctx.callId is null', () async {
      // Defensive: if the chat service ever forgets to wire the
      // callId into the context, the tool should not produce a
      // note with a phantom "callId_" prefix. Empty callId is
      // a misconfiguration, not a useful signal to the agent.
      final ctxNoCallId = ToolContext(
        sessionId: 1,
        messageId: 1,
        abort: AbortSignal(),
        workingDirectory: tempDir.path,
      );
      await writeFile('big2.txt', 'XXX_YYY_ZZZ');
      final result = await EditTool().execute(
        {
          'filePath': '${tempDir.path}/big2.txt',
          'oldString': 'YYY',
          'newString': 'y' * 5000,
          'intent': '...',
        },
        ctxNoCallId,
      );
      expect(result.output, isNot(contains('offloaded_content')));
    });
  });

  group('WriteTool result message includes the offload note', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('crux_write_offload_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('small write (no offload) does not append the offload note',
        () async {
      final filePath = '${tempDir.path}/small.dart';
      final result = await WriteTool().execute(
        {
          'filePath': filePath,
          'content': 'hello',
          'intent': 'create new file',
        },
        ToolContext(
          sessionId: 1,
          messageId: 1,
          abort: AbortSignal(),
          callId: 'call_w_small',
          workingDirectory: tempDir.path,
        ),
      );

      expect(result.output, contains('File written:'));
      expect(result.output, contains('create new file'));
      expect(result.output, isNot(contains('offloaded_content')));
    });

    test('large write triggers an offload note for content', () async {
      final filePath = '${tempDir.path}/big.dart';
      final result = await WriteTool().execute(
        {
          'filePath': filePath,
          'content': 'x' * 5000,
          'intent': 'create big file',
        },
        ToolContext(
          sessionId: 1,
          messageId: 1,
          abort: AbortSignal(),
          callId: 'call_w_big',
          workingDirectory: tempDir.path,
        ),
      );

      expect(result.output, contains('File written:'));
      expect(result.output, contains('create big file'));
      expect(result.output, contains('call_w_big_content'),
          reason: 'composite key must appear so the LLM can name it');
      expect(result.output, contains('`content`'));
    });
  });
}
