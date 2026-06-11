import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:crux/src/tools/tool_def.dart';
import 'package:crux/src/tools/registry.dart';
import 'package:crux/src/tools/file_read_tracker.dart';
import 'package:crux/src/services/llm_client.dart';
import 'package:crux/src/services/tool_executor.dart';
import 'package:crux/src/tools/bash_tool.dart';
import 'package:path/path.dart' as p;
import 'package:crux/src/tools/cmd_tool.dart';
import 'package:crux/src/tools/glob_tool.dart';
import 'package:crux/src/tools/grep_tool.dart';
import 'package:crux/src/tools/powershell_tool.dart';
import 'package:crux/src/tools/read_tool.dart';
import 'package:crux/src/tools/edit_tool.dart';
import 'package:crux/src/tools/write_tool.dart';
import 'package:crux/src/tools/matchers/exact_matcher.dart';
import 'package:crux/src/tools/matchers/whitespace_matcher.dart';
import 'package:crux/src/tools/matchers/indentation_matcher.dart';
import 'package:crux/src/utils/token_estimate.dart';
import 'package:crux/src/storage/storage.dart';

void main() {
  group('resolvePath', () {
    test('returns absolute path unchanged', () {
      final absolute = Platform.isWindows
          ? r'C:\home\user\file.txt'
          : '/home/user/file.txt';
      final cwd = Platform.isWindows ? r'C:\home\user' : '/home/user';
      expect(resolvePath(absolute, cwd), absolute);
    });

    test('resolves relative path against working directory', () {
      final cwd = Platform.isWindows ? r'C:\home\user\project' : '/home/user/project';
      final result = resolvePath('src/main.dart', cwd);
      expect(p.basename(result), 'main.dart');
      expect(p.dirname(result), p.join(cwd, 'src'));
    });

    test('resolves dot-relative path', () {
      final cwd = Platform.isWindows ? r'C:\home\user\project' : '/home/user/project';
      final result = resolvePath('./lib/app.dart', cwd);
      expect(p.basename(result), 'app.dart');
      expect(p.dirname(result), endsWith(p.join('lib')));
    });
  });

  group('ToolRegistry', () {
    late ToolRegistry registry;

    setUp(() {
      registry = ToolRegistry();
    });

    test('register and lookup are case-insensitive', () {
      registry.register(BashTool());
      expect(registry.lookup('bash'), isNotNull);
      expect(registry.lookup('Bash'), isNotNull);
      expect(registry.lookup('BASH'), isNotNull);
    });

    test('lookup returns null for unknown tool', () {
      expect(registry.lookup('unknown'), isNull);
    });

    test('all returns all registered tools', () {
      registry.register(BashTool());
      registry.register(ReadTool());
      expect(registry.all.length, 2);
      expect(registry.all.any((t) => t.name == 'bash'), isTrue);
      expect(registry.all.any((t) => t.name == 'read'), isTrue);
    });

    test('toApiTools produces valid API definitions', () {
      registry.register(BashTool());
      final apiTools = registry.toApiTools();
      expect(apiTools.length, 1);
      expect(apiTools[0]['name'], 'bash');
      expect(apiTools[0]['description'], isNotNull);
      expect(apiTools[0]['parameters'], isNotNull);
    });

    test('registerDefaults registers all 7 tools', () {
      final tracker = FileReadTracker();
      final registry = ToolRegistry();
      registry.registerDefaults(tracker);
      final names = registry.all.map((t) => t.name).toList();
      final expectedShell = Platform.isWindows ? 'cmd' : 'bash';
      expect(
        names,
        containsAll([
          expectedShell,
          'read',
          'write',
          'edit',
          'grep',
          'glob',
          'webfetch',
        ]),
      );
      if (Platform.isWindows) {
        expect(names, contains('powershell'));
        expect(registry.all.length, 8);
      } else {
        expect(names, isNot(contains('powershell')));
        expect(names, isNot(contains('cmd')));
        expect(registry.all.length, 7);
      }
    });
  });

  group('ToolDef', () {
    test('BashTool has correct name and schema', () {
      final tool = BashTool();
      expect(tool.name, 'bash');
      expect(tool.parametersSchema['required'], contains('command'));
    });

    test('ReadTool has correct name and schema', () {
      final tool = ReadTool();
      expect(tool.name, 'read');
      expect(tool.parametersSchema['required'], contains('filePath'));
    });
  });

  group('ToolResult', () {
    test('error factory creates error result', () {
      final result = ToolResult.error('something went wrong');
      expect(result.title, 'Error');
      expect(result.output, 'something went wrong');
      expect(result.truncated, isFalse);
    });
  });

  group('AbortSignal', () {
    test('initial state is not aborted', () {
      final signal = AbortSignal();
      expect(signal.isAborted, isFalse);
    });

    test('abort sets isAborted to true', () {
      final signal = AbortSignal();
      signal.abort();
      expect(signal.isAborted, isTrue);
    });
  });

  group('FileReadTracker', () {
    late FileReadTracker tracker;
    late Directory tempDir;

    setUp(() async {
      tracker = FileReadTracker();
      tempDir = await Directory.systemTemp.createTemp('crux_tracker_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'recordRead and checkWriteGuard returns null for fresh file',
      () async {
        final file = File('${tempDir.path}/fresh.txt');
        await file.writeAsString('hello');
        final mtime = file.statSync().modified.millisecondsSinceEpoch;
        tracker.recordRead(file.path, mtime);
        final guard = tracker.checkWriteGuard(file.path);
        expect(guard, isNull);
      },
    );

    test(
        'checkWriteGuard reads file for the agent and signals "you can write now"',
        () async {
      final file = File('${tempDir.path}/unread.txt');
      await file.writeAsString('content here');
      final guard = tracker.checkWriteGuard(file.path);
      expect(guard, isNotNull);
      expect(guard!.header, contains('[GUARD]'));
      expect(guard.header, contains('not read before write'));
      expect(guard.content, 'content here');
    });

    test(
        'checkWriteGuard reads file for the agent when file is modified, '
        'with a clear "pattern must match this version" hint', () async {
      final file = File('${tempDir.path}/modified.txt');
      await file.writeAsString('original');
      tracker.recordRead(
        file.path,
        file.statSync().modified.millisecondsSinceEpoch,
      );
      await Future.delayed(const Duration(milliseconds: 1500));
      await file.writeAsString('updated completely different content here');
      final guard = tracker.checkWriteGuard(file.path);
      expect(guard, isNotNull);
      expect(guard!.header, contains('We re-read it for you'));
      expect(guard.header, contains('retry your edit'));
      expect(guard.content, 'updated completely different content here');
    });

    test('toMap and loadFromMap preserve state', () {
      tracker.recordRead('/foo/bar.dart', 12345);
      tracker.recordRead('/baz/qux.dart', 67890);
      final map = tracker.toMap();
      final newTracker = FileReadTracker();
      newTracker.loadFromMap(map);
      expect(newTracker.toMap().length, 2);
    });
  });

  group('ExactMatcher', () {
    test('finds single exact match', () {
      final matcher = ExactMatcher();
      final result = matcher.findMatches('hello world foo', 'world', false);
      expect(result, isNotNull);
      expect(result!.positions.length, 1);
      expect(result!.positions[0], 6);
    });

    test('returns error for multiple matches when replaceAll is false', () {
      final matcher = ExactMatcher();
      final result = matcher.findMatches('aaa bbb aaa', 'aaa', false);
      expect(result, isNotNull);
      expect(result!.error, isNotNull);
    });

    test('finds all matches when replaceAll is true', () {
      final matcher = ExactMatcher();
      final result = matcher.findMatches('aaa bbb aaa', 'aaa', true);
      expect(result, isNotNull);
      expect(result!.positions.length, 2);
      expect(result!.error, isNull);
    });

    test('returns null when no match found', () {
      final matcher = ExactMatcher();
      final result = matcher.findMatches('hello', 'world', false);
      expect(result, isNull);
    });
  });

  group('WhitespaceMatcher', () {
    test('matches with whitespace normalization', () {
      final matcher = WhitespaceMatcher();
      final result = matcher.findMatches(
        'hello   world  foo',
        'hello world foo',
        false,
      );
      expect(result, isNotNull);
    });

    test('returns null when no match after normalization', () {
      final matcher = WhitespaceMatcher();
      final result = matcher.findMatches('hello', 'world', false);
      expect(result, isNull);
    });

    test('positions are in original content space, not normalized', () {
      final matcher = WhitespaceMatcher();
      final content = 'hello   world';
      final result = matcher.findMatches(content, 'hello world', false);
      expect(result, isNotNull);
      expect(result!.positions.length, 1);
      final pos = result.positions[0];
      expect(
        content.substring(pos, pos + 'hello   world'.length),
        equals('hello   world'),
      );
    });

    test('positions map correctly with leading whitespace', () {
      final matcher = WhitespaceMatcher();
      final content = '  hello   world';
      final result = matcher.findMatches(content, 'hello world', false);
      expect(result, isNotNull);
      expect(result!.positions.length, 1);
      final pos = result.positions[0];
      expect(content.substring(pos).startsWith('hello'), isTrue);
    });

    test('positions map correctly with tabs', () {
      final matcher = WhitespaceMatcher();
      final content = 'foo\tbar\tbaz';
      final result = matcher.findMatches(content, 'foo bar baz', false);
      expect(result, isNotNull);
      expect(result!.positions.length, 1);
      final pos = result.positions[0];
      expect(content.substring(pos), equals('foo\tbar\tbaz'));
    });

    test('replacement via WhitespaceMatcher does not corrupt file', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'crux_ws_edit_test_',
      );
      final file = File('${tempDir.path}/test.txt');
      await file.writeAsString('hello   world\nmore   text');

      final tool = EditTool();
      final ctx = ToolContext(
        sessionId: 1,
        messageId: 1,
        abort: AbortSignal(),
        workingDirectory: tempDir.path,
      );
      final result = await tool.execute({
        'filePath': 'test.txt',
        'oldString': 'hello world',
        'newString': 'hello universe',
      }, ctx);

      expect(result.output, contains('Replaced 1 occurrence'));
      final updated = await file.readAsString();
      expect(updated, equals('hello universe\nmore   text'));

      await tempDir.delete(recursive: true);
    });

    test('WhitespaceMatcher preserves surrounding content with tabs', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'crux_ws_tab_test_',
      );
      final file = File('${tempDir.path}/test.txt');
      await file.writeAsString('prefix\tfoo\tbar\tsuffix');

      final tool = EditTool();
      final ctx = ToolContext(
        sessionId: 1,
        messageId: 1,
        abort: AbortSignal(),
        workingDirectory: tempDir.path,
      );
      final result = await tool.execute({
        'filePath': 'test.txt',
        'oldString': 'foo bar',
        'newString': 'baz qux',
      }, ctx);

      expect(result.output, contains('Replaced 1 occurrence'));
      final updated = await file.readAsString();
      expect(updated, equals('prefix\tbaz qux\tsuffix'));

      await tempDir.delete(recursive: true);
    });
  });

  group('IndentationMatcher', () {
    test('matches with flexible indentation', () {
      final matcher = IndentationMatcher();
      final content = '    line one\n    line two';
      final pattern = 'line one\nline two';
      final result = matcher.findMatches(content, pattern, false);
      expect(result, isNotNull);
    });
  });

  group('BashTool execute', () {
    test('returns error for missing command', () async {
      final tool = BashTool();
      final ctx = ToolContext(
        sessionId: 1,
        messageId: 1,
        abort: AbortSignal(),
        workingDirectory: '/tmp',
      );
      final result = await tool.execute({}, ctx);
      expect(result.output, contains('Missing required parameter'));
    });

    test('executes a simple command', () async {
      final tool = BashTool();
      final ctx = ToolContext(
        sessionId: 1,
        messageId: 1,
        abort: AbortSignal(),
        workingDirectory: Directory.systemTemp.path,
      );
      final result = await tool.execute({
        'command': 'echo hello_crux_test',
        'description': 'Test echo command',
      }, ctx);
      expect(result.output, contains('hello_crux_test'));
      expect(result.metadata['exitCode'], 0);
    }, skip: Platform.isWindows);

    test('appends exit code suffix when command fails', () async {
      final tool = BashTool();
      final ctx = ToolContext(
        sessionId: 1,
        messageId: 1,
        abort: AbortSignal(),
        workingDirectory: Directory.systemTemp.path,
      );
      final result = await tool.execute({
        'command': 'exit 7',
        'description': 'Test failing command',
      }, ctx);
      expect(result.metadata['exitCode'], 7);
      expect(result.output.trimRight().endsWith('[exit code: 7]'), isTrue);
    }, skip: Platform.isWindows);

    test(
      'places exit code suffix AFTER truncation marker, not inside kept lines',
      () async {
        final tool = BashTool();
        final ctx = ToolContext(
          sessionId: 1,
          messageId: 1,
          abort: AbortSignal(),
          workingDirectory: Directory.systemTemp.path,
        );
        // 2500 lines + a failing command → output is truncated and exit != 0
        final result = await tool.execute({
          'command': 'seq 1 2500; exit 3',
          'description': 'Long failing output',
        }, ctx);
        expect(result.truncated, isTrue);
        expect(result.outputPath, isNotNull);
        expect(result.metadata['exitCode'], 3);
        // The exit code marker must be the LAST thing in the output
        expect(
          result.output.trimRight().endsWith('[exit code: 3]'),
          isTrue,
          reason: 'exit code should appear at the end, after truncation marker',
        );
        // And the truncation marker should mention the temp file path
        expect(result.output, contains('output truncated to 2000 lines'));
        expect(result.output, contains('full output:'));
        // The truncation marker should come BEFORE the exit code marker
        final truncIdx = result.output.indexOf('output truncated');
        final exitIdx = result.output.lastIndexOf('[exit code: 3]');
        expect(truncIdx, lessThan(exitIdx));
      },
      skip: Platform.isWindows,
    );
  });

  group('CmdTool execute (Windows)', () {
    test('executes a simple cmd command', () async {
      final tool = CmdTool();
      final ctx = ToolContext(
        sessionId: 1,
        messageId: 1,
        abort: AbortSignal(),
        workingDirectory: Directory.systemTemp.path,
      );
      final result = await tool.execute({
        'command': 'echo hello_crux_test',
        'description': 'Test echo command',
      }, ctx);
      expect(result.output.toLowerCase(), contains('hello_crux_test'));
      expect(result.metadata['exitCode'], 0);
    }, skip: !Platform.isWindows);

    test('handles quoted slashes in arguments (regression for session 13 hang)',
        () async {
      final tool = CmdTool();
      final ctx = ToolContext(
        sessionId: 1,
        messageId: 1,
        abort: AbortSignal(),
        workingDirectory: Directory(r'C:\Projects\crux').absolute.path,
      );
      final result = await tool.execute({
        'command': r'echo "fix /continue"',
      }, ctx);
      expect(
        result.output.contains("'/continue' is outside repository"),
        isFalse,
        reason: 'should not leak git-style pathspec errors',
      );
      expect(result.output.toLowerCase(), contains('fix /continue'));
    }, skip: !Platform.isWindows);

    test('handles multi-line commands with quoted slashes (session 13 commit)',
        () async {
      final tool = CmdTool();
      final ctx = ToolContext(
        sessionId: 1,
        messageId: 1,
        abort: AbortSignal(),
        workingDirectory: r'C:\Projects\crux',
      );
      final result = await tool.execute({
        'command': r'echo "fix(commands): reject /continue" & echo "second line with /flag"',
      }, ctx);
      expect(
        result.output.contains("'/continue' is outside repository"),
        isFalse,
      );
      expect(result.output.toLowerCase(), contains('fix(commands)'));
      expect(result.output.toLowerCase(), contains('second line'));
    }, skip: !Platform.isWindows);

    test('cleans up temp .bat file after execution', () async {
      final tool = CmdTool();
      final ctx = ToolContext(
        sessionId: 1,
        messageId: 1,
        abort: AbortSignal(),
        workingDirectory: Directory.systemTemp.path,
      );
      await tool.execute({'command': 'echo cleanup_test'}, ctx);
      await Future.delayed(const Duration(milliseconds: 100));
      final leaked = Directory(Directory.systemTemp.path)
          .listSync()
          .where((e) => e.path.contains('crux_cmd_') && e.path.endsWith('.bat'))
          .toList();
      expect(leaked, isEmpty);
    }, skip: !Platform.isWindows);

    test('returns error for missing command', () async {
      final tool = CmdTool();
      final ctx = ToolContext(
        sessionId: 1,
        messageId: 1,
        abort: AbortSignal(),
        workingDirectory: Directory.systemTemp.path,
      );
      final result = await tool.execute({}, ctx);
      expect(result.output, contains('Missing required parameter'));
    });

    test('PowerShellTool has correct name and schema', () {
      final tool = PowerShellTool();
      expect(tool.name, 'powershell');
      expect(tool.parametersSchema['required'], contains('command'));
    });

    test('CmdTool has correct name and schema', () {
      final tool = CmdTool();
      expect(tool.name, 'cmd');
      expect(tool.parametersSchema['required'], contains('command'));
    });
  });

  group('ReadTool execute', () {
    test('returns error for missing filePath', () async {
      final tool = ReadTool();
      final ctx = ToolContext(
        sessionId: 1,
        messageId: 1,
        abort: AbortSignal(),
        workingDirectory: '/tmp',
      );
      final result = await tool.execute({}, ctx);
      expect(result.output, contains('Missing required parameter'));
    });

    test('returns error for nonexistent path', () async {
      final tool = ReadTool();
      final ctx = ToolContext(
        sessionId: 1,
        messageId: 1,
        abort: AbortSignal(),
        workingDirectory: '/tmp',
      );
      final result = await tool.execute({
        'filePath': '/nonexistent/path/to/file.txt',
      }, ctx);
      expect(result.output, contains('not found'));
    });

    test('reads a file successfully', () async {
      final tempDir = await Directory.systemTemp.createTemp('crux_read_test_');
      final file = File('${tempDir.path}/test.txt');
      await file.writeAsString('line one\nline two\nline three');
      final tool = ReadTool();
      final ctx = ToolContext(
        sessionId: 1,
        messageId: 1,
        abort: AbortSignal(),
        workingDirectory: tempDir.path,
      );
      final result = await tool.execute({'filePath': file.path}, ctx);
      expect(result.output, contains('line one'));
      expect(result.output, contains('line two'));
      await tempDir.delete(recursive: true);
    });

    test('reads a directory listing', () async {
      final tempDir = await Directory.systemTemp.createTemp('crux_dir_test_');
      await File('${tempDir.path}/file1.txt').writeAsString('a');
      await Directory('${tempDir.path}/subdir').create();
      final tool = ReadTool();
      final ctx = ToolContext(
        sessionId: 1,
        messageId: 1,
        abort: AbortSignal(),
        workingDirectory: tempDir.path,
      );
      final result = await tool.execute({'filePath': tempDir.path}, ctx);
      expect(result.output, contains('file1.txt'));
      expect(result.output, contains('subdir/'));
      await tempDir.delete(recursive: true);
    });

    test('reads a file with relative path', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'crux_read_rel_test_',
      );
      final file = File('${tempDir.path}/test.txt');
      await file.writeAsString('relative content');
      final tool = ReadTool();
      final ctx = ToolContext(
        sessionId: 1,
        messageId: 1,
        abort: AbortSignal(),
        workingDirectory: tempDir.path,
      );
      final result = await tool.execute({'filePath': 'test.txt'}, ctx);
      expect(result.output, contains('relative content'));
      await tempDir.delete(recursive: true);
    });
  });

  group('EditTool replaceAll', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('crux_edit_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'replaceAll with different length replacement preserves positions',
      () async {
        final content =
            '[Nocterm](https://github.com/wu-sheng/nocterm)\n'
            'Some text\n'
            '[Nocterm](https://github.com/wu-sheng/nocterm)';
        final file = File('${tempDir.path}/readme.md');
        await file.writeAsString(content);

        final tool = EditTool();
        final ctx = ToolContext(
          sessionId: 1,
          messageId: 1,
          abort: AbortSignal(),
          workingDirectory: tempDir.path,
        );
        final result = await tool.execute({
          'filePath': 'readme.md',
          'oldString': 'https://github.com/wu-sheng/nocterm',
          'newString': 'https://github.com/marsup-space/nocterm',
          'replaceAll': true,
        }, ctx);

        expect(result.output, contains('Replaced 2 occurrence'));

        final updated = await file.readAsString();
        expect(
          updated,
          equals(
            '[Nocterm](https://github.com/marsup-space/nocterm)\n'
            'Some text\n'
            '[Nocterm](https://github.com/marsup-space/nocterm)',
          ),
        );
      },
    );

    test('replaceAll with same length replacement works', () async {
      final file = File('${tempDir.path}/code.dart');
      await file.writeAsString('foo bar foo bar foo');

      final tool = EditTool();
      final ctx = ToolContext(
        sessionId: 1,
        messageId: 1,
        abort: AbortSignal(),
        workingDirectory: tempDir.path,
      );
      final result = await tool.execute({
        'filePath': 'code.dart',
        'oldString': 'foo',
        'newString': 'baz',
        'replaceAll': true,
      }, ctx);

      expect(result.output, contains('Replaced 3 occurrence'));
      final updated = await file.readAsString();
      expect(updated, equals('baz bar baz bar baz'));
    });

    test('replaceAll with longer replacement does not corrupt content', () async {
      final file = File('${tempDir.path}/config.txt');
      await file.writeAsString('url=http://old\nname=test\nurl=http://old');

      final tool = EditTool();
      final ctx = ToolContext(
        sessionId: 1,
        messageId: 1,
        abort: AbortSignal(),
        workingDirectory: tempDir.path,
      );
      final result = await tool.execute({
        'filePath': 'config.txt',
        'oldString': 'http://old',
        'newString': 'https://new-server.example.com',
        'replaceAll': true,
      }, ctx);

      expect(result.output, contains('Replaced 2 occurrence'));
      final updated = await file.readAsString();
      expect(
        updated,
        equals(
          'url=https://new-server.example.com\nname=test\nurl=https://new-server.example.com',
        ),
      );
    });
  });

  group('EditTool + WriteTool auto-detect encoding/line ending', () {
    test(
        'EditTool preserves UTF-8 BOM when file has it (agent edit does not strip it)',
        () async {
      // Session 70/72 pain: agents edit, file loses BOM, downstream tools
      // (or other Windows editors) complain. Now EditTool reads bytes,
      // detects BOM, re-writes with BOM intact.
      final tempDir = await Directory.systemTemp.createTemp('crux_bom_');
      final filePath = p.join(tempDir.path, 'sample.dart');
      final bom = <int>[0xEF, 0xBB, 0xBF];
      final originalBytes = <int>[
        ...bom,
        ...utf8.encode('hello\r\nworld\r\n'),
      ];
      await File(filePath).writeAsBytes(originalBytes);
      final ctx = ToolContext(
        sessionId: 1,
        messageId: 1,
        abort: AbortSignal(),
        workingDirectory: tempDir.path,
      );
      final result = await EditTool().execute({
        'filePath': filePath,
        'oldString': 'hello\nworld',
        'newString': 'goodbye\nworld',
      }, ctx);
      final after = await File(filePath).readAsBytes();
      expect(after[0], 0xEF,
          reason: 'BOM byte 1 must be preserved');
      expect(after[1], 0xBB,
          reason: 'BOM byte 2 must be preserved');
      expect(after[2], 0xBF,
          reason: 'BOM byte 3 must be preserved');
      final content = utf8.decode(after.sublist(3));
      expect(content, contains('goodbye\r\nworld'),
          reason: 'CRLF must be preserved (file was CRLF)');
      expect(content, isNot(contains('goodbye\nworld')),
          reason: 'should not have LF-only after the edit');
      await tempDir.delete(recursive: true);
    });

    test(
        'EditTool does NOT introduce BOM when editing a non-BOM file',
        () async {
      final tempDir = await Directory.systemTemp.createTemp('crux_nobom_');
      final filePath = p.join(tempDir.path, 'sample.dart');
      await File(filePath).writeAsString('hello\nworld\n');
      final ctx = ToolContext(
        sessionId: 1,
        messageId: 1,
        abort: AbortSignal(),
        workingDirectory: tempDir.path,
      );
      final result = await EditTool().execute({
        'filePath': filePath,
        'oldString': 'hello\nworld',
        'newString': 'goodbye\nworld',
      }, ctx);
      final after = await File(filePath).readAsBytes();
      expect(after.length >= 1, isTrue);
      expect(after[0] != 0xEF || after.length < 3 || after[1] != 0xBB || after[2] != 0xBF,
          isTrue,
          reason: 'BOM must NOT be added to a non-BOM file');
      await tempDir.delete(recursive: true);
    });

    test(
        'WriteTool preserves UTF-8 BOM when overwriting a BOM file',
        () async {
      final tempDir = await Directory.systemTemp.createTemp('crux_wbom_');
      final filePath = p.join(tempDir.path, 'sample.dart');
      await File(filePath).writeAsBytes(<int>[
        0xEF, 0xBB, 0xBF,
        ...utf8.encode('old content\r\n'),
      ]);
      final ctx = ToolContext(
        sessionId: 1,
        messageId: 1,
        abort: AbortSignal(),
        workingDirectory: tempDir.path,
      );
      final result = await WriteTool().execute({
        'filePath': filePath,
        'content': 'new content\n',
        'intent': 'test',
      }, ctx);
      final after = await File(filePath).readAsBytes();
      expect(after[0], 0xEF);
      expect(after[1], 0xBB);
      expect(after[2], 0xBF);
      final content = utf8.decode(after.sublist(3));
      expect(content, equals('new content\r\n'),
          reason: 'WriteTool should preserve CRLF and add it even though '
              'agent provided LF');
      await tempDir.delete(recursive: true);
    });

    test(
        'WriteTool preserves CRLF when overwriting a CRLF file, '
        'normalizing agent\'s LF input to match',
        () async {
      final tempDir = await Directory.systemTemp.createTemp('crux_wcrlf_');
      final filePath = p.join(tempDir.path, 'sample.txt');
      await File(filePath).writeAsString('line1\r\nline2\r\nline3\r\n');
      final ctx = ToolContext(
        sessionId: 1,
        messageId: 1,
        abort: AbortSignal(),
        workingDirectory: tempDir.path,
      );
      final result = await WriteTool().execute({
        'filePath': filePath,
        'content': 'line1\nline2\nline3\n',
        'intent': 'test',
      }, ctx);
      final after = await File(filePath).readAsString();
      expect(after, equals('line1\r\nline2\r\nline3\r\n'),
          reason: 'CRLF must be preserved when overwriting CRLF file');
      await tempDir.delete(recursive: true);
    });
  });

  group('estimateTokens', () {
    test('pure ASCII text uses 4 chars per token', () {
      expect(estimateTokens('hello world'), equals(3));
    });

    test('pure CJK text uses 1.25 chars per token', () {
      expect(estimateTokens('你好世界'), equals(4));
    });

    test('mixed CJK and ASCII', () {
      final result = estimateTokens('hello 你好 world');
      expect(result, greaterThan(0));
    });

    test('empty string returns 0', () {
      expect(estimateTokens(''), equals(0));
    });

    test('CJK gets more tokens than same-length ASCII', () {
      final asciiTokens = estimateTokens('aaaa');
      final cjkTokens = estimateTokens('你好你好');
      expect(cjkTokens, greaterThan(asciiTokens));
    });
  });

  group('estimateToolRoundTripTokens', () {
    test('includes tool name, args, result, and overhead', () {
      final result = estimateToolRoundTripTokens(
        toolName: 'read',
        args: {'filePath': '/foo/bar.txt'},
        resultOutput: 'file contents here',
      );
      final nameTokens = estimateTokens('read');
      final argsTokens = estimateTokens('{"filePath":"/foo/bar.txt"}');
      final outputTokens = estimateTokens('file contents here');
      expect(result, equals(nameTokens + argsTokens + outputTokens + 25));
    });

    test('without anthropic overhead', () {
      final result = estimateToolRoundTripTokens(
        toolName: 'read',
        args: {'filePath': '/foo/bar.txt'},
        resultOutput: 'file contents here',
        anthropicOverhead: false,
      );
      final nameTokens = estimateTokens('read');
      final argsTokens = estimateTokens('{"filePath":"/foo/bar.txt"}');
      final outputTokens = estimateTokens('file contents here');
      expect(result, equals(nameTokens + argsTokens + outputTokens));
    });

    test('with anthropic overhead is larger than without', () {
      final withOverhead = estimateToolRoundTripTokens(
        toolName: 'read',
        args: {'filePath': '/foo'},
        resultOutput: 'output',
      );
      final withoutOverhead = estimateToolRoundTripTokens(
        toolName: 'read',
        args: {'filePath': '/foo'},
        resultOutput: 'output',
        anthropicOverhead: false,
      );
      expect(withOverhead, greaterThan(withoutOverhead));
    });

    test('excludeArgsFromEstimate removes specified args from estimate', () {
      final full = estimateToolRoundTripTokens(
        toolName: 'edit',
        args: {
          'filePath': '/foo.txt',
          'oldString': 'a' * 1000,
          'newString': 'b' * 1000,
        },
        resultOutput: 'Replaced 1 occurrence',
      );
      final excluded = estimateToolRoundTripTokens(
        toolName: 'edit',
        args: {
          'filePath': '/foo.txt',
          'oldString': 'a' * 1000,
          'newString': 'b' * 1000,
        },
        resultOutput: 'Replaced 1 occurrence',
        excludeArgsFromEstimate: {'oldString', 'newString'},
      );
      expect(excluded, lessThan(full));
      expect(excluded, lessThan(100));
    });
  });

  group('estimateToolDefsTokens', () {
    test('estimates tokens for tool definitions', () {
      final defs = [
        {
          'name': 'read',
          'description': 'Reads a file',
          'parameters': {
            'type': 'object',
            'properties': {
              'filePath': {'type': 'string'},
            },
          },
        },
      ];
      final result = estimateToolDefsTokens(defs);
      expect(result, greaterThan(0));
    });

    test('empty list returns minimal tokens', () {
      final result = estimateToolDefsTokens([]);
      expect(result, equals(estimateTokens('[]')));
    });

    test('more tools means more tokens', () {
      final one = [
        {'name': 'read', 'description': 'Reads a file', 'parameters': {}},
      ];
      final two = [
        {'name': 'read', 'description': 'Reads a file', 'parameters': {}},
        {'name': 'write', 'description': 'Writes a file', 'parameters': {}},
      ];
      expect(estimateToolDefsTokens(two), greaterThan(estimateToolDefsTokens(one)));
    });
  });

  group('contentBlockDeltaToChunk (Anthropic multi-call regression)', () {
    test('preserves block index in input_json_delta', () {
      final toolBlocks = <int, ({String callId, String name})>{
        0: (callId: 'call_a', name: 'grep'),
        1: (callId: 'call_b', name: 'read'),
      };

      final grepDelta = contentBlockDeltaToChunk(
        {
          'index': 0,
          'delta': {
            'type': 'input_json_delta',
            'partial_json': '{"pattern": "/continue", "path": "c:\\\\Projects\\\\crux"}',
          },
        },
        toolBlocks,
      );
      expect(grepDelta, isNotNull);
      expect(grepDelta!.toolUse, isNotNull);
      expect(grepDelta.toolUse!.index, 0, reason: 'index must be propagated');
      expect(grepDelta.toolUse!.callId, 'call_a');
      expect(grepDelta.toolUse!.name, 'grep');
      expect(
        grepDelta.toolUse!.inputDelta,
        '{"pattern": "/continue", "path": "c:\\\\Projects\\\\crux"}',
      );

      final readDelta = contentBlockDeltaToChunk(
        {
          'index': 1,
          'delta': {
            'type': 'input_json_delta',
            'partial_json': '{"filePath": "c:\\\\Projects\\\\crux"}',
          },
        },
        toolBlocks,
      );
      expect(readDelta!.toolUse!.index, 1);
      expect(readDelta.toolUse!.callId, 'call_b');
      expect(readDelta.toolUse!.name, 'read');
    });

    test('end-to-end: parallel deltas do not get concatenated', () {
      final toolBlocks = <int, ({String callId, String name})>{
        0: (callId: 'call_grep', name: 'grep'),
        1: (callId: 'call_read', name: 'read'),
      };
      final deltas = [
        contentBlockDeltaToChunk(
          {
            'index': 0,
            'delta': {
              'type': 'input_json_delta',
              'partial_json': '{"pattern": "TODO", "path": "lib"}',
            },
          },
          toolBlocks,
        )!,
        contentBlockDeltaToChunk(
          {
            'index': 1,
            'delta': {
              'type': 'input_json_delta',
              'partial_json': '{"filePath": "lib/foo.dart"}',
            },
          },
          toolBlocks,
        )!,
      ];
      final calls = ToolExecutor.parseToolUseFromChunks(deltas);
      expect(calls.length, 2);
      final grepCall = calls.firstWhere((c) => c.name == 'grep');
      expect(grepCall.input['pattern'], 'TODO');
      expect(grepCall.input['path'], 'lib');
      expect(grepCall.parseError, isNull);
      final readCall = calls.firstWhere((c) => c.name == 'read');
      expect(readCall.input['filePath'], 'lib/foo.dart');
      expect(readCall.parseError, isNull);
    });
  });

  group('GrepTool with file path (regression for session 12 hang)', () {
    test('treats a file path as single-file grep, not directory listing', () async {
      final workingDirectory = Directory.current.absolute.path;
      final ctx = ToolContext(
        sessionId: 1,
        messageId: 1,
        abort: AbortSignal(),
        workingDirectory: workingDirectory,
      );
      final result = await GrepTool().execute({
        'pattern': r'filterCommands|isCommandAvailable|filterSuggestions',
        'path': p.join(
          workingDirectory,
          'lib',
          'src',
          'components',
          'chat_panel.dart',
        ),
        'context': 3,
      }, ctx);
      expect(result.output, isNot(contains('Directory listing failed')));
      expect(result.output, isNot(contains('FileSystemException')));
      expect(result.output.toLowerCase(), contains('filtercommands'));
    });

    test('does not throw on directory paths either (sanity)', () async {
      final workingDirectory = Directory.current.absolute.path;
      final ctx = ToolContext(
        sessionId: 1,
        messageId: 1,
        abort: AbortSignal(),
        workingDirectory: workingDirectory,
      );
      final result = await GrepTool().execute({
        'pattern': 'Platform.isWindows',
        'path': p.join(workingDirectory, 'lib', 'src', 'tools'),
      }, ctx);
      expect(result.output, contains('Platform.isWindows'));
    });
  });

  group('parseToolUseFromChunks (multi-call regression)', () {
    test('keeps parallel tool calls separate by index', () {
      final chunks = <LlmChunk>[
        const LlmChunk(
          toolUse: ToolUseChunk(
            index: 0,
            callId: 'call_a',
            name: 'grep',
            inputDelta: '{"pattern": "/continue", "path": "c:\\\\Projects\\\\crux"}',
          ),
        ),
        const LlmChunk(
          toolUse: ToolUseChunk(
            index: 1,
            callId: 'call_b',
            name: 'read',
            inputDelta: '{"filePath": "c:\\\\Projects\\\\crux"}',
          ),
        ),
      ];
      final calls = ToolExecutor.parseToolUseFromChunks(chunks);
      expect(calls.length, 2);

      final grepCall = calls.firstWhere((c) => c.name == 'grep');
      expect(grepCall.callId, 'call_a');
      expect(grepCall.input['pattern'], '/continue');
      expect(grepCall.input['path'], r'c:\Projects\crux');
      expect(grepCall.parseError, isNull);

      final readCall = calls.firstWhere((c) => c.name == 'read');
      expect(readCall.callId, 'call_b');
      expect(readCall.input['filePath'], r'c:\Projects\crux');
      expect(readCall.parseError, isNull);
    });

    test('streams partial JSON across multiple deltas per call', () {
      final chunks = <LlmChunk>[
        const LlmChunk(
          toolUse: ToolUseChunk(
            index: 0,
            callId: 'call_a',
            name: 'cmd',
            inputDelta: '{"command":',
          ),
        ),
        const LlmChunk(
          toolUse: ToolUseChunk(
            index: 0,
            callId: 'call_a',
            name: 'cmd',
            inputDelta: '"dir"}',
          ),
        ),
        const LlmChunk(
          toolUse: ToolUseChunk(
            index: 1,
            callId: 'call_b',
            name: 'grep',
            inputDelta: '{"pattern": "TODO"}',
          ),
        ),
      ];
      final calls = ToolExecutor.parseToolUseFromChunks(chunks);
      expect(calls.length, 2);
      final cmdCall = calls.firstWhere((c) => c.name == 'cmd');
      expect(cmdCall.input['command'], 'dir');
      final grepCall = calls.firstWhere((c) => c.name == 'grep');
      expect(grepCall.input['pattern'], 'TODO');
    });
  });

  group('LargePayloadTool', () {
    test('WriteTool implements LargePayloadTool with content as offloadable', () {
      final tool = WriteTool();
      expect(tool, isA<LargePayloadTool>());
      expect((tool as LargePayloadTool).offloadableArgs, ['content']);
    });

    test('EditTool implements LargePayloadTool with oldString and newString', () {
      final tool = EditTool();
      expect(tool, isA<LargePayloadTool>());
      expect(
        (tool as LargePayloadTool).offloadableArgs,
        ['oldString', 'newString'],
      );
    });

    test('ReadTool does not implement LargePayloadTool', () {
      final tool = ReadTool();
      expect(tool, isNot(isA<LargePayloadTool>()));
    });

    test('BashTool does not implement LargePayloadTool', () {
      final tool = BashTool();
      expect(tool, isNot(isA<LargePayloadTool>()));
    });
  });

  group('offloadableArgsFor', () {
    test('returns the offloadable args set for a LargePayloadTool', () {
      final tool = WriteTool();
      expect(offloadableArgsFor(tool), {'content'});
    });

    test('returns the offloadable args set for EditTool', () {
      final tool = EditTool();
      expect(offloadableArgsFor(tool), {'oldString', 'newString'});
    });

    test('returns null for a non-LargePayloadTool', () {
      final tool = ReadTool();
      expect(offloadableArgsFor(tool), isNull);
    });

    test('returns null for a null tool', () {
      expect(offloadableArgsFor(null), isNull);
    });

    test('preserves declaration order in the returned set', () {
      // EditTool declares ['oldString', 'newString']; the order matters
      // for cache-stable persisted JSON, so the interface contract
      // requires List<String> (not Set<String>). The helper converts
      // to a set for the existing excludeArgsFromEstimate contract;
      // the ordering discipline lives in the implementation.
      final tool = EditTool();
      final list = (tool as LargePayloadTool).offloadableArgs;
      expect(list, isA<List<String>>());
      expect(list.first, 'oldString');
      expect(list.last, 'newString');
    });
  });

  group('CollapsedSummary', () {
    test('WriteTool returns text + args-only + total tokens', () {
      final tool = WriteTool();
      final summary = tool.collapsedSummary(
        {
          'filePath': 'foo.py',
          'content': 'a' * 5000,
          'intent': '...',
        },
        ToolResult(title: 'Write', output: 'Wrote 5000 chars'),
      );
      expect(summary, isA<CollapsedSummary>());
      expect(summary.text, '1 lines, 4.9KB');
      expect(summary.text, isNot(contains('~')));
      // For `write`, the content is both an arg and the
      // "result" of the operation. The two numbers differ
      // because argsTokens treats content as an arg while
      // totalTokens treats it as the result output (different
      // exclusion semantics in the call site). The important
      // invariant: both are nonzero and the total accounts
      // for the actual round-trip cost.
      expect(summary.argsTokens, greaterThan(0));
      expect(summary.totalTokens, greaterThan(0));
    });

    test('EditTool args-only includes the large args (stand-ins or full)', () {
      final tool = EditTool();
      final summary = tool.collapsedSummary(
        {
          'filePath': 'foo.py',
          'oldString': 'a' * 2000,
          'newString': 'b' * 2000,
          'intent': '...',
        },
        ToolResult(title: 'Edit', output: 'Replaced 1 occurrence'),
      );
      expect(summary.text, '1 replacement, 1→1 lines');
      // Both pre (from chat_service) and post (from collapsedSummary)
      // include the oldString/newString. The strikethrough comparison
      // is honest: pre counts the full strings, post counts the
      // stand-ins. The difference is the saving from offload.
      // Here the args are 2000 chars each, so the token count
      // reflects the actual (full or stand-in) arg values.
      expect(summary.argsTokens, greaterThan(500));
      expect(summary.totalTokens, greaterThanOrEqualTo(summary.argsTokens));
    });

    test('ReadTool returns lines + size, args-only == total (not offloadable)',
        () {
      final tool = ReadTool();
      final summary = tool.collapsedSummary(
        {'filePath': 'foo.py'},
        ToolResult(title: 'Read', output: 'x' * 2000),
      );
      expect(summary.text, '1 lines, 2.0KB');
      // Read isn't a LargePayloadTool, so args-only and total
      // are identical — there's no compression distinction to
      // make, and the bubble just shows the single number.
      expect(summary.argsTokens, summary.totalTokens);
    });

    test('BashTool includes command preview in the text', () {
      final tool = BashTool();
      final summary = tool.collapsedSummary(
        {'command': 'ls -la /tmp'},
        ToolResult(title: 'Bash', output: 'foo\nbar\n', metadata: {'exitCode': 0}),
      );
      expect(summary.text, contains('ls -la /tmp'));
      expect(summary.text, contains('lines'));
      expect(summary.argsTokens, greaterThan(0));
      expect(summary.totalTokens, summary.argsTokens);
    });

    test('EditTool shows "all" when replaceAll is true', () {
      final tool = EditTool();
      final summary = tool.collapsedSummary(
        {
          'filePath': 'foo.py',
          'oldString': 'foo',
          'newString': 'bar',
          'replaceAll': true,
          'intent': '...',
        },
        ToolResult(title: 'Edit', output: 'Replaced 5 occurrences'),
      );
      expect(summary.text, startsWith('all replacement'));
    });

    test('BashTool shows [exit N] suffix for non-zero exit codes', () {
      final tool = BashTool();
      final summary = tool.collapsedSummary(
        {'command': 'false'},
        ToolResult(
          title: 'Bash',
          output: '',
          metadata: {'exitCode': 1},
        ),
      );
      expect(summary.text, contains('[exit 1]'));
    });

    test('GrepTool appends [truncated] suffix when result was truncated', () {
      final tool = GrepTool();
      final summary = tool.collapsedSummary(
        {'pattern': 'TODO'},
        ToolResult(
          title: 'Grep',
          output: 'matches...',
          truncated: true,
          metadata: {'totalMatches': 500},
        ),
      );
      expect(summary.text, contains('[truncated]'));
      expect(summary.text, contains('500 matches'));
    });
  });

  group('EditTool', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('crux_edit_full_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    ToolContext _ctx() => ToolContext(
      sessionId: 1,
      messageId: 1,
      abort: AbortSignal(),
      workingDirectory: tempDir.path,
    );

    Future<File> _file(String name, String content) async {
      final f = File('${tempDir.path}/$name');
      await f.writeAsString(content);
      return f;
    }

    // ── Happy path ──

    test('exact match replaces single line and writes correctly', () async {
      await _file('test.txt', 'hello\nworld\n');
      final result = await EditTool().execute({
        'filePath': 'test.txt',
        'oldString': 'hello',
        'newString': 'hi',
      }, _ctx());

      expect(result.output, contains('Replaced 1 occurrence'));
      expect(await File('${tempDir.path}/test.txt').readAsString(),
          'hi\nworld\n');
    });

    test('exact multi-line match replaces block', () async {
      await _file('test.txt', 'alpha\nbeta\ngamma\ndelta\n');
      final result = await EditTool().execute({
        'filePath': 'test.txt',
        'oldString': 'beta\ngamma',
        'newString': 'middle',
      }, _ctx());

      expect(result.output, contains('Replaced 1 occurrence'));
      expect(await File('${tempDir.path}/test.txt').readAsString(),
          'alpha\nmiddle\ndelta\n');
    });

    test('replaceAll replaces every occurrence', () async {
      await _file('test.txt', 'foo bar foo bar foo');
      final result = await EditTool().execute({
        'filePath': 'test.txt',
        'oldString': 'foo',
        'newString': 'baz',
        'replaceAll': true,
      }, _ctx());

      expect(result.output, contains('Replaced 3 occurrence'));
      expect(await File('${tempDir.path}/test.txt').readAsString(),
          'baz bar baz bar baz');
    });

    // ── Auto-read on mismatch ──

    test('oldString not found returns auto-read with file content', () async {
      final content = 'alpha\nbeta\ngamma\n';
      await _file('test.txt', content);
      final result = await EditTool().execute({
        'filePath': 'test.txt',
        'oldString': 'nonexistent',
        'newString': 'replacement',
      }, _ctx());

      expect(result.title, contains('Auto-read:'));
      expect(result.output, contains('not found'));
      expect(result.output, contains('saved a round trip'));
      expect(result.output, contains('alpha\nbeta\ngamma\n'));
      expect(result.metadata['autoRead'], isTrue);
    });

    test('multiple exact matches without replaceAll returns auto-read',
        () async {
      await _file('test.txt', 'dup\nunique\ndup\n');
      final result = await EditTool().execute({
        'filePath': 'test.txt',
        'oldString': 'dup',
        'newString': 'replaced',
      }, _ctx());

      expect(result.metadata['autoRead'], isTrue);
    });

    test('disproportionate match returns auto-read', () async {
      // Multi-line oldString against content with large whitespace
      // gaps between the matching words. WhitespaceMatcher
      // collapses the gaps but the matched span in the original
      // includes all the blank lines — much larger than oldString.
      await _file('test.txt', 'a\n\n\n\n\n\n\n\nb\n\n\n\n\nc\n');
      final result = await EditTool().execute({
        'filePath': 'test.txt',
        'oldString': 'a\nb\nc',
        'newString': 'replaced',
      }, _ctx());

      // The matched span includes ~8 blank lines, far exceeding
      // oldString's length. Should trigger disproportionate guard.
      expect(result.metadata['autoRead'], isTrue);
    });

    test('no-match returns auto-read correctly', () async {
      await _file('test.txt', 'line one\nline two\nline three\n');
      final result = await EditTool().execute({
        'filePath': 'test.txt',
        'oldString': 'xxxyyy',
        'newString': 'y',
      }, _ctx());

      expect(result.metadata['autoRead'], isTrue);
    });

    // ── Fuzzy matching (still works for real cases) ──

    test('indentation-flexible match succeeds for single line', () async {
      // File uses 8-space indent, agent provides no indent.
      // IndentationMatcher strips leading whitespace and matches.
      await _file('test.txt', '        alpha\n    beta\n');
      final result = await EditTool().execute({
        'filePath': 'test.txt',
        'oldString': 'alpha',
        'newString': 'replaced',
      }, _ctx());

      expect(result.output, contains('Replaced 1 occurrence'));
      expect(await File('${tempDir.path}/test.txt').readAsString(),
          '        replaced\n    beta\n');
    });

    test('exact multi-line match preserves indentation', () async {
      // Both file and oldString use the same 4-space indent.
      // ExactMatcher handles this without going through
      // IndentationMatcher's match-length issue.
      await _file('test.txt', '    alpha\n    beta\n    gamma\n');
      final result = await EditTool().execute({
        'filePath': 'test.txt',
        'oldString': '    alpha\n    beta',
        'newString': '    replacement',
      }, _ctx());

      expect(result.output, contains('Replaced 1 occurrence'));
      expect(await File('${tempDir.path}/test.txt').readAsString(),
          '    replacement\n    gamma\n');
    });

    test('whitespace-normalized single-line match succeeds (tabs vs spaces)',
        () async {
      await _file('test.txt', 'prefix\tfoo\tbar\tsuffix');
      final result = await EditTool().execute({
        'filePath': 'test.txt',
        'oldString': 'foo bar',
        'newString': 'baz qux',
      }, _ctx());

      expect(result.output, contains('Replaced 1 occurrence'));
      expect(await File('${tempDir.path}/test.txt').readAsString(),
          'prefix\tbaz qux\tsuffix');
    });

    // ── Validation ──

    test('oldString equals newString returns error', () async {
      await _file('test.txt', 'hello\n');
      final result = await EditTool().execute({
        'filePath': 'test.txt',
        'oldString': 'hello',
        'newString': 'hello',
      }, _ctx());

      expect(result.output,
          contains('oldString and newString must be different'));
    });

    test('missing filePath returns error', () async {
      final result = await EditTool().execute({
        'oldString': 'x',
        'newString': 'y',
      }, _ctx());

      expect(result.output, contains('Missing required parameter: filePath'));
    });

    test('missing oldString returns error', () async {
      final result = await EditTool().execute({
        'filePath': 'test.txt',
        'newString': 'y',
      }, _ctx());

      expect(result.output, contains('Missing required parameter: oldString'));
    });

    test('missing newString returns error', () async {
      final result = await EditTool().execute({
        'filePath': 'test.txt',
        'oldString': 'x',
      }, _ctx());

      expect(result.output,
          contains('Missing required parameter: newString'));
    });

    test('file not found returns error', () async {
      final result = await EditTool().execute({
        'filePath': 'nonexistent.txt',
        'oldString': 'x',
        'newString': 'y',
      }, _ctx());

      expect(result.output, contains('File not found'));
    });

    test('empty oldString on existing file creates the file', () async {
      await _file('test.txt', 'hello\n');
      final result = await EditTool().execute({
        'filePath': 'test.txt',
        'oldString': '',
        'newString': 'new content',
      }, _ctx());

      expect(result.output, contains('Created file'));
    });

    // ── Read-before-write guard ──

    test('read-before-write guard triggers when file was never read',
        () async {
      final tracker = FileReadTracker();
      final tool = EditTool(tracker: tracker);
      final filePath = '${tempDir.path}/guarded.txt';
      await File(filePath).writeAsString('existing content\n');

      final result = await tool.execute({
        'filePath': filePath,
        'oldString': 'existing content',
        'newString': 'new',
      }, _ctx());

      expect(result.output, contains('[GUARD]'));
      expect(result.output, contains('not read before write'));
      expect(result.output, contains('existing content'));
      expect(result.metadata['guardTriggered'], isTrue);
    });

    test('read-before-write guard triggers when file was modified since read',
        () async {
      final tracker = FileReadTracker();
      final tool = EditTool(tracker: tracker);
      final filePath = '${tempDir.path}/modified.txt';
      await File(filePath).writeAsString('version 1');
      tracker.recordRead(filePath,
          DateTime.now().subtract(const Duration(seconds: 10)).millisecondsSinceEpoch);

      await File(filePath).writeAsString('version 2');
      final result = await tool.execute({
        'filePath': filePath,
        'oldString': 'version 1',
        'newString': 'version 2',
      }, _ctx());

      expect(result.output, contains('[GUARD]'));
      expect(result.output, contains('We re-read it'));
      expect(result.output, contains('version 2'));
      expect(result.metadata['guardTriggered'], isTrue);
    });

    // ── Match positions are correct ──

    test('match position does not corrupt surrounding content', () async {
      final content = 'line zero\nline one\nline two\nline three\n';
      await _file('test.txt', content);
      final result = await EditTool().execute({
        'filePath': 'test.txt',
        'oldString': 'line one',
        'newString': 'REPLACED',
      }, _ctx());

      expect(result.output, contains('Replaced 1 occurrence'));
      expect(await File('${tempDir.path}/test.txt').readAsString(),
          'line zero\nREPLACED\nline two\nline three\n');
    });

    test('mid-line exact match replaces only the matched span', () async {
      await _file('test.txt', 'prefix old middle suffix\n');
      final result = await EditTool().execute({
        'filePath': 'test.txt',
        'oldString': 'old middle',
        'newString': 'new center',
      }, _ctx());

      expect(result.output, contains('Replaced 1 occurrence'));
      expect(await File('${tempDir.path}/test.txt').readAsString(),
          'prefix new center suffix\n');
    });

    // ── File not changed on failed edit ──

    test('file is unchanged when auto-read fires (no write happened)',
        () async {
      final original = 'alpha\nbeta\ngamma\n';
      await _file('test.txt', original);
      await EditTool().execute({
        'filePath': 'test.txt',
        'oldString': 'nonexistent',
        'newString': 'replacement',
      }, _ctx());

      expect(await File('${tempDir.path}/test.txt').readAsString(), original);
    });
  });
}
