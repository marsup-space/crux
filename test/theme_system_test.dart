import 'dart:io';

import 'package:nocterm/nocterm.dart' hide isEmpty;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:toml/toml.dart';

import 'package:crux/src/theme/crux_theme.dart';
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
      expect(
        registry.availableIds.take(curatedThemeIds.length),
        curatedThemeIds,
      );
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
          'rosepine-main',
        ]) {
          expect(registry[id]!.brightness, Brightness.dark, reason: id);
        }
        for (final id in const [
          'flexoki',
          'rosepine',
          'electric-orchid',
          'cobalt-bloom',
          'ember-clay',
        ]) {
          expect(registry[id]!.brightness, Brightness.light, reason: id);
        }
      },
    );

    test(
      'rejects malformed TOML, invalid brightness, and malformed color',
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
        // name and brightness stay required.
        expect(
          () => ThemeLoader.parse('brightness = "dark"\n', id: 'bad'),
          throwsFormatException,
        );
        expect(
          () => ThemeLoader.parse('name = "No Brightness"\n', id: 'bad'),
          throwsFormatException,
        );
      },
    );

    test('accepts #RGB shorthand and expands it to #RRGGBB', () async {
      final valid = await File(
        p.join(bundledThemes.path, 'dracula.toml'),
      ).readAsString();
      final theme = ThemeLoader.parse(
        valid
            .replaceFirst('background = "#282A36"', 'background = "#1A2b3C"')
            .replaceFirst('surface = "#21222C"', 'surface = "#abc"'),
        id: 'shorthand',
      );
      expect(theme.background, const Color(0x1A2B3C));
      expect(theme.surface, const Color(0xAABBCC));
    });

    test(
      'missing tokens fall back to Dracula defaults with warnings',
      () async {
        final valid = await File(
          p.join(bundledThemes.path, 'dracula.toml'),
        ).readAsString();
        final warnings = <String>[];
        final theme = ThemeLoader.parse(
          valid
              .replaceFirst('background = "#282A36"\n', '')
              .replaceFirst('heading = "#BD93F9"\n', ''),
          id: 'sparse',
          warnings: warnings,
        );
        expect(theme.background, CruxThemeData.draculaFallback.background);
        expect(
          theme.markdownHeading,
          CruxThemeData.draculaFallback.markdownHeading,
        );
        // Untouched tokens still come from the file itself.
        expect(theme.surface, const Color(0x21222C));
        expect(warnings, hasLength(2));
        expect(warnings.first, contains('[colors] "background"'));
        expect(warnings.last, contains('[markdown] "heading"'));
      },
    );

    test('missing sections fall back wholesale with one warning each', () {
      final warnings = <String>[];
      final theme = ThemeLoader.parse(
        'name = "Bare"\nbrightness = "dark"\n',
        id: 'bare',
        warnings: warnings,
      );
      expect(theme.text, CruxThemeData.draculaFallback.text);
      expect(theme.syntaxKeyword, CruxThemeData.draculaFallback.syntaxKeyword);
      expect(warnings, hasLength(3));
      expect(
        warnings.every((w) => w.contains('section')),
        isTrue,
        reason: warnings.join('\n'),
      );
    });

    test('fallback warnings ride the registry loadErrors channel', () async {
      final userDirectory = await Directory.systemTemp.createTemp(
        'crux_theme_warn_',
      );
      addTearDown(() => userDirectory.delete(recursive: true));
      final file = File(p.join(userDirectory.path, 'partial.toml'));
      await file.writeAsString(
        'name = "Partial"\nbrightness = "dark"\n'
        '[colors]\nbackground = "#000000"\n',
      );

      final registry = await ThemeLoader(
        bundledDirectory: bundledThemes,
        userDirectory: userDirectory,
      ).load();

      expect(registry['partial']!.background, const Color(0x000000));
      expect(
        registry['partial']!.surface,
        CruxThemeData.draculaFallback.surface,
      );
      expect(registry.loadErrors, contains(file.path));
      expect(registry.loadErrors[file.path], contains('fallback defaults'));
    });
  });

  group('derived roles', () {
    final dracula = CruxThemeData.draculaFallback;

    test('assistant falls back to warning; responsePrefix follows it', () {
      expect(dracula.assistantColor, isNull);
      expect(dracula.assistant, dracula.warning);
      expect(dracula.responsePrefix, dracula.assistant);
    });

    test('explicit assistant token wins', () async {
      final theme = await ThemeLoader.loadFile(
        File(p.join(bundledThemes.path, 'dracula.toml')),
        id: 'dracula',
      );
      expect(theme.assistant, const Color(0x50FA7B));
      expect(theme.responsePrefix, const Color(0x50FA7B));
    });

    test('diff roles fall back to success/error with 15% background tints', () {
      expect(dracula.diffAddedColor, isNull);
      expect(dracula.diffAdded, dracula.success);
      expect(dracula.diffRemoved, dracula.error);
      expect(
        dracula.diffAddedBackground,
        Color.lerp(dracula.background, dracula.success, 0.15),
      );
      expect(
        dracula.diffRemovedBackground,
        Color.lerp(dracula.background, dracula.error, 0.15),
      );
    });

    test('explicit diff tokens win', () async {
      final theme = await ThemeLoader.loadFile(
        File(p.join(bundledThemes.path, 'dracula.toml')),
        id: 'dracula',
      );
      expect(theme.diffAdded, const Color(0x50FA7B));
      expect(theme.diffRemoved, const Color(0xFF5555));
      expect(theme.diffAddedBackground, const Color(0x2E4940));
      expect(theme.diffRemovedBackground, const Color(0x48303B));
    });

    test('heading hierarchy derives from heading and text', () {
      expect(dracula.mdH1, dracula.markdownHeading);
      expect(dracula.mdH2, dracula.markdownHeading);
      expect(
        dracula.mdH3,
        Color.lerp(dracula.markdownHeading, dracula.markdownText, 0.25),
      );
      expect(
        dracula.mdH4,
        Color.lerp(dracula.markdownHeading, dracula.markdownText, 0.25),
      );
      expect(
        dracula.mdH5,
        Color.lerp(dracula.markdownHeading, dracula.markdownText, 0.5),
      );
      expect(
        dracula.mdH6,
        Color.lerp(dracula.markdownHeading, dracula.markdownText, 0.5),
      );
    });

    test('optional h1..h6 markdown overrides win', () async {
      final valid = await File(
        p.join(bundledThemes.path, 'dracula.toml'),
      ).readAsString();
      final theme = ThemeLoader.parse(
        valid.replaceFirst(
          'heading = "#BD93F9"',
          'heading = "#BD93F9"\nh3 = "#123456"',
        ),
        id: 'overrides',
      );
      expect(theme.mdH3, const Color(0x123456));
      expect(theme.mdH1, theme.markdownHeading);
    });

    test('onColor picks the theme color with better WCAG contrast', () {
      // On a light chip the dark theme background wins; on a dark
      // chip the light text wins.
      expect(dracula.onColor(const Color(0xFFFFFF)), dracula.background);
      expect(dracula.onColor(const Color(0x000000)), dracula.text);
      // A light theme mirrors this through its own tokens.
      const light = Color(0xFFFFFF);
      const dark = Color(0x24292F);
      final github = CruxThemeData.draculaFallback;
      expect(github.onColor(light), isNot(github.onColor(dark)));
    });
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
      expect(
        registry.availableIds.take(curatedThemeIds.length),
        curatedThemeIds,
      );
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
      await store.writeThemeId('cobalt-bloom');

      expect(await store.readThemeId(), 'cobalt-bloom');
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

        final result = await controller.switchTheme('cobalt-bloom');
        expect(result.persisted, isTrue);
        expect(controller.activeId, 'cobalt-bloom');

        final restarted = await ThemeController.create(
          registry: registry,
          configStore: store,
        );
        expect(restarted.activeId, 'cobalt-bloom');
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

      final result = await controller.switchTheme('cobalt-bloom');
      expect(result.found, isTrue);
      expect(result.persisted, isFalse);
      expect(controller.activeId, 'cobalt-bloom');
    });
  });
}
