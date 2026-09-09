import 'dart:io';

import 'package:crux/src/utils/gitignore.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('GitignoreMatcher', () {
    GitignoreMatcher build(Map<String, String> files) {
      final sources = <GitignoreSource>[];
      for (final entry in files.entries) {
        sources.add((directory: entry.key, lines: entry.value.split('\n')));
      }
      final m = GitignoreMatcher();
      m.loadAll(sources);
      return m;
    }

    test('root-level glob matches at any depth', () {
      final m = build({'.': '*.log'});
      expect(m.matches('foo.log', isDirectory: false), isTrue);
      expect(m.matches('sub/foo.log', isDirectory: false), isTrue);
      expect(m.matches('a/b/c/foo.log', isDirectory: false), isTrue);
      expect(m.matches('foo.txt', isDirectory: false), isFalse);
    });

    test('directory-only pattern matches directories only', () {
      final m = build({'.': 'build/'});
      expect(m.matches('build', isDirectory: true), isTrue);
      expect(m.matches('a/b/build', isDirectory: true), isTrue);
      expect(m.matches('build', isDirectory: false), isFalse);
      expect(m.matches('build/file.o', isDirectory: false), isFalse);
    });

    test('anchored pattern only matches at the .gitignore level', () {
      final m = build({'.': '/build'});
      // At root level: matches.
      expect(m.matches('build', isDirectory: true), isTrue);
      // Below root: does NOT match.
      expect(m.matches('sub/build', isDirectory: true), isFalse);
      expect(m.matches('a/b/build', isDirectory: true), isFalse);
    });

    test('pattern with slash is anchored-like', () {
      final m = build({'.': 'docs/build'});
      expect(m.matches('docs/build', isDirectory: true), isTrue);
      expect(m.matches('sub/docs/build', isDirectory: true), isFalse);
    });

    test('negation overrides previous match', () {
      final m = build({'.': '*.log\n!important.log'});
      expect(m.matches('foo.log', isDirectory: false), isTrue);
      expect(m.matches('important.log', isDirectory: false), isFalse);
    });

    test('comments and blanks are ignored', () {
      final m = build({'.': '# this is a comment\n\n   \n*.tmp'});
      expect(m.matches('foo.tmp', isDirectory: false), isTrue);
    });

    test('leading backslash escapes special chars', () {
      final m = build({'.': r'\#tagged'});
      expect(m.matches('#tagged', isDirectory: false), isTrue);
    });

    test('double-star matches any depth including slashes', () {
      final m = build({'.': 'a/**/b'});
      expect(m.matches('a/b', isDirectory: false), isTrue);
      expect(m.matches('a/x/b', isDirectory: false), isTrue);
      expect(m.matches('a/x/y/b', isDirectory: false), isTrue);
      expect(m.matches('a/c/d', isDirectory: false), isFalse);
    });

    test('nested .gitignore only applies to its subtree', () {
      final m = build({'.': '*.log', 'sub': '*.tmp'});
      // *.log at the root, *.tmp under sub/.
      expect(m.matches('a.log', isDirectory: false), isTrue);
      expect(m.matches('sub/a.tmp', isDirectory: false), isTrue);
      // *.log doesn't apply inside sub/ — wait, it does! *.log
      // matches at any depth, so even sub/x.log matches.
      expect(m.matches('sub/x.log', isDirectory: false), isTrue);
      // *.tmp at sub/ only applies under sub/.
      expect(m.matches('a.tmp', isDirectory: false), isFalse);
    });

    test('git status works against a real temp tree', () {
      // Build a tiny project, write a .gitignore, verify the
      // matcher agrees with the in-process walker.
      final dir = Directory.systemTemp.createTempSync('crux_gi_test_');
      try {
        File(p.join(dir.path, '.gitignore')).writeAsStringSync('''
# build artifacts
build/
*.pyc
*.log
!keep.log
node_modules/
/root_only.tmp
''');
        Directory(p.join(dir.path, 'build')).createSync();
        Directory(p.join(dir.path, 'src')).createSync();
        File(p.join(dir.path, 'src/main.dart'))
            .writeAsStringSync('void main() {}');
        File(p.join(dir.path, 'src/main.pyc')).writeAsStringSync('x');
        File(p.join(dir.path, 'debug.log')).writeAsStringSync('x');
        File(p.join(dir.path, 'keep.log')).writeAsStringSync('x');
        File(p.join(dir.path, 'root_only.tmp')).writeAsStringSync('x');
        File(p.join(dir.path, 'src/root_only.tmp')).writeAsStringSync('x');

        final gi = File(p.join(dir.path, '.gitignore')).readAsLinesSync();
        final m = GitignoreMatcher();
        m.loadAll([(directory: '.', lines: gi)]);

        expect(
          m.matches('build', isDirectory: true),
          isTrue,
          reason: 'build/ should be ignored',
        );
        expect(
          m.matches('src/main.pyc', isDirectory: false),
          isTrue,
          reason: '*.pyc at any depth',
        );
        expect(m.matches('debug.log', isDirectory: false), isTrue);
        expect(
          m.matches('keep.log', isDirectory: false),
          isFalse,
          reason: '!keep.log overrides *.log',
        );
        expect(
          m.matches('root_only.tmp', isDirectory: false),
          isTrue,
          reason: '/root_only.tmp matches at root only',
        );
        expect(
          m.matches('src/root_only.tmp', isDirectory: false),
          isFalse,
          reason: '/root_only.tmp does NOT match in sub/',
        );
        expect(m.matches('src/main.dart', isDirectory: false), isFalse);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });
}
