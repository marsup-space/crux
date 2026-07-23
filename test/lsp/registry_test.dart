// Tests for the default LSP registry and WhichServerActor.

import 'dart:io';

import 'package:crux/src/lsp/actors/generic.dart';
import 'package:crux/src/lsp/actors/registry.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('defaultLspActorFactories', () {
    test('covers the major languages', () {
      final factories = defaultLspActorFactories();
      const expected = {
        'dart',
        'typescript',
        'pyright',
        'rust',
        'gopls',
        'clangd',
        'jdtls',
        'csharp',
        'kotlin-ls',
        'sourcekit-lsp',
        'ruby-lsp',
        'intelephense',
        'lua-ls',
        'bash',
        'yaml-ls',
        'zls',
        'vue',
        'svelte',
        'astro',
        'dockerfile',
        'terraform',
        'nixd',
        'ocaml-lsp',
        'haskell-language-server',
        'clojure-lsp',
        'gleam',
        'prisma',
        'tinymist',
        'texlab',
        'fsharp',
        'elixir-ls',
      };
      expect(factories.keys.toSet(), expected);
    });

    test('factory instances expose matching id and non-empty extensions',
        () {
      final factories = defaultLspActorFactories();
      for (final entry in factories.entries) {
        final actor = entry.value();
        expect(actor.id, entry.key, reason: 'id mismatch for ${entry.key}');
        expect(
          actor.extensions.isNotEmpty || actor.bareFilenames.isNotEmpty,
          isTrue,
          reason: '${entry.key} matches no files',
        );
      }
    });
  });

  group('WhichServerActor', () {
    test('returns null when binary is not on PATH', () async {
      final actor = WhichServerActor(
        id: 'nope',
        extensions: const ['.nope'],
        commandCandidates: const [
          ['definitely-not-a-real-binary-xyz'],
        ],
      );
      final spec = await actor.resolveSpec(Directory.current.path, 'a.nope');
      expect(spec, isNull);
    });

    test('resolves spec using a PATH binary and falls back to session root',
        () async {
      // `dart` is guaranteed on PATH in this repo's test environment.
      final dart = _which('dart');
      if (dart == null) return; // skip if the SDK isn't on PATH

      final actor = WhichServerActor(
        id: 'fake-dart',
        extensions: const ['.dart'],
        rootMarkers: const ['no-such-marker-file-xyz'],
        commandCandidates: const [
          ['dart', 'language-server', '--lsp'],
        ],
      );
      final root = Directory.current.path;
      final spec = await actor.resolveSpec(root, p.join(root, 'x.dart'));
      expect(spec, isNotNull);
      expect(spec!.command.first, dart);
      expect(spec.command, containsAll(['language-server', '--lsp']));
      expect(spec.root, root);
    });

    test('resolves project root from marker files', () async {
      final dart = _which('dart');
      if (dart == null) return;

      final tmp = await Directory.systemTemp.createTemp('crux-lsp-test-');
      addTearDown(() => tmp.delete(recursive: true));
      final project = Directory(p.join(tmp.path, 'proj'));
      final nested = Directory(p.join(project.path, 'lib', 'src'));
      await nested.create(recursive: true);
      await File(p.join(project.path, 'pubspec.yaml')).writeAsString('');
      final file = p.join(nested.path, 'main.dart');

      final actor = WhichServerActor(
        id: 'fake-dart',
        extensions: const ['.dart'],
        rootMarkers: const ['pubspec.yaml'],
        commandCandidates: const [
          ['dart'],
        ],
      );
      final spec = await actor.resolveSpec(tmp.path, file);
      expect(spec, isNotNull);
      expect(spec!.root, project.path);
    });

    test('tries command candidates in order', () async {
      final dart = _which('dart');
      if (dart == null) return;

      final actor = WhichServerActor(
        id: 'candidates',
        extensions: const ['.x'],
        commandCandidates: const [
          ['definitely-not-a-real-binary-xyz'],
          ['dart', '--version'],
        ],
      );
      final spec =
          await actor.resolveSpec(Directory.current.path, 'a.x');
      expect(spec, isNotNull);
      expect(spec!.command, [dart, '--version']);
    });
  });
}

String? _which(String binary) {
  final pathVar = Platform.environment['PATH'] ?? '';
  for (final dir in pathVar.split(Platform.isWindows ? ';' : ':')) {
    if (dir.isEmpty) continue;
    final candidate = p.join(dir, binary);
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}
