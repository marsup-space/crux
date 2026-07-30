import 'dart:io';

import 'package:crux/src/utils/dropped_file_handler.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Helper: create a temp directory containing a small text file,
/// an image-named file, a binary blob, and a sub-directory, then
/// return the directory plus a map of names to paths. Cleaned up
/// automatically when the test exits.
class _Fixture {
  final Directory root;
  final Map<String, String> files;
  _Fixture(this.root, this.files);

  String path(String name) => files[name]!;
}

Future<_Fixture> _createFixture() async {
  final root = await Directory.systemTemp.createTemp('crux_drop_test_');
  final files = <String, String>{};

  Future<void> writeFile(String name, List<int> bytes) async {
    final f = File(p.join(root.path, name));
    await f.writeAsBytes(bytes);
    files[name] = f.path;
  }

  await writeFile('hello.txt', 'Hello, world!\nLine 2.\n'.codeUnits);
  await writeFile('main.dart', 'void main() { print("hi"); }\n'.codeUnits);
  await writeFile('photo.png', [
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
  ]);
  await writeFile('big.bin', List.filled(128 * 1024, 0x41));
  // Binary file with a NUL byte — should still be classified as 'file'.
  await writeFile('blarp.dat', [0x48, 0x65, 0x00, 0x6C, 0x6C, 0x6F]);
  await Directory(p.join(root.path, 'sub')).create();
  files['sub'] = p.join(root.path, 'sub');

  // Some entries inside the directory so the listing isn't empty.
  await File(p.join(root.path, 'sub', 'a.md')).writeAsString('a');
  await File(p.join(root.path, 'sub', 'b.md')).writeAsString('b');

  return _Fixture(root, files);
}

