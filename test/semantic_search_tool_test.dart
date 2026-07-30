import 'dart:io';

import 'package:test/test.dart';
import 'package:crux/src/tools/semantic_search_tool.dart';
import 'package:crux/src/tools/tool_def.dart';

void main() {
  group('SemanticSearchTool', () {
    late SemanticSearchTool tool;
    late ToolContext ctx;

    setUp(() {
      tool = SemanticSearchTool();
      ctx = ToolContext(
        sessionId: 1,
        messageId: 1,
        abort: AbortSignal(),
        workingDirectory: Directory.current.path,
      );
    });

    test('has correct name and description triggers', () {
      expect(tool.name, equals('semantic_search'));
      expect(tool.description, contains('SEMANTIC'));
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

    test('missing query returns error', () async {
      final result = await tool.execute({'query': ''}, ctx);
      expect(result.output, contains('Missing required parameter'));
    });

    test(
      'finds semantic matches across a repo',
      () async {
        final repo = '/Users/developer/Projects/crux/.research/semble';
        if (!Directory(repo).existsSync()) {
          markTestSkipped('semble source not available at $repo');
          return;
        }
        final result = await tool.execute({
          'query': 'how does the indexer parse source files',
          'path': repo,
          'k': 3,
        }, ctx);
        expect(result.metadata['totalMatches'], greaterThan(0));
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test(
      'returns clean error when path does not exist',
      () async {
        final result = await tool.execute({
          'query': 'anything',
          'path': '/nonexistent/path/xyzzy',
          'k': 3,
        }, ctx);
        expect(
          result.title,
          equals('Error'),
          reason: 'invalid path should produce a clean error',
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'reports clean error when search engine not installed',
      () async {
        final ctx2 = ToolContext(
          sessionId: 1,
          messageId: 1,
          abort: AbortSignal(),
          workingDirectory: '/nonexistent/path/that/does/not/exist',
        );
        final result = await tool.execute({
          'query': 'anything',
          'path': '/nonexistent/path/xyzzy',
        }, ctx2);
        expect(result.title, equals('Error'));
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'respects .gitignore: files inside gitignored dirs are not indexed',
      () async {
        final repo = '/Users/developer/Projects/crux';
        if (!Directory(repo).existsSync()) {
          markTestSkipped('crux repo not available at $repo');
          return;
        }
        final sentinelDir = Directory('$repo/.research');
        final sentinelFile = File(
          '${sentinelDir.path}/sentinel_xyzzy12345_uniquename.dart',
        );
        const sentinelToken =
            'zylqwensecret_ophthalmosaurus_xyzzy12345_sentinel';
        final sentinelContent =
            '''
// This file exists only to verify that .gitignore is respected.
// Token: $sentinelToken
// If you see this content in a semantic_search result, .gitignore is broken.
class SentinelForSembleTest {
  String marker = "$sentinelToken";
}
''';
        final existed = sentinelFile.existsSync();
        final priorContent = existed ? sentinelFile.readAsStringSync() : null;
        sentinelFile.writeAsStringSync(sentinelContent);

        addTearDown(() {
          if (existed && priorContent != null) {
            sentinelFile.writeAsStringSync(priorContent);
          } else if (!existed) {
            if (sentinelFile.existsSync()) sentinelFile.deleteSync();
          }
        });

        try {
          final result = await tool.execute({
            'query': sentinelToken,
            'path': repo,
            'k': 5,
          }, ctx);
          expect(
            result.output,
            isNot(contains('sentinel_xyzzy12345_uniquename.dart')),
            reason:
                '.gitignore is broken: sentinel file inside .research/ '
                'leaked into search results. Output was:\n${result.output}',
          );
        } catch (_) {
          // Sentinel cleanup handled by tearDown.
        }
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
