import 'dart:io';
import 'package:test/test.dart';
import 'package:crux/src/tools/tool_def.dart';
import 'package:crux/src/tools/registry.dart';
import 'package:crux/src/tools/file_read_tracker.dart';
import 'package:crux/src/tools/bash_tool.dart';
import 'package:crux/src/tools/read_tool.dart';
import 'package:crux/src/tools/edit_tool.dart';
import 'package:crux/src/tools/matchers/exact_matcher.dart';
import 'package:crux/src/tools/matchers/whitespace_matcher.dart';
import 'package:crux/src/tools/matchers/indentation_matcher.dart';
import 'package:crux/src/utils/token_estimate.dart';

void main() {
  group('resolvePath', () {
    test('returns absolute path unchanged', () {
      expect(
        resolvePath('/home/user/file.txt', '/home/user'),
        '/home/user/file.txt',
      );
    });

    test('resolves relative path against working directory', () {
      expect(
        resolvePath('src/main.dart', '/home/user/project'),
        '/home/user/project/src/main.dart',
      );
    });

    test('resolves dot-relative path', () {
      expect(
        resolvePath('./lib/app.dart', '/home/user/project'),
        '/home/user/project/./lib/app.dart',
      );
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
      expect(registry.all.length, 7);
      final names = registry.all.map((t) => t.name).toList();
      expect(
        names,
        containsAll([
          'bash',
          'read',
          'write',
          'edit',
          'grep',
          'glob',
          'webfetch',
        ]),
      );
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

    test('checkWriteGuard returns guard for unread file', () async {
      final file = File('${tempDir.path}/unread.txt');
      await file.writeAsString('content here');
      final guard = tracker.checkWriteGuard(file.path);
      expect(guard, isNotNull);
      expect(guard!.header, contains('not yet read'));
      expect(guard!.content, 'content here');
    });

    test('checkWriteGuard returns guard for modified file', () async {
      final file = File('${tempDir.path}/modified.txt');
      await file.writeAsString('original');
      tracker.recordRead(
        file.path,
        file.statSync().modified.millisecondsSinceEpoch,
      );
      await Future.delayed(Duration(milliseconds: 100));
      await file.writeAsString('updated');
      final guard = tracker.checkWriteGuard(file.path);
      expect(guard, isNotNull);
      expect(guard!.header, contains('modified since'));
      expect(guard!.content, 'updated');
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
    });

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
    });

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
    );
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
}
