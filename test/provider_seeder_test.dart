import 'dart:io';
import 'package:test/test.dart';
import 'package:crux/src/services/provider_seeder.dart';

void main() {
  group('seedExampleProviders', () {
    late Directory builtInDir;
    late Directory userDir;

    setUp(() async {
      builtInDir = await Directory.systemTemp.createTemp('crux_built_in_');
      userDir = await Directory.systemTemp.createTemp('crux_user_');
    });

    tearDown(() async {
      if (await builtInDir.exists()) {
        await builtInDir.delete(recursive: true);
      }
      if (await userDir.exists()) {
        await userDir.delete(recursive: true);
      }
    });

    test('returns empty list when built-in dir does not exist', () async {
      await builtInDir.delete(recursive: true);
      final results = await seedExampleProviders(
        builtInDir: builtInDir,
        userDir: userDir,
      );
      expect(results, isEmpty);
    });

    test('creates user dir if missing', () async {
      await userDir.delete(recursive: true);
      expect(userDir.existsSync(), isFalse);

      await File('${builtInDir.path}/provider.toml').writeAsString('''
type = "openai_compatible"
endpoint_url = "https://api.openai.com/v1"
''');

      await seedExampleProviders(builtInDir: builtInDir, userDir: userDir);

      expect(userDir.existsSync(), isTrue);
    });

    test('creates file when it does not exist in user dir', () async {
      const bundled = '''
type = "openai_compatible"
endpoint_url = "https://api.openai.com/v1"

[[models]]
id = "gpt-4o"
name = "GPT-4o"
context_size = 128000
''';
      await File('${builtInDir.path}/provider.toml').writeAsString(bundled);

      final results = await seedExampleProviders(
        builtInDir: builtInDir,
        userDir: userDir,
      );

      expect(results, hasLength(1));
      final r = results.single;
      // Examples are written as `example.<name>.toml`, not `<name>.toml`.
      expect(r.fileName, 'example.provider.toml');
      expect(r.action, SeedAction.created);
      expect(r.oldSha256, isNull);
      expect(r.newSha256, isNotNull);

      // The file now exists in the user dir with the bundled content,
      // under the `example.` prefix.
      final userFile = File('${userDir.path}/example.provider.toml');
      expect(await userFile.readAsString(), bundled);
    });

    test('skips file when SHA-256 matches (idempotent)', () async {
      const content = 'same content in both places';
      await File('${builtInDir.path}/foo.toml').writeAsString(content);
      await File('${userDir.path}/example.foo.toml').writeAsString(content);

      final results = await seedExampleProviders(
        builtInDir: builtInDir,
        userDir: userDir,
      );

      expect(results.single.action, SeedAction.unchanged);
      expect(results.single.fileName, 'example.foo.toml');
    });

    test('overwrites file when SHA-256 differs (destructive)', () async {
      const builtInContent = 'NEW: bundled version 2.0';
      const userContent = 'OLD: user-edited version 1.0';
      await File(
        '${builtInDir.path}/provider.toml',
      ).writeAsString(builtInContent);
      await File(
        '${userDir.path}/example.provider.toml',
      ).writeAsString(userContent);

      final results = await seedExampleProviders(
        builtInDir: builtInDir,
        userDir: userDir,
      );

      expect(results.single.action, SeedAction.overwritten);
      expect(results.single.fileName, 'example.provider.toml');
      expect(results.single.oldSha256, isNot(equals(results.single.newSha256)));

      // The file's content has been clobbered with the bundled version.
      final userFile = File('${userDir.path}/example.provider.toml');
      expect(await userFile.readAsString(), builtInContent);
    });

    test(
      'handles multiple files in alphabetical order, all prefixed',
      () async {
        await File('${builtInDir.path}/zeta.toml').writeAsString('z');
        await File('${builtInDir.path}/alpha.toml').writeAsString('a');
        await File('${builtInDir.path}/middle.toml').writeAsString('m');

        final results = await seedExampleProviders(
          builtInDir: builtInDir,
          userDir: userDir,
        );

        expect(results.map((r) => r.fileName).toList(), [
          'example.alpha.toml',
          'example.middle.toml',
          'example.zeta.toml',
        ]);
        expect(results.every((r) => r.action == SeedAction.created), isTrue);
      },
    );

    test(
      'strips pre-existing "example." prefix from built-in basename',
      () async {
        // A built-in whose name already starts with `example.` should
        // not produce a doubly-prefixed `example.example.X.toml` copy
        // in the user dir. Without the strip the loader would still
        // skip the file (startsWith("example.")), but the double prefix
        // is confusing for users reading their providers directory.
        await File(
          '${builtInDir.path}/example.provider.toml',
        ).writeAsString('reference template');

        final results = await seedExampleProviders(
          builtInDir: builtInDir,
          userDir: userDir,
        );

        expect(results.single.fileName, 'example.provider.toml');
        expect(
          await File('${userDir.path}/example.provider.toml').exists(),
          isTrue,
        );
        expect(
          await File('${userDir.path}/example.example.provider.toml').exists(),
          isFalse,
          reason: 'No doubly-prefixed file should be created',
        );
      },
    );

    test('ignores non-TOML files in built-in dir', () async {
      await File('${builtInDir.path}/provider.toml').writeAsString('a');
      await File('${builtInDir.path}/README.md').writeAsString('docs');
      await File('${builtInDir.path}/schema.json').writeAsString('{}');

      final results = await seedExampleProviders(
        builtInDir: builtInDir,
        userDir: userDir,
      );

      expect(results, hasLength(1));
      expect(results.single.fileName, 'example.provider.toml');
      // README and schema are left alone in the user dir
      expect(File('${userDir.path}/README.md').existsSync(), isFalse);
    });

    test(
      'mixed: some files exist (unchanged), some are new (created), some differ (overwritten)',
      () async {
        // bundled has all three
        await File('${builtInDir.path}/alpha.toml').writeAsString('a-v2');
        await File('${builtInDir.path}/beta.toml').writeAsString('b-v2');
        await File('${builtInDir.path}/gamma.toml').writeAsString('g-v2');

        // user has: example.alpha unchanged, example.beta different, gamma missing
        await File('${userDir.path}/example.alpha.toml').writeAsString('a-v2');
        await File('${userDir.path}/example.beta.toml').writeAsString('b-v1');

        final results = await seedExampleProviders(
          builtInDir: builtInDir,
          userDir: userDir,
        );

        final byName = {for (final r in results) r.fileName: r};
        expect(byName['example.alpha.toml']!.action, SeedAction.unchanged);
        expect(byName['example.beta.toml']!.action, SeedAction.overwritten);
        expect(byName['example.gamma.toml']!.action, SeedAction.created);

        // File contents after seed
        expect(
          await File('${userDir.path}/example.alpha.toml').readAsString(),
          'a-v2',
        );
        expect(
          await File('${userDir.path}/example.beta.toml').readAsString(),
          'b-v2',
        );
        expect(
          await File('${userDir.path}/example.gamma.toml').readAsString(),
          'g-v2',
        );
      },
    );

    test('second call after no-op is still a no-op', () async {
      await File('${builtInDir.path}/foo.toml').writeAsString('x');
      await seedExampleProviders(builtInDir: builtInDir, userDir: userDir);
      final second = await seedExampleProviders(
        builtInDir: builtInDir,
        userDir: userDir,
      );
      expect(second.single.action, SeedAction.unchanged);
    });

    test('does not touch real provider files already in user dir', () async {
      // User has a real provider file at a name unrelated to any built-in
      // (the bundled `provider.toml` would become `example.provider.toml`,
      // which is the prefix-skip path — that's covered by other tests).
      // Here we verify the seeder doesn't write over a real (non-example)
      // file in the user dir.
      const realCustom = '''
type = "openai_compatible"
endpoint_url = "https://my-proxy.example/v1"

[[models]]
id = "gpt-4o"
name = "GPT-4o via my proxy"
context_size = 128000
''';
      await File('${userDir.path}/mycorp.toml').writeAsString(realCustom);
      // And the bundled has the canonical example
      await File('${builtInDir.path}/provider.toml').writeAsString('original');

      await seedExampleProviders(builtInDir: builtInDir, userDir: userDir);

      // The real mycorp.toml is preserved untouched.
      expect(
        await File('${userDir.path}/mycorp.toml').readAsString(),
        realCustom,
      );
      // The example is created under its prefixed name.
      expect(
        await File('${userDir.path}/example.provider.toml').readAsString(),
        'original',
      );
    });
  });

  group('isExampleProviderFile', () {
    test('matches `example.` prefix', () {
      expect(isExampleProviderFile('example.provider.toml'), isTrue);
      expect(isExampleProviderFile('example.deepseek.toml'), isTrue);
      expect(
        isExampleProviderFile('/full/path/to/example.provider.toml'),
        isTrue,
      );
    });

    test('does not match real provider files', () {
      expect(isExampleProviderFile('openai.toml'), isFalse);
      expect(isExampleProviderFile('deepseek.toml'), isFalse);
      expect(isExampleProviderFile('/full/path/to/deepseek.toml'), isFalse);
    });

    test('does not match files that merely contain "example" in the name', () {
      expect(isExampleProviderFile('myexample.toml'), isFalse);
      expect(isExampleProviderFile('exampleless.toml'), isFalse);
    });

    test('does not match non-TOML files', () {
      expect(isExampleProviderFile('example.provider.json'), isFalse);
      expect(isExampleProviderFile('example.provider.md'), isFalse);
    });
  });
}
