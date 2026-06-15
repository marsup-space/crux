import 'dart:io';

import 'package:crux/src/utils/file_searcher.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Spins up a FileSearcher rooted at a temp directory populated
/// with [files]. Keys are relative POSIX paths; values are file
/// contents (empty string = empty file). Trailing `/` means
/// directory. Returns the searcher and the temp dir so the
/// caller can clean up.
Future<(FileSearcher, Directory)> _buildSearcher(
  Map<String, String> files,
) async {
  final dir = await Directory.systemTemp.createTemp('crux_file_searcher_');
  for (final entry in files.entries) {
    final rel = entry.key;
    if (rel.endsWith('/')) {
      final d = Directory(p.join(dir.path, rel));
      await d.create(recursive: true);
    } else {
      final f = File(p.join(dir.path, rel));
      await f.parent.create(recursive: true);
      await f.writeAsString(entry.value);
    }
  }
  final searcher = FileSearcher(rootPath: dir.path, preferRipgrep: false);
  await searcher.ensureIndex();
  return (searcher, dir);
}

void main() {
  group('FileSearcher.search — ranking tiers', () {
    test('exact basename match ranks above prefix and substring', () async {
      // For query `foo.dart`, the exact basename match is
      // `foo.dart`. `foo.dart.bak` has a basename that
      // starts with `foo.dart` (prefix match). The unrelated
      // file has no match at all and shouldn't appear.
      final (searcher, dir) = await _buildSearcher({
        'foo.dart.bak': '',      // filename prefix match
        'foo.dart': '',          // exact basename match
        'lib/foo.dart': '',      // exact basename match (longer path)
        'unrelated.dart': '',    // no match for `foo.dart`
      });
      addTearDown(() => dir.delete(recursive: true));

      final results = searcher.search('foo.dart');
      final paths = results.map((m) => m.relativePath).toList();

      // Exact match wins; prefix match is at the bottom.
      expect(paths.first, 'foo.dart');
      expect(paths.last, 'foo.dart.bak');
      // The non-exact basename match sorts by path length so
      // the root-level copy comes before the buried copy.
      expect(paths.indexOf('foo.dart'),
          lessThan(paths.indexOf('lib/foo.dart')));
      // Unrelated file is filtered out.
      expect(paths, isNot(contains('unrelated.dart')));
    });

    test('exact basename match with shorter path wins the tie', () async {
      // All three files share the basename `foo.dart` and so
      // match the exact-basename tier. The path-length
      // tiebreaker should rank the root-level file first.
      final (searcher, dir) = await _buildSearcher({
        'old/foo.dart': '',
        'foo.dart': '',
        'lib/foo.dart': '',
      });
      addTearDown(() => dir.delete(recursive: true));

      final results = searcher.search('foo.dart');
      final paths = results.map((m) => m.relativePath).toList();

      expect(paths, ['foo.dart', 'lib/foo.dart', 'old/foo.dart']);
    });

    test('exact basename match works regardless of file casing', () async {
      // Basenames are stored lowercased so the @-mention UX is
      // case-insensitive: `@battlemode.cs` must find `Battlemode.cs`
      // (a real C# file name) and rank it above `ShowIfInBattlemode.cs`
      // whose basename contains `battlemode.cs` only as a substring.
      // Without the lowercasing fix this file would be demoted to the
      // path-substring tier — losing to the substring match.
      final (searcher, dir) = await _buildSearcher({
        'Battlemode.cs': '',         // exact basename (PascalCase on disk)
        'ShowIfInBattlemode.cs': '', // filename substring match
      });
      addTearDown(() => dir.delete(recursive: true));

      final results = searcher.search('battlemode.cs');
      final paths = results.map((m) => m.relativePath).toList();

      // The exact basename match wins over the substring match,
      // even though the on-disk file is `Battlemode.cs` (mixed case)
      // and the user typed lowercase `battlemode.cs`.
      expect(paths.first, 'Battlemode.cs');
      expect(paths.last, 'ShowIfInBattlemode.cs');
    });

    test('filename prefix match ranks above filename substring', () async {
      // `reader.dart` has `read` as a prefix; `old_read.dart`
      // has `read` only as a substring.
      final (searcher, dir) = await _buildSearcher({
        'old_read.dart': '',     // filename substring at idx 4
        'reader.dart': '',       // filename prefix match
        'lib/unrelated.dart': '',
      });
      addTearDown(() => dir.delete(recursive: true));

      final results = searcher.search('read');
      final paths = results.map((m) => m.relativePath).toList();

      expect(paths.first, 'reader.dart');
      expect(
        paths.indexOf('reader.dart'),
        lessThan(paths.indexOf('old_read.dart')),
      );
    });

    test('filename substring always ranks above path-only match', () async {
      // Even when the basename match is deep in a long name,
      // it must outrank a path-only match at the very start
      // of another path. This is the case the user explicitly
      // called out: "filename matches first".
      final longName = 'a_long_filename_with_xy.dart';
      final (searcher, dir) = await _buildSearcher({
        longName: '',
        // `lib/xyz/` directory's basename is `xyz` and so also
        // matches via filename substring — it should beat the
        // path-only substring in `lib/xyz/foo.dart`.
        'lib/xyz/foo.dart': '',
      });
      addTearDown(() => dir.delete(recursive: true));

      final results = searcher.search('xy');
      final paths = results.map((m) => m.relativePath).toList();

      // Both basename-substring matches (the long-name file
      // and the `lib/xyz/` directory entry) outrank the
      // path-only substring.
      expect(paths, contains(longName));
      expect(paths, contains('lib/xyz/foo.dart'));
      expect(
        paths.indexOf(longName),
        lessThan(paths.indexOf('lib/xyz/foo.dart')),
      );
    });

    test('results are sorted by strictly descending score', () async {
      // Construct a fixture where every result has a unique
      // score — different tier base, different basename
      // length, or different path length — so we can verify
      // the top-K output is in strictly descending order
      // without ties.
      final (searcher, dir) = await _buildSearcher({
        'foo_old.dart': '',       // filename prefix (basename len 11)
        'foo.dart': '',           // filename prefix (basename len 8)
        'old_foo.dart': '',       // filename substring (idx 4)
        'lib/foo/bar.dart': '',   // path substring (idx 4)
      });
      addTearDown(() => dir.delete(recursive: true));

      final results = searcher.search('foo');
      final scores = results.map((m) => m.score).toList();
      final paths = results.map((m) => m.relativePath).toList();

      for (var i = 1; i < scores.length; i++) {
        expect(
          scores[i - 1],
          greaterThan(scores[i]),
          reason: 'scores must be strictly descending; '
              'broken at position $i between ${paths[i - 1]} '
              '(${scores[i - 1]}) and ${paths[i]} (${scores[i]})',
        );
      }
    });

    test('empty query returns the first N indexed paths', () async {
      final (searcher, dir) = await _buildSearcher({
        'a.dart': '',
        'b.dart': '',
        'c.dart': '',
      });
      addTearDown(() => dir.delete(recursive: true));

      final results = searcher.search('', limit: 10);
      expect(results.length, 3);
      // Index is sorted alphabetically.
      expect(
        results.map((m) => m.relativePath).toList(),
        ['a.dart', 'b.dart', 'c.dart'],
      );
    });

    test('subsequence fallback still surfaces weak matches', () async {
      // No substring/prefix/path-substring match — every char
      // of the query appears in order in the path, so the
      // subsequence tier should pick these up.
      final (searcher, dir) = await _buildSearcher({
        'foo_bar_baz.dart': '', // subsequence: f..b..z
      });
      addTearDown(() => dir.delete(recursive: true));

      final results = searcher.search('fbz');
      expect(results.length, 1);
      expect(results.first.relativePath, 'foo_bar_baz.dart');
    });
  });
}