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
import 'package:crux/src/tools/read_tool.dart';
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
      executor = ToolExecutor(registry, store.messageStore);
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

    test('intent is included in the note when provided', () {
      final note = buildOffloadNote(
        callId: 'call_with_intent',
        offloadedArgs: const ['content'],
        intent: 'Write the config file',
      );
      expect(note, contains("intent: 'Write the config file'"));
      expect(note, contains('`content`'));
      expect(note, contains('call_with_intent_content'));
    });

    test('intent is omitted from the note when not provided', () {
      final note = buildOffloadNote(
        callId: 'call_no_intent',
        offloadedArgs: const ['content'],
      );
      expect(note, isNot(contains('intent:')));
      expect(note, contains('`content`'));
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
      await writeFile('huge.txt', '${'a' * 5000}SENTINEL${'b' * 5000}');
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

  group('Offload stand-in write guard', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('crux_standin_guard_');
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

    const standIn =
        '[offloaded: 42 lines / 3.0KB; recall via offloaded_content(key="call_x_newString")]';

    test('write refuses to write a standalone offload stand-in', () async {
      final filePath = '${tempDir.path}/target.txt';

      final result = await WriteTool().execute(
        {
          'filePath': filePath,
          'content': standIn,
          'intent': 'accidental placeholder write',
        },
        ctx(),
      );

      expect(result.output, contains('Refusing to write'));
      expect(result.output, contains('offloaded-content stand-in'));
      expect(await File(filePath).exists(), isFalse,
          reason: 'the guard must not create or modify the target');
    });

    test('write refuses an embedded offload stand-in line', () async {
      final filePath = '${tempDir.path}/target.txt';
      await File(filePath).writeAsString('original');

      final result = await WriteTool().execute(
        {
          'filePath': filePath,
          'content': 'before\n$standIn\nafter',
          'intent': 'accidental placeholder write',
          'force': true,
        },
        ctx(),
      );

      expect(result.output, contains('Refusing to write'));
      expect(await File(filePath).readAsString(), 'original',
          reason: 'force must not bypass the placeholder guard');
    });

    test('edit refuses to use an offload stand-in as replacement text',
        () async {
      final filePath = '${tempDir.path}/edit.txt';
      await File(filePath).writeAsString('hello world');

      final result = await EditTool().execute(
        {
          'filePath': filePath,
          'oldString': 'world',
          'newString': standIn,
          'intent': 'accidental placeholder replacement',
        },
        ctx(),
      );

      expect(result.output, contains('Refusing to write'));
      expect(result.output, contains('newString'));
      expect(await File(filePath).readAsString(), 'hello world');
    });

    test('edit can still target an existing stand-in in oldString for cleanup',
        () async {
      final filePath = '${tempDir.path}/polluted.txt';
      await File(filePath).writeAsString('before\n$standIn\nafter');

      final result = await EditTool().execute(
        {
          'filePath': filePath,
          'oldString': standIn,
          'newString': 'clean',
          'intent': 'remove accidental placeholder',
        },
        ctx(),
      );

      expect(result.output, contains('Edit applied'));
      expect(await File(filePath).readAsString(), 'before\nclean\nafter');
    });
  });

  group('WriteTool read-before-write guard (regression: session 1141)', () {
    late Directory tempDir;
    late FileReadTracker tracker;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('crux_guard_');
      tracker = FileReadTracker();
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

    test('first write to a new file succeeds without guard', () async {
      final filePath = '${tempDir.path}/new_file.dart';
      final tool = WriteTool(tracker: tracker);

      final result = await tool.execute(
        {
          'filePath': filePath,
          'content': 'hello world',
          'intent': 'create new file',
        },
        ctx(),
      );

      expect(result.output, contains('File written:'));
      expect(result.output, isNot(contains('[GUARD]')));
      expect(await File(filePath).readAsString(), 'hello world');
    });

    test('write tool records mtime after creating a new file, '
        'so a second write does NOT trigger guard', () async {
      // This is the correct behavior: the write tool creates the file
      // and records the read. The agent knows what it just wrote, so
      // a subsequent write in the same turn should not be blocked.
      final filePath = '${tempDir.path}/created_by_write.dart';
      final tool = WriteTool(tracker: tracker);

      await tool.execute(
        {
          'filePath': filePath,
          'content': 'initial content',
          'intent': 'create file',
        },
        ctx(),
      );

      final result = await tool.execute(
        {
          'filePath': filePath,
          'content': 'updated content',
          'intent': 'overwrite same-session file',
        },
        ctx(),
      );

      expect(result.output, contains('File written:'));
      expect(result.output, isNot(contains('[GUARD]')));
      expect(await File(filePath).readAsString(), 'updated content');
    });

    test('writing to a pre-existing file that was never read triggers guard '
        'and does NOT modify the file', () async {
      // Session 1141 scenario: a file exists on disk (from a previous
      // session, bash command, etc.) but the agent has never read it.
      // The write tool must block and return the file content so the
      // agent can retry.
      final filePath = '${tempDir.path}/preexisting.dart';

      // Simulate a pre-existing file (not created through the write tool,
      // so the tracker has no record of it).
      await File(filePath).writeAsString('original content from disk');

      final tool = WriteTool(tracker: tracker);
      final result = await tool.execute(
        {
          'filePath': filePath,
          'content': 'new content',
          'intent': 'overwrite without reading',
        },
        ctx(),
      );

      expect(result.output, contains('[GUARD]'));
      expect(result.output, contains('BLOCKED'));
      expect(result.output, contains('not read before write'));
      expect(result.metadata['guardTriggered'], isTrue);
      // The guard must include the file content so the agent can retry.
      expect(result.output, contains('original content from disk'));

      // The file must be unchanged — the guard blocked the write.
      expect(await File(filePath).readAsString(), 'original content from disk',
          reason: 'guard must block the write; file content must be unchanged');
    });

    test('after guard auto-read on a pre-existing file, a subsequent '
        'write succeeds', () async {
      final filePath = '${tempDir.path}/retry_preexisting.dart';
      await File(filePath).writeAsString('version one on disk');

      final tool = WriteTool(tracker: tracker);

      // First write attempt — guard triggers (file never read),
      // but the guard's auto-read records the mtime.
      final guardResult = await tool.execute(
        {
          'filePath': filePath,
          'content': 'should not be written',
          'intent': 'overwrite without read',
        },
        ctx(),
      );
      expect(guardResult.output, contains('[GUARD]'));

      // Now the agent retries — the guard auto-read recorded the mtime,
      // so this should succeed.
      final retryResult = await tool.execute(
        {
          'filePath': filePath,
          'content': 'version two',
          'intent': 'overwrite after guard auto-read',
        },
        ctx(),
      );

      expect(retryResult.output, contains('File written:'));
      expect(retryResult.output, isNot(contains('[GUARD]')));
      expect(await File(filePath).readAsString(), 'version two');
    });

    test('read then write on a pre-existing file does not trigger guard',
        () async {
      final filePath = '${tempDir.path}/read_then_write.dart';
      await File(filePath).writeAsString('original');

      final readTool = ReadTool(tracker: tracker);
      final writeTool = WriteTool(tracker: tracker);

      // Read the file first — this records the mtime in the tracker
      await readTool.execute({'filePath': filePath}, ctx());

      // Now write — guard should NOT trigger
      final result = await writeTool.execute(
        {
          'filePath': filePath,
          'content': 'updated',
          'intent': 'update after read',
        },
        ctx(),
      );

      expect(result.output, contains('File written:'));
      expect(result.output, isNot(contains('[GUARD]')));
      expect(await File(filePath).readAsString(), 'updated');
    });

    test('EditTool guard on a pre-existing unread file does not modify file',
        () async {
      final filePath = '${tempDir.path}/edit_preexisting.dart';
      await File(filePath).writeAsString('alpha\nbeta\ngamma\n');

      final editTool = EditTool(tracker: tracker);

      // Edit without reading — guard must trigger
      final result = await editTool.execute(
        {
          'filePath': filePath,
          'oldString': 'beta',
          'newString': 'replaced',
          'intent': 'edit without read',
        },
        ctx(),
      );

      expect(result.output, contains('[GUARD]'));
      expect(result.metadata['guardTriggered'], isTrue);
      // File must be unchanged
      expect(await File(filePath).readAsString(), 'alpha\nbeta\ngamma\n',
          reason: 'guard must block the edit; file content must be unchanged');
    });

    test('guard does NOT trigger for a non-existent file (new file creation)',
        () async {
      // Brand-new file: no guard, any write is legitimate.
      final filePath = '${tempDir.path}/brand_new.dart';
      final tool = WriteTool(tracker: tracker);

      final result = await tool.execute(
        {
          'filePath': filePath,
          'content': 'fresh content',
          'intent': 'create new file',
        },
        ctx(),
      );

      expect(result.output, contains('File written:'));
      expect(result.output, isNot(contains('[GUARD]')));
      expect(await File(filePath).readAsString(), 'fresh content');
    });

    test('session 1141 exact sequence: guard → read → write should succeed',
        () async {
      // Exact reproduction of session 1141:
      // 1. File exists on disk (from previous session)
      // 2. Agent tries to write → guard triggers
      // 3. Agent reads the file (because guard said to)
      // 4. Agent writes again → should succeed
      final filePath = '${tempDir.path}/session1141.dart';
      await File(filePath).writeAsString('pre-existing content');

      final readTool = ReadTool(tracker: tracker);
      final writeTool = WriteTool(tracker: tracker);

      // Step 1: write without read → guard triggers
      final r1 = await writeTool.execute(
        {
          'filePath': filePath,
          'content': 'new content',
          'intent': 'overwrite',
        },
        ctx(),
      );
      expect(r1.output, contains('[GUARD]'));
      expect(r1.metadata['guardTriggered'], isTrue);
      expect(await File(filePath).readAsString(), 'pre-existing content');

      // Step 2: agent reads the file
      final r2 = await readTool.execute({'filePath': filePath}, ctx());
      expect(r2.output, contains('pre-existing content'));

      // Step 3: agent writes again — must succeed
      final r3 = await writeTool.execute(
        {
          'filePath': filePath,
          'content': 'new content',
          'intent': 'overwrite after read',
        },
        ctx(),
      );
      expect(r3.output, contains('File written:'),
          reason: 'after reading the file, the write must succeed');
      expect(r3.output, isNot(contains('[GUARD]')));
      expect(await File(filePath).readAsString(), 'new content');
    });

    test('session 1141 exact sequence: guard auto-read → write should succeed '
        '(without explicit read)', () async {
      // The guard's auto-read already records the mtime, so the agent
      // should be able to write immediately without an explicit read.
      final filePath = '${tempDir.path}/session1141_autoread.dart';
      await File(filePath).writeAsString('pre-existing content');

      final writeTool = WriteTool(tracker: tracker);

      // Step 1: write without read → guard triggers (auto-reads)
      final r1 = await writeTool.execute(
        {
          'filePath': filePath,
          'content': 'new content',
          'intent': 'overwrite',
        },
        ctx(),
      );
      expect(r1.output, contains('[GUARD]'));

      // Step 2: write again — guard's auto-read already recorded mtime
      final r2 = await writeTool.execute(
        {
          'filePath': filePath,
          'content': 'new content',
          'intent': 'overwrite after guard auto-read',
        },
        ctx(),
      );
      expect(r2.output, contains('File written:'),
          reason: 'guard auto-read should have recorded mtime; '
              'second write must succeed');
      expect(r2.output, isNot(contains('[GUARD]')));
      expect(await File(filePath).readAsString(), 'new content');
    });

    test('session 1141 exact sequence: guard→read→edit→read→edit', () async {
      // The exact sequence from session 1141:
      // 1. Edit unread file → guard triggers (auto-read records mtime)
      // 2. Read the file explicitly
      // 3. Edit succeeds (recordRead after edit)
      // 4. Read the file again
      // 5. Edit again → must NOT trigger "not read before write" guard
      final filePath = '${tempDir.path}/session1141_full.dart';
      await File(filePath).writeAsString('alpha\nbeta\ngamma\ndelta\n');

      final readTool = ReadTool(tracker: tracker);
      final editTool = EditTool(tracker: tracker);

      // Step 1: edit unread file → guard
      final r1 = await editTool.execute(
        {
          'filePath': filePath,
          'oldString': 'beta',
          'newString': 'BETA',
          'intent': 'replace beta',
        },
        ctx(),
      );
      expect(r1.output, contains('[GUARD]'));
      expect(r1.metadata['guardTriggered'], isTrue);
      expect(await File(filePath).readAsString(), 'alpha\nbeta\ngamma\ndelta\n');

      // Step 2: read the file
      final r2 = await readTool.execute({'filePath': filePath}, ctx());
      expect(r2.output, contains('beta'));

      // Step 3: edit succeeds
      final r3 = await editTool.execute(
        {
          'filePath': filePath,
          'oldString': 'beta',
          'newString': 'BETA',
          'intent': 'replace beta',
        },
        ctx(),
      );
      expect(r3.output, contains('Edit applied'));
      expect(r3.output, isNot(contains('[GUARD]')));

      // Step 4: read again
      final r4 = await readTool.execute({'filePath': filePath}, ctx());
      expect(r4.output, contains('BETA'));

      // Step 5: edit again — the bug: guard "not read before write"
      final r5 = await editTool.execute(
        {
          'filePath': filePath,
          'oldString': 'gamma',
          'newString': 'GAMMA',
          'intent': 'replace gamma',
        },
        ctx(),
      );
      expect(r5.output, contains('Edit applied'),
          reason: 'after edit+read+edit+read, a subsequent edit '
              'must NOT be guarded as "not read before write"');
      expect(r5.output, isNot(contains('[GUARD]')));
    });

    test('session 1141 exact sequence with relative paths: '
        'guard→read→edit→read→edit', () async {
      final subDir = '${tempDir.path}/lib/src/components';
      await Directory(subDir).create(recursive: true);
      final filePath = '$subDir/message_bubble.dart';
      await File(filePath).writeAsString('alpha\nbeta\ngamma\ndelta\n');

      final readTool = ReadTool(tracker: tracker);
      final editTool = EditTool(tracker: tracker);

      // Step 1: guard
      final r1 = await editTool.execute(
        {
          'filePath': 'lib/src/components/message_bubble.dart',
          'oldString': 'beta',
          'newString': 'BETA',
          'intent': 'replace beta',
        },
        ctx(),
      );
      expect(r1.output, contains('[GUARD]'));

      // Step 2: read
      await readTool.execute(
        {'filePath': 'lib/src/components/message_bubble.dart'},
        ctx(),
      );

      // Step 3: edit succeeds
      final r3 = await editTool.execute(
        {
          'filePath': 'lib/src/components/message_bubble.dart',
          'oldString': 'beta',
          'newString': 'BETA',
          'intent': 'replace beta',
        },
        ctx(),
      );
      expect(r3.output, contains('Edit applied'));

      // Step 4: read
      await readTool.execute(
        {'filePath': 'lib/src/components/message_bubble.dart'},
        ctx(),
      );

      // Step 5: edit again — must NOT guard
      final r5 = await editTool.execute(
        {
          'filePath': 'lib/src/components/message_bubble.dart',
          'oldString': 'gamma',
          'newString': 'GAMMA',
          'intent': 'replace gamma',
        },
        ctx(),
      );
      expect(r5.output, contains('Edit applied'),
          reason: 'relative-path edit after edit+read must not be guarded');
      expect(r5.output, isNot(contains('[GUARD]')));
    });

    test('session 1141: guard → read → write using relative paths '
        '(same as agent uses)', () async {
      // The agent uses relative paths like "lib/src/components/foo.dart"
      // while the working directory is the project root. This test
      // ensures path normalization doesn't break the tracker.
      final subDir = '${tempDir.path}/lib/src/components';
      await Directory(subDir).create(recursive: true);
      final filePath = '$subDir/relative.dart';
      await File(filePath).writeAsString('original');

      final readTool = ReadTool(tracker: tracker);
      final writeTool = WriteTool(tracker: tracker);

      // Write using relative path → guard
      final r1 = await writeTool.execute(
        {
          'filePath': 'lib/src/components/relative.dart',
          'content': 'new',
          'intent': 'overwrite',
        },
        ctx(),
      );
      expect(r1.output, contains('[GUARD]'));

      // Read using relative path
      await readTool.execute(
        {'filePath': 'lib/src/components/relative.dart'},
        ctx(),
      );

      // Write using relative path again — must succeed
      final r3 = await writeTool.execute(
        {
          'filePath': 'lib/src/components/relative.dart',
          'content': 'new',
          'intent': 'overwrite after read',
        },
        ctx(),
      );
      expect(r3.output, contains('File written:'),
          reason: 'relative path normalization must be consistent '
              'between read and write tools');
      expect(r3.output, isNot(contains('[GUARD]')));
    });

    test('tracker state survives simulated app restart via loadSession', () async {
      // Regression test for session 1141: tracker cache was lost on
      // app restart, causing false "not read before write" guards.
      // With persistence, the state is loaded from the DB.
      final filePath = '${tempDir.path}/persist_test.dart';
      await File(filePath).writeAsString('original content');

      final persisted = <(int, String, int)>[];
      final tracker1 = FileReadTracker(
        sessionId: 1,
        onRecordRead: (sid, path, mtime) async {
          persisted.add((sid, path, mtime));
        },
      );

      final readTool1 = ReadTool(tracker: tracker1);
      final editTool1 = EditTool(tracker: tracker1);

      // Read and edit with first tracker instance
      await readTool1.execute({'filePath': filePath}, ctx());
      final r1 = await editTool1.execute(
        {
          'filePath': filePath,
          'oldString': 'original content',
          'newString': 'edited content',
          'intent': 'edit after read',
        },
        ctx(),
      );
      expect(r1.output, contains('Edit applied'));
      expect(persisted.length, greaterThanOrEqualTo(2));

      // Simulate app restart: new tracker, load state from "DB"
      final savedState = <String, int>{};
      for (final (_, path, mtime) in persisted) {
        savedState[path] = mtime;
      }
      final tracker2 = FileReadTracker(
        sessionId: 1,
        onRecordRead: (sid, path, mtime) async {
          persisted.add((sid, path, mtime));
        },
      );
      tracker2.loadSession(1, savedState);

      // Edit with second tracker — should NOT trigger guard
      final editTool2 = EditTool(tracker: tracker2);
      final r2 = await editTool2.execute(
        {
          'filePath': filePath,
          'oldString': 'edited content',
          'newString': 'further edited',
          'intent': 'edit after restart',
        },
        ctx(),
      );
      expect(r2.output, contains('Edit applied'),
          reason: 'tracker state loaded from DB must prevent '
              'false "not read before write" guard after restart');
      expect(r2.output, isNot(contains('[GUARD]')));
    });
  });
}
