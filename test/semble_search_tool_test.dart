import 'dart:io';

import 'package:test/test.dart';
import 'package:crux/src/tools/semble_search_tool.dart';
import 'package:crux/src/tools/tool_def.dart';

void main() {
  group('SembleSearchTool', () {
    late SembleSearchTool tool;
    late ToolContext ctx;

    setUp(() {
      tool = SembleSearchTool();
      ctx = ToolContext(
        sessionId: 1,
        messageId: 1,
        abort: AbortSignal(),
        workingDirectory: Directory.current.path,
      );
    });

    test('missing query returns error', () async {
      final result = await tool.execute({'query': ''}, ctx);
      expect(result.output, contains('Missing required parameter'));
    });

    test(
      'finds symbol-shape matches via semantic search',
      () async {
        final repo =
            '/Users/developer/Projects/crux/.research/semble';
        if (!Directory(repo).existsSync()) {
          markTestSkipped('semble source not available at $repo');
          return;
        }
        final result = await tool.execute(
          {'query': 'how does the indexer parse source files', 'path': repo, 'k': 3},
          ctx,
        );
        print('---TOOL OUTPUT---');
        print(result.output);
        print('---END---');
        expect(result.metadata['totalMatches'], greaterThan(0));
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test(
      'returns no matches when path does not exist',
      () async {
        final result = await tool.execute(
          {
            'query': 'anything',
            'path': '/nonexistent/path/xyzzy',
            'k': 3,
          },
          ctx,
        );
        expect(result.title, equals('Error'),
            reason: 'invalid path should produce a clean error');
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'reports clean error when semble not installed',
      () async {
        // Override the executable resolution by simulating a missing binary
        // via a path that doesn't exist. We can't easily inject this without
        // DI, so just check the error message format from a guaranteed
        // missing executable by passing a very weird working directory.
        final ctx2 = ToolContext(
          sessionId: 1,
          messageId: 1,
          abort: AbortSignal(),
          workingDirectory: '/nonexistent/path/that/does/not/exist',
        );
        final result = await tool.execute(
          {'query': 'anything', 'path': '/nonexistent/path/xyzzy'},
          ctx2,
        );
        // Either: semble fails because path doesn't exist, OR
        // ProcessException because binary missing. Either way the output
        // should be an error (not a successful result with matches).
        expect(result.title, equals('Error'));
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'respects .gitignore: files inside gitignored dirs are not indexed',
      () async {
        // Plant a sentinel file inside .research/ (which is in crux's
        // .gitignore). The content uses a unique token that won't match
        // any legitimate code. If .gitignore is honored, the file is not
        // walked, the cache stays valid, and a search for the token
        // returns no matches. If .gitignore is broken, the file is
        // indexed, the cache rebuilds, and the search returns the file.
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
        final sentinelContent = '''
// This file exists only to verify that .gitignore is respected.
// Token: $sentinelToken
// If you see this content in a semble_search result, .gitignore is broken.
class SentinelForSembleTest {
  String marker = "$sentinelToken";
}
''';
        // Write the sentinel; restore prior state at the end either way.
        final existed = sentinelFile.existsSync();
        final priorContent =
            existed ? sentinelFile.readAsStringSync() : null;
        sentinelFile.writeAsStringSync(sentinelContent);

        addTearDown(() {
          if (existed && priorContent != null) {
            sentinelFile.writeAsStringSync(priorContent);
          } else if (!existed) {
            if (sentinelFile.existsSync()) sentinelFile.deleteSync();
          }
        });

        try {
          final result = await tool.execute(
            {
              'query': sentinelToken,
              'path': repo,
              'k': 5,
            },
            ctx,
          );
          // The planted file must not appear in any result.
          expect(
            result.output,
            isNot(contains('sentinel_xyzzy12345_uniquename.dart')),
            reason:
                '.gitignore is broken: sentinel file inside .research/ '
                'leaked into search results. Output was:\n${result.output}',
          );
        } finally {
          // Re-index to drop the planted file from any cache (defensive).
          // We rely on the setUp/tearDown to restore the original file
          // state, so subsequent runs are deterministic.
        }
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}