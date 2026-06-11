import 'dart:io';

import 'package:nocterm/nocterm.dart' hide isEmpty;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:toml/toml.dart';

import 'package:crux/src/theme/theme_config_store.dart';
import 'package:crux/src/theme/theme_controller.dart';
import 'package:crux/src/theme/theme_loader.dart';
import 'package:crux/src/theme/theme_registry.dart';
import 'package:crux/src/utils/bundled_directory.dart';

void main() {
  final bundledThemes = Directory(p.join(Directory.current.path, 'themes'));

  group('bundled themes', () {
    test('resolves from the package root outside the checkout cwd', () async {
      final unrelatedDirectory = await Directory.systemTemp.createTemp(
        'crux_theme_cwd_',
      );
      addTearDown(() => unrelatedDirectory.delete(recursive: true));

      final resolved = await resolveBundledDirectory(
        'themes',
        executablePath: p.join(unrelatedDirectory.path, 'dart'),
        scriptUri: Uri.file(
          p.join(unrelatedDirectory.path, 'bin', 'wrapper.dart'),
        ),
        launchDirectory: unrelatedDirectory.path,
        packageUriResolver: (_) async =>
            Uri.file(p.join(Directory.current.path, 'lib', 'crux.dart')),
      );

      expect(p.equals(resolved.path, bundledThemes.path), isTrue);
      final registry = await ThemeLoader(
        bundledDirectory: resolved,
        userDirectory: Directory(
          p.join(unrelatedDirectory.path, 'user-themes'),
        ),
      ).load();
      expect(registry.availableIds.take(8), curatedThemeIds);
    });

    test('all curated themes and the example parse completely', () async {
      for (final id in curatedThemeIds) {
        final theme = await ThemeLoader.loadFile(
          File(p.join(bundledThemes.path, '$id.toml')),
          id: id,
        );
        expect(theme.id, id);
      }
      final example = await ThemeLoader.loadFile(
        File(p.join(bundledThemes.path, 'example.theme.toml')),
        id: 'example.theme',
      );
      expect(example.name, 'Example Theme');
    });

    test(
      'curated brightness matches the intended light and dark groups',
      () async {
        final registry = await ThemeLoader(
          bundledDirectory: bundledThemes,
          userDirectory: await Directory.systemTemp.createTemp(
            'crux_theme_empty_',
          ),
        ).load();
        for (final id in const [
          'dracula',
          'onedarkpro',
          'catppuccin',
          'synthwave84',
        ]) {
          expect(registry[id]!.brightness, Brightness.dark, reason: id);
        }
        for (final id in const ['cobalt2', 'flexoki', 'rosepine', 'github']) {
          expect(registry[id]!.brightness, Brightness.light, reason: id);
        }
      },
    );

    test(
      'rejects malformed TOML, invalid brightness, color, and missing token',
      () async {
        final valid = await File(
          p.join(bundledThemes.path, 'dracula.toml'),
        ).readAsString();

        expect(
          () => ThemeLoader.parse('name = [', id: 'bad'),
          throwsA(isA<Exception>()),
        );
        expect(
          () => ThemeLoader.parse(
            valid.replaceFirst('brightness = "dark"', 'brightness = "system"'),
            id: 'bad',
          ),
          throwsFormatException,
        );
        expect(
          () => ThemeLoader.parse(
            valid.replaceFirst('#282A36', '#12345'),
            id: 'bad',
          ),
          throwsFormatException,
        );
        expect(
          () => ThemeLoader.parse(
            valid.replaceFirst('background = "#282A36"\n', ''),
            id: 'bad',
          ),
          throwsFormatException,
        );
      },
    );
  });

  group('ThemeLoader precedence', () {
    late Directory userDirectory;

    setUp(() async {
      userDirectory = await Directory.systemTemp.createTemp(
        'crux_user_themes_',
      );
    });

    tearDown(() async {
      if (await userDirectory.exists()) {
        await userDirectory.delete(recursive: true);
      }
    });

    test('valid user files override bundled IDs', () async {
      final source = await File(
        p.join(bundledThemes.path, 'dracula.toml'),
      ).readAsString();
      await File(p.join(userDirectory.path, 'dracula.toml')).writeAsString(
        source.replaceFirst('name = "Dracula"', 'name = "My Dracula"'),
      );

      final registry = await ThemeLoader(
        bundledDirectory: bundledThemes,
        userDirectory: userDirectory,
      ).load();

      expect(registry['dracula']!.name, 'My Dracula');
      expect(registry.loadErrors, isEmpty);
    });

    test('invalid user override leaves bundled theme available', () async {
      final override = File(p.join(userDirectory.path, 'dracula.toml'));
      await override.writeAsString('name = "Broken"\n');

      final registry = await ThemeLoader(
        bundledDirectory: bundledThemes,
        userDirectory: userDirectory,
      ).load();

      expect(registry['dracula']!.name, 'Dracula');
      expect(registry.loadErrors, contains(override.path));
    });

    test('seeds and excludes example theme from available IDs', () async {
      final registry = await ThemeLoader(
        bundledDirectory: bundledThemes,
        userDirectory: userDirectory,
      ).load();

      expect(
        await File(p.join(userDirectory.path, 'example.theme.toml')).exists(),
        isTrue,
      );
      expect(registry.availableIds, isNot(contains('example.theme')));
      expect(registry.availableIds.take(8), curatedThemeIds);
    });
  });

  group('ThemeConfigStore and ThemeController', () {
    late Directory directory;
    late File configFile;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('crux_theme_config_');
      configFile = File(p.join(directory.path, 'config.toml'));
    });

    tearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    test('persists [ui].theme and preserves unrelated TOML settings', () async {
      await configFile.writeAsString('''
[provider]
default = "openai"

[ui]
compact = true
''');
      final store = ThemeConfigStore(configFile);
      await store.writeThemeId('github');

      expect(await store.readThemeId(), 'github');
      final map = TomlDocument.parse(await configFile.readAsString()).toMap();
      expect((map['provider'] as Map)['default'], 'openai');
      expect((map['ui'] as Map)['compact'], isTrue);
      expect(
        directory.listSync().whereType<File>().where(
          (file) => file.path.endsWith('.tmp'),
        ),
        isEmpty,
      );
    });

    test(
      'missing and unavailable configured themes fall back to Dracula',
      () async {
        final userThemes = Directory(p.join(directory.path, 'themes'));
        final registry = await ThemeLoader(
          bundledDirectory: bundledThemes,
          userDirectory: userThemes,
        ).load();
        await configFile.writeAsString('[ui]\ntheme = "not-a-theme"\n');

        final controller = await ThemeController.create(
          registry: registry,
          configStore: ThemeConfigStore(configFile),
        );
        expect(controller.activeId, 'dracula');
        expect(controller.startupWarning, contains('unavailable'));
      },
    );

    test(
      'switches immediately and persists across controller startup',
      () async {
        final registry = await ThemeLoader(
          bundledDirectory: bundledThemes,
          userDirectory: Directory(p.join(directory.path, 'themes')),
        ).load();
        final store = ThemeConfigStore(configFile);
        final controller = await ThemeController.create(
          registry: registry,
          configStore: store,
        );

        final result = await controller.switchTheme('github');
        expect(result.persisted, isTrue);
        expect(controller.activeId, 'github');

        final restarted = await ThemeController.create(
          registry: registry,
          configStore: store,
        );
        expect(restarted.activeId, 'github');
      },
    );

    test('keeps the selected theme when persistence fails', () async {
      final registry = await ThemeLoader(
        bundledDirectory: bundledThemes,
        userDirectory: Directory(p.join(directory.path, 'themes')),
      ).load();
      final impossibleTarget = Directory(p.join(directory.path, 'config.toml'));
      await impossibleTarget.create();
      final controller = await ThemeController.create(
        registry: registry,
        configStore: ThemeConfigStore(File(impossibleTarget.path)),
      );

      final result = await controller.switchTheme('github');
      expect(result.found, isTrue);
      expect(result.persisted, isFalse);
      expect(controller.activeId, 'github');
    });
  });
}
