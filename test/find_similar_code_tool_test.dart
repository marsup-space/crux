import 'dart:io';

import 'package:test/test.dart';
import 'package:crux/src/tools/find_similar_code_tool.dart';
import 'package:crux/src/tools/tool_def.dart';

void main() {
  group('FindSimilarCodeTool', () {
    late FindSimilarCodeTool tool;
    late ToolContext ctx;

    setUp(() {
      tool = FindSimilarCodeTool();
      ctx = ToolContext(
        sessionId: 1,
        messageId: 1,
        abort: AbortSignal(),
        workingDirectory: Directory.current.path,
      );
    });

    test('has correct name and description triggers', () {
      expect(tool.name, equals('find_similar_code'));
      expect(tool.description, contains('find_similar_code'));
      // Implementation details shouldn't leak into the agent-facing
      // description.
      expect(
        tool.description,
        isNot(contains('semble')),
        reason: 'agent-facing description should not mention semble',
      );
      expect(
        tool.description,
        isNot(contains('CLI')),
        reason: 'agent-facing description should not mention CLI',
      );
    });

    test('requires both file and line', () async {
      final missingFile = await tool.execute({'line': 10}, ctx);
      expect(missingFile.title, equals('Error'));
      expect(missingFile.output, contains('Missing required parameter: file'));

      final missingLine = await tool.execute({'file': 'foo.dart'}, ctx);
      expect(missingLine.title, equals('Error'));
      expect(missingLine.output, contains('Missing required parameter: line'));
    });

    test('rejects line < 1', () async {
      final result = await tool.execute({'file': 'foo.dart', 'line': 0}, ctx);
      expect(result.title, equals('Error'));
      expect(result.output, contains('line must be >= 1'));
    });

    test(
      'finds chunks similar to a known location in a repo',
      () async {
        final repo = '${Directory.current.path}/.research/semble';
        if (!Directory(repo).existsSync()) {
          markTestSkipped('semble source not available at $repo');
          return;
        }
        // Anchor on the start of `_run_find_related` — a function
        // whose name spells out its purpose and that the engine
        // should be able to find semantically similar calls for.
        final result = await tool.execute({
          'file': 'src/semble/cli.py',
          'line': 124,
          'path': repo,
          'k': 3,
        }, ctx);
        expect(
          result.metadata['totalMatches'],
          greaterThan(0),
          reason: 'find_similar_code should find at least one match',
        );
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test(
      'returns clean error when anchor line is out of range',
      () async {
        final repo = '${Directory.current.path}/.research/semble';
        if (!Directory(repo).existsSync()) {
          markTestSkipped('semble source not available at $repo');
          return;
        }
        final result = await tool.execute({
          'file': 'src/semble/cli.py',
          'line': 99999,
          'path': repo,
          'k': 3,
        }, ctx);
        expect(
          result.title,
          equals('Error'),
          reason: 'out-of-range anchor should produce a clean error',
        );
        expect(
          result.output,
          contains('no chunk found'),
          reason: 'should explain the anchor mismatch to the agent',
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });
}
