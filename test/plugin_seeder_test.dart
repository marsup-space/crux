import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:crux/src/services/plugin_seeder.dart';

void main() {
  group('seedBundledPlugins', () {
    late Directory builtInDir;
    late Directory userDir;

    setUp(() async {
      builtInDir = await Directory.systemTemp.createTemp('crux_bundled_');
      userDir = await Directory.systemTemp.createTemp('crux_user_plugins_');
    });

    tearDown(() async {
      if (await builtInDir.exists()) {
        await builtInDir.delete(recursive: true);
      }
      if (await userDir.exists()) {
        await userDir.delete(recursive: true);
      }
    });

    Future<void> bundle(String name, String content) =>
        File('${builtInDir.path}/$name').writeAsString(content);

    File userFile(String name) => File('${userDir.path}/$name');

    test('returns empty list when built-in dir does not exist', () async {
      await builtInDir.delete(recursive: true);
      final results = await seedBundledPlugins(
        builtInDir: builtInDir,
        userDir: userDir,
      );
      expect(results, isEmpty);
    });

    test('creates user dir if missing', () async {
      await userDir.delete(recursive: true);
      await bundle('my-notes.toml', 'id = "my-notes"\n');
      await seedBundledPlugins(builtInDir: builtInDir, userDir: userDir);
      expect(userDir.existsSync(), isTrue);
    });

    test('creates spec on first run and records marker', () async {
      const content = 'id = "my-notes"\n';
      await bundle('my-notes.toml', content);

      final results = await seedBundledPlugins(
        builtInDir: builtInDir,
        userDir: userDir,
      );

      expect(results, hasLength(1));
      expect(results.single.action, PluginSeedAction.created);
      expect(await userFile('my-notes.toml').readAsString(), content);

      final marker = jsonDecode(
        await File('${userDir.path}/$kPluginSeedMarkerFileName').readAsString(),
      );
      expect(marker, isA<Map<String, dynamic>>());
      expect(marker, containsPair('my-notes.toml', anything));
    });

    test('second run is unchanged (idempotent)', () async {
      await bundle('my-notes.toml', 'id = "my-notes"\n');
      await seedBundledPlugins(builtInDir: builtInDir, userDir: userDir);

      final results = await seedBundledPlugins(
        builtInDir: builtInDir,
        userDir: userDir,
      );

      expect(results.single.action, PluginSeedAction.unchanged);
    });

    test('adopts a hand-copied identical file into the marker', () async {
      const content = 'id = "my-notes"\n';
      await bundle('my-notes.toml', content);
      // Hand-copied BEFORE any seed ran: no marker, identical bytes.
      await userFile('my-notes.toml').writeAsString(content);

      final results = await seedBundledPlugins(
        builtInDir: builtInDir,
        userDir: userDir,
      );

      expect(results.single.action, PluginSeedAction.unchanged);
      final marker = jsonDecode(
        await File('${userDir.path}/$kPluginSeedMarkerFileName').readAsString(),
      ) as Map<String, dynamic>;
      expect(marker, containsPair('my-notes.toml', anything));
    });

    test('updates an unmodified seeded spec when the bundle changes', () async {
      await bundle('my-notes.toml', 'id = "my-notes"\nlabel = "v1"\n');
      await seedBundledPlugins(builtInDir: builtInDir, userDir: userDir);

      // Upgrade: bundled content changes, user file untouched.
      await bundle('my-notes.toml', 'id = "my-notes"\nlabel = "v2"\n');
      final results = await seedBundledPlugins(
        builtInDir: builtInDir,
        userDir: userDir,
      );

      expect(results.single.action, PluginSeedAction.updated);
      expect(
        await userFile('my-notes.toml').readAsString(),
        'id = "my-notes"\nlabel = "v2"\n',
      );
    });

    test('never overwrites a user-modified spec', () async {
      await bundle('my-notes.toml', 'id = "my-notes"\n');
      await seedBundledPlugins(builtInDir: builtInDir, userDir: userDir);
      await userFile('my-notes.toml').writeAsString('id = "my-notes"\n# mine');

      await bundle('my-notes.toml', 'id = "my-notes"\n# v2');
      final results = await seedBundledPlugins(
        builtInDir: builtInDir,
        userDir: userDir,
      );

      expect(results.single.action, PluginSeedAction.userModified);
      expect(
        await userFile('my-notes.toml').readAsString(),
        'id = "my-notes"\n# mine',
      );
      // Stays user-owned on every later run, even without further
      // bundle changes.
      final again = await seedBundledPlugins(
        builtInDir: builtInDir,
        userDir: userDir,
      );
      expect(again.single.action, PluginSeedAction.userModified);
    });

    test('does not resurrect a deleted spec', () async {
      await bundle('my-notes.toml', 'id = "my-notes"\n');
      await seedBundledPlugins(builtInDir: builtInDir, userDir: userDir);
      await userFile('my-notes.toml').delete();

      final results = await seedBundledPlugins(
        builtInDir: builtInDir,
        userDir: userDir,
      );

      expect(results.single.action, PluginSeedAction.deleted);
      expect(userFile('my-notes.toml').existsSync(), isFalse);
    });

    test('a deleted spec stays dead across runs', () async {
      await bundle('my-notes.toml', 'id = "my-notes"\n');
      await seedBundledPlugins(builtInDir: builtInDir, userDir: userDir);
      await userFile('my-notes.toml').delete();
      await seedBundledPlugins(builtInDir: builtInDir, userDir: userDir);

      // Re-run after a bundle change: still not resurrected.
      await bundle('my-notes.toml', 'id = "my-notes"\n# v2');
      final results = await seedBundledPlugins(
        builtInDir: builtInDir,
        userDir: userDir,
      );

      expect(results.single.action, PluginSeedAction.deleted);
      expect(userFile('my-notes.toml').existsSync(), isFalse);
    });

    test('corrupt marker is treated as empty (conservative)', () async {
      await bundle('my-notes.toml', 'id = "my-notes"\n');
      // A user file that matches nothing, with a corrupt marker.
      await userFile('my-notes.toml').writeAsString('id = "my-notes"\n# mine');
      await File('${userDir.path}/$kPluginSeedMarkerFileName')
          .writeAsString('{not json');

      final results = await seedBundledPlugins(
        builtInDir: builtInDir,
        userDir: userDir,
      );

      expect(results.single.action, PluginSeedAction.userModified);
      expect(
        await userFile('my-notes.toml').readAsString(),
        'id = "my-notes"\n# mine',
      );
    });

    test('marker file is invisible to the plugin registry scan', () async {
      // The registry only reads `*.toml`; the marker must not collide
      // with that glob even after a seed + update cycle.
      await bundle('my-notes.toml', 'id = "my-notes"\n');
      await seedBundledPlugins(builtInDir: builtInDir, userDir: userDir);
      await bundle('my-notes.toml', 'id = "my-notes"\n# v2');
      await seedBundledPlugins(builtInDir: builtInDir, userDir: userDir);

      final tomls = userDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.toml'))
          .map((f) => f.path)
          .toList();
      expect(tomls, hasLength(1));
      expect(tomls.single, endsWith('my-notes.toml'));
    });
  });
}