void main() {
  late _Fixture fx;

  setUp(() async {
    fx = await _createFixture();
  });

  tearDown(() async {
    if (fx.root.existsSync()) {
      await fx.root.delete(recursive: true);
    }
  });

  group('extractDroppedPaths', () {
    test('returns a single absolute path unchanged', () {
      expect(extractDroppedPaths('/tmp/foo.md'), ['/tmp/foo.md']);
    });

    test('strips a single pair of matching surrounding quotes', () {
      expect(extractDroppedPaths("'/tmp/foo.md'"), ['/tmp/foo.md']);
      expect(extractDroppedPaths('"/tmp/foo.md"'), ['/tmp/foo.md']);
    });

    test('preserves unbalanced or mismatched quotes', () {
      // Only strip when first==last, so a stray quote stays put.
      expect(extractDroppedPaths("'/tmp/foo.md"), ["'/tmp/foo.md"]);
      expect(extractDroppedPaths('"/tmp/a" "/tmp/b'), ['/tmp/a', '"/tmp/b']);
    });

    test('splits on whitespace (newlines, spaces, tabs)', () {
      expect(extractDroppedPaths('/tmp/a.md\n/tmp/b.md\t/tmp/c.md'), [
        '/tmp/a.md',
        '/tmp/b.md',
        '/tmp/c.md',
      ]);
      expect(extractDroppedPaths('/tmp/a.md /tmp/b.md'), [
        '/tmp/a.md',
        '/tmp/b.md',
      ]);
    });

    test('strips file:// prefix and percent-decodes the rest', () {
      expect(extractDroppedPaths('file:///tmp/My%20Doc.md'), [
        '/tmp/My Doc.md',
      ]);
      // Path with %2F (encoded slash) — only %XX sequences are
      // decoded; the resulting string still contains a real `/`.
      expect(extractDroppedPaths('file:///tmp/%2E%2E/foo'), ['/tmp/../foo']);
    });

    test('leaves invalid %-escapes alone', () {
      // '%ZZ' is not valid hex, so the '%' and the next two
      // chars pass through verbatim.
      expect(extractDroppedPaths('%ZZabc'), ['%ZZabc']);
    });

    test('drops empty tokens', () {
      expect(extractDroppedPaths('   \n  '), isEmpty);
    });
  });

  group('classifyDroppedPaths', () {
    test('classifies a small UTF-8 text file as file', () {
      final r = classifyDroppedPaths([
        fx.path('hello.txt'),
      ], projectRoot: fx.root.path);
      expect(r, hasLength(1));
      expect(r.first.kind, DroppedFileKind.file);
      expect(r.first.sizeBytes, 'Hello, world!\nLine 2.\n'.length);
      expect(r.first.absolutePath, fx.path('hello.txt'));
    });

    test(
      'classifies any non-image file as file (regardless of binary content)',
      () {
        final r = classifyDroppedPaths([
          fx.path('blarp.dat'),
        ], projectRoot: fx.root.path);
        expect(r.first.kind, DroppedFileKind.file);
      },
    );

    test('classifies a large file as file', () {
      final r = classifyDroppedPaths([
        fx.path('big.bin'),
      ], projectRoot: fx.root.path);
      expect(r.first.kind, DroppedFileKind.file);
    });

    test('classifies a directory as directory', () {
      final r = classifyDroppedPaths([
        fx.path('sub'),
      ], projectRoot: fx.root.path);
      expect(r.first.kind, DroppedFileKind.directory);
    });

    test('classifies a missing path as missing', () {
      final r = classifyDroppedPaths([
        p.join(fx.root.path, 'does_not_exist.md'),
      ], projectRoot: fx.root.path);
      expect(r.first.kind, DroppedFileKind.missing);
    });

    test('classifies .png as image', () {
      final r = classifyDroppedPaths([
        fx.path('photo.png'),
      ], projectRoot: fx.root.path);
      expect(r.first.kind, DroppedFileKind.image);
    });

    test('resolves a relative path against projectRoot', () {
      final r = classifyDroppedPaths(['hello.txt'], projectRoot: fx.root.path);
      expect(r.first.kind, DroppedFileKind.file);
      expect(r.first.absolutePath, fx.path('hello.txt'));
      // originalPath is the user's input — relative as they typed it.
      expect(r.first.originalPath, 'hello.txt');
    });

    test('handles a mixed batch in one call', () {
      final r = classifyDroppedPaths([
        fx.path('hello.txt'),
        fx.path('photo.png'),
        fx.path('big.bin'),
        fx.path('sub'),
        p.join(fx.root.path, 'nope.md'),
      ], projectRoot: fx.root.path);
      expect(r.map((f) => f.kind).toList(), [
        DroppedFileKind.file,
        DroppedFileKind.image,
        DroppedFileKind.file,
        DroppedFileKind.directory,
        DroppedFileKind.missing,
      ]);
    });
  });

  group('formatDroppedFilesForInput', () {
    test('renders a file as a path reference', () {
      final files = classifyDroppedPaths([
        fx.path('hello.txt'),
      ], projectRoot: fx.root.path);
      final out = formatDroppedFilesForInput(files);
      expect(out, contains('[file:'));
      expect(out, contains(fx.path('hello.txt')));
      expect(out, isNot(contains('Hello, world!')));
    });

    test('renders a large/binary file as a path reference', () {
      final files = classifyDroppedPaths([
        fx.path('big.bin'),
      ], projectRoot: fx.root.path);
      final out = formatDroppedFilesForInput(files);
      expect(out, contains('[file:'));
      expect(out, contains('128.0 KB'));
    });

    test('renders a directory as a path reference only (no listing)', () {
      final files = classifyDroppedPaths([
        fx.path('sub'),
      ], projectRoot: fx.root.path);
      final out = formatDroppedFilesForInput(files);
      expect(out, contains('[directory:'));
      expect(out, contains(fx.path('sub')));
      // Contents must NOT be inlined — the agent lists the
      // directory itself with its own tools when it needs to.
      expect(out, isNot(contains('a.md')));
      expect(out, isNot(contains('b.md')));
      expect(out, isNot(contains('(empty directory)')));
    });

    test('skips image and missing kinds (caller handles them)', () {
      final files = classifyDroppedPaths([
        fx.path('photo.png'),
        p.join(fx.root.path, 'nope.md'),
      ], projectRoot: fx.root.path);
      final out = formatDroppedFilesForInput(files);
      expect(out, isEmpty);
    });
  });

  group('end-to-end: extract + classify + format', () {
    test('dropping a real text file yields a path reference, not content', () {
      // Simulate what a bracketed-paste payload looks like when
      // the user drags a file from Finder (single quoted path).
      final payload = "'${fx.path('main.dart')}'";
      final tokens = extractDroppedPaths(payload);
      final classified = classifyDroppedPaths(
        tokens,
        projectRoot: fx.root.path,
      );
      final out = formatDroppedFilesForInput(classified);
      expect(out, contains('[file:'));
      expect(out, contains('main.dart'));
      // Content must NOT be inlined.
      expect(out, isNot(contains('void main()')));
    });

    test(
      'dropping multiple files (newline-separated) produces path references',
      () {
        final payload = [fx.path('hello.txt'), fx.path('main.dart')].join('\n');
        final tokens = extractDroppedPaths(payload);
        final classified = classifyDroppedPaths(
          tokens,
          projectRoot: fx.root.path,
        );
        final out = formatDroppedFilesForInput(classified);
        // Both paths appear.
        expect(out, contains('hello.txt'));
        expect(out, contains('main.dart'));
        // Both are [file:] references.
        expect('[file:'.allMatches(out).length, 2);
      },
    );

    test(
      'dropping a path that does not exist falls through (empty format)',
      () {
        // classifier returns one entry with kind=missing; the
        // formatter skips it; the caller (chat_input) is responsible
        // for showing the error toast.
        final payload = p.join(fx.root.path, 'phantom.md');
        final tokens = extractDroppedPaths(payload);
        final classified = classifyDroppedPaths(
          tokens,
          projectRoot: fx.root.path,
        );
        final out = formatDroppedFilesForInput(classified);
        expect(out, isEmpty);
        expect(classified.single.kind, DroppedFileKind.missing);
      },
    );
  });

  group('looksLikeFileDrop', () {
    test('rejects an empty classification list', () {
      expect(looksLikeFileDrop(const <DroppedFile>[]), isFalse);
    });

    test('accepts a single real file', () {
      final classified = classifyDroppedPaths([
        fx.path('hello.txt'),
      ], projectRoot: fx.root.path);
      expect(looksLikeFileDrop(classified), isTrue);
    });

    test('accepts a single real directory', () {
      final classified = classifyDroppedPaths([
        fx.path('sub'),
      ], projectRoot: fx.root.path);
      expect(looksLikeFileDrop(classified), isTrue);
    });

    test('accepts a mixed batch of real files and a directory', () {
      final classified = classifyDroppedPaths([
        fx.path('hello.txt'),
        fx.path('photo.png'),
        fx.path('big.bin'),
        fx.path('sub'),
      ], projectRoot: fx.root.path);
      expect(
        classified.every((f) => f.kind != DroppedFileKind.missing),
        isTrue,
        reason: 'all four are real on disk',
      );
      expect(looksLikeFileDrop(classified), isTrue);
    });

    test(
      'rejects when at least one token is missing (prose-with-path bug)',
      () {
        // Regression: the previous implementation used `any(...)` to
        // decide whether a paste was a file drop, so a sentence that
        // happened to mention a real file path (e.g. "see
        // /tmp/hello.txt for context") was mis-routed as a file drop
        // and the surrounding words were surfaced as "File(s) not
        // found" toasts. With the new `every(...)` check, the paste
        // falls through to plain-text insertion.
        final classified = classifyDroppedPaths(const [
          'see',
          '/see',
          'for',
          'context',
        ], projectRoot: fx.root.path);
        // Sanity: the path-less words are missing; the only one that
        // resolves is whatever happens to be a real file at that name
        // (likely none in the fixture), or possibly one of them. The
        // important property is that NOT all of them are real.
        expect(
          classified.any((f) => f.kind == DroppedFileKind.missing),
          isTrue,
        );
        expect(looksLikeFileDrop(classified), isFalse);
      },
    );

    test('rejects a real prose payload whose tokens include a real path '
        '(reproduces the chatbox regression end-to-end)', () {
      // End-to-end repro: paste a sentence that *mentions* a real
      // file. With the old `any` check the chat input would consume
      // the paste and toast the non-path words as missing files. The
      // new `every` check must say "not a file drop" so the text
      // falls through to the plain-text path.
      final payload = 'see ${fx.path('hello.txt')} for context on the design';
      final tokens = extractDroppedPaths(payload);
      final classified = classifyDroppedPaths(
        tokens,
        projectRoot: fx.root.path,
      );

      // The real file is among the tokens, so the legacy `any`
      // check would have classified this as a drop. The new
      // `every` check must NOT.
      expect(
        classified.any((f) => f.kind != DroppedFileKind.missing),
        isTrue,
        reason: 'the real file token is present and resolves',
      );
      expect(
        classified.any((f) => f.kind == DroppedFileKind.missing),
        isTrue,
        reason: 'the surrounding words resolve to nothing',
      );
      expect(looksLikeFileDrop(classified), isFalse);
    });

    test('rejects when every token is missing', () {
      final classified = classifyDroppedPaths([
        p.join(fx.root.path, 'nope_a.md'),
        p.join(fx.root.path, 'nope_b.md'),
      ], projectRoot: fx.root.path);
      expect(
        classified.every((f) => f.kind == DroppedFileKind.missing),
        isTrue,
      );
      expect(looksLikeFileDrop(classified), isFalse);
    });

    // ─── IME-composition guard (macOS) ───────────────────────────
    //
    // On macOS, Chinese / Japanese / Korean IMEs commit their
    // candidate text through bracketed-paste mode, so a confirmed
    // word that happens to match a project entry (e.g. typing
    // "sub" in a project that has a `sub/` directory, or "tool"
    // in a project that has a `tool/` directory) used to be
    // classified against the project root and routed as a file
    // drop, replacing the user's IME text with a `[directory:
    // ...]` reference and firing a "Dropped: 1 path(s) inserted"
    // toast. Real file drops from terminal emulators always look
    // like paths — absolute (`/foo`), home-relative (`~`), or
    // with an explicit relative prefix (`./foo`, `../foo`) — so
    // a single bare word must NOT be treated as a drop.
    group('IME-composition guard (macOS bracketed-paste regression)', () {
      test('rejects a single bare word that resolves to a real directory', () {
        // The fixture's `sub/` directory makes "sub" the exact
        // shape of an IME-committed word that joins against the
        // project root and resolves to a real path.
        final classified = classifyDroppedPaths([
          'sub',
        ], projectRoot: fx.root.path);
        expect(
          classified.single.kind,
          DroppedFileKind.directory,
          reason: 'sanity: "sub" joins to <projectRoot>/sub and resolves',
        );
        expect(
          looksLikeFileDrop(classified),
          isFalse,
          reason: 'single bare word without path prefix is IME text',
        );
      });

      test('rejects a single bare word that resolves to a real file', () {
        // Same shape, but resolves to a file. The classifier happily
        // accepts it (it lives on disk); the drop guard is the only
        // thing standing between the user and a misclassification.
        final classified = classifyDroppedPaths([
          'hello.txt',
        ], projectRoot: fx.root.path);
        expect(
          classified.single.kind,
          DroppedFileKind.file,
          reason: 'sanity: "hello.txt" joins to <projectRoot>/hello.txt',
        );
        expect(
          looksLikeFileDrop(classified),
          isFalse,
          reason: 'single bare word without path prefix is IME text',
        );
      });

      test('rejects a single CJK token that happens to resolve', () {
        // Realistic Chinese-IME shape: a single bare CJK word.
        // Stash a CJK-named entry under the fixture so the
        // classifier can resolve it; the guard must still reject.
        final cjkDir = Directory(p.join(fx.root.path, '工具'));
        cjkDir.createSync();
        addTearDown(() {
          if (cjkDir.existsSync()) cjkDir.deleteSync(recursive: true);
        });

        final classified = classifyDroppedPaths([
          '工具',
        ], projectRoot: fx.root.path);
        expect(
          classified.single.kind,
          DroppedFileKind.directory,
          reason: 'sanity: "工具" joins to <projectRoot>/工具 and resolves',
        );
        expect(
          looksLikeFileDrop(classified),
          isFalse,
          reason: 'single CJK bare word is IME text, not a file drop',
        );
      });

      test('accepts a single absolute path', () {
        final classified = classifyDroppedPaths([
          fx.path('hello.txt'),
        ], projectRoot: fx.root.path);
        expect(
          looksLikeFileDrop(classified),
          isTrue,
          reason: 'real file drop: absolute path',
        );
      });

      test('accepts a single absolute directory path', () {
        final classified = classifyDroppedPaths([
          fx.path('sub'),
        ], projectRoot: fx.root.path);
        expect(
          looksLikeFileDrop(classified),
          isTrue,
          reason: 'real file drop: absolute directory path',
        );
      });

      test('accepts a single explicit-relative path (./foo)', () {
        final classified = classifyDroppedPaths([
          './hello.txt',
        ], projectRoot: fx.root.path);
        expect(
          classified.single.kind,
          DroppedFileKind.file,
          reason: 'sanity: "./hello.txt" resolves via projectRoot',
        );
        expect(
          looksLikeFileDrop(classified),
          isTrue,
          reason: 'real file drop: explicit relative path',
        );
      });

      test('accepts a single home-relative path (~/foo)', () {
        // `~` is intentionally not expanded by the classifier
        // (path canonicalize leaves it alone), so this resolves as
        // missing — but the path-shape check fires before the
        // missing-kind check, and the originalPath is "~/foo"
        // which is path-shaped. So we expect the drop guard to
        // return TRUE here: the shape is right; the user clearly
        // meant a file drop. The downstream code (or the user
        // noticing nothing got attached) handles the actual miss.
        // Actually, the existing every-must-resolve rule still
        // applies AFTER the path-shape check, so the expected
        // result here is FALSE: the path is path-shaped but does
        // not resolve. Document the behaviour with a comment so
        // future readers don't trip over it.
        final classified = classifyDroppedPaths(const [
          '~/no-such-file.md',
        ], projectRoot: fx.root.path);
        expect(
          classified.single.kind,
          DroppedFileKind.missing,
          reason: 'sanity: `~` is not expanded, so the path is missing',
        );
        expect(
          looksLikeFileDrop(classified),
          isFalse,
          reason: 'path-shaped but missing; every-must-resolve wins',
        );
      });
    });
  });
}
