import 'dart:async';
import 'dart:io';

import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:crux/src/components/setup_guide.dart';
import 'package:crux/src/i18n/locale_config_store.dart';
import 'package:crux/src/i18n/locale_controller.dart';
import 'package:crux/src/services/codex_oauth.dart';
import 'package:crux/src/services/provider_service.dart';
import 'package:crux/src/services/providers/tinyfish_web_provider.dart';
import 'package:crux/src/services/runtime_setup_service.dart';
import 'package:crux/src/services/terminal_font_service.dart';
import 'package:crux/src/services/web_provider_registry.dart';
import 'package:crux/src/theme/crux_theme.dart';
import 'package:crux/src/theme/theme_config_store.dart';
import 'package:crux/src/theme/theme_controller.dart';
import 'package:crux/src/theme/theme_loader.dart';
import 'package:crux/src/theme/theme_registry.dart';
import 'package:crux/src/utils/url_launcher.dart';

void main() {
  late Directory tempDir;
  late ProviderService providers;
  late WebProviderRegistry web;
  late ThemeController themes;
  late LocaleController locale;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('crux_setup_guide_');
    final providerDir = Directory(p.join(tempDir.path, 'providers'));
    await providerDir.create();
    await File(p.join(providerDir.path, 'test.toml')).writeAsString('''
type = "openai_compatible"
endpoint_url = "https://example.invalid"

[[models]]
id = "test-model"
name = "Test Model"
context_size = 4096
''');
    providers = ProviderService(
      userProvidersDir: providerDir.path,
      userDataDirOverride: tempDir.path,
    );
    await providers.initialize();
    web = WebProviderRegistry(userDataDirOverride: tempDir.path)
      ..register(TinyFishWebProvider(envLookup: () => const {}));
    await web.initialize();
    final config = File(p.join(tempDir.path, 'config.toml'));
    final lightTheme = ThemeLoader.parse(
      'name = "Test Light"\nbrightness = "light"\n',
      id: 'test-light',
    );
    themes = await ThemeController.create(
      registry: ThemeRegistry(
        themes: {
          'dracula': CruxThemeData.draculaFallback,
          'test-light': lightTheme,
        },
        orderedIds: const ['dracula', 'test-light'],
      ),
      configStore: ThemeConfigStore(config),
    );
    locale = await LocaleController.create(
      configStore: LocaleConfigStore(config),
    );
  });

  tearDown(() async {
    await web.dispose();
    themes.dispose();
    locale.dispose();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Component guide({
    Future<void> Function(String)? onFinish,
    PrerequisiteCheck? ensureSemble,
    PrerequisiteCheck? ensureRipgrep,
    VoidCallback? onQuit,
    CodexLoginStarter? beginCodexLogin,
    CodexLoginWaiter? waitForCodexLogin,
    ClipboardWriter? copyToClipboard,
    Map<String, String> Function()? environment,
    TerminalFontService? terminalFont,
    Future<void> Function(RuntimeProgressCallback)? installMapleFont,
  }) => CruxTheme(
    data: themes.activeTheme,
    child: SetupGuide(
      providerService: providers,
      webProviderRegistry: web,
      themeController: themes,
      localeController: locale,
      testProvider: (_, _) async => null,
      testWeb: () async => null,
      launchUrl: (_) => UrlLaunchResult.launched,
      ensureSemble: ensureSemble ?? (progress) async => progress(1, 'ready'),
      ensureRipgrep: ensureRipgrep ?? (progress) async => progress(1, 'ready'),
      beginCodexLogin: beginCodexLogin ?? CodexOAuth.beginDeviceLogin,
      waitForCodexLogin: waitForCodexLogin ?? CodexOAuth.waitForDeviceLogin,
      copyToClipboard: copyToClipboard ?? ClipboardManager.copy,
      environment: environment,
      terminalFont: terminalFont,
      installMapleFont: installMapleFont,
      onQuit: onQuit,
      onFinish: onFinish ?? (_) async {},
    ),
  );

  test('is a scrollable single page in a short terminal', () async {
    await testNocterm('setup short terminal', (tester) async {
      await tester.pumpComponent(
        Container(width: 52, height: 14, child: guide()),
      );
      await tester.pump(const Duration(milliseconds: 20));

      expect(tester.terminalState, containsText('CRUX  SETUP'));
      expect(tester.terminalState, containsText('Language'));

      var sawTinyFish = false;
      var sawFinish = false;
      for (var i = 0; i < 10; i++) {
        sawTinyFish |= tester.terminalState.findText('TinyFish').isNotEmpty;
        sawFinish |= tester.terminalState.findText('Finish setup').isNotEmpty;
        await tester.sendKey(LogicalKey.pageDown);
      }
      sawTinyFish |= tester.terminalState.findText('TinyFish').isNotEmpty;
      sawFinish |= tester.terminalState.findText('Finish setup').isNotEmpty;
      expect(sawTinyFish, isTrue);
      expect(sawFinish, isTrue);
    }, size: const Size(52, 14));
  });

  test('uses an equal-width two-column grid in a wide terminal', () async {
    await testNocterm('setup wide terminal', (tester) async {
      await tester.pumpComponent(
        Container(width: 140, height: 60, child: guide()),
      );
      await tester.pump(const Duration(milliseconds: 20));

      final language = tester.terminalState.findText('Language').single;
      final theme = tester.terminalState.findText('Theme').single;
      final providersTitle = tester.terminalState
          .findText('LLM providers')
          .single;
      final auxiliary = tester.terminalState.findText('Auxiliary model').single;
      expect(theme.x, greaterThan(language.x));
      expect(providersTitle.x, language.x);
      expect(auxiliary.x, theme.x);
      expect(providersTitle.y, greaterThan(language.y));
      expect(auxiliary.y, greaterThan(theme.y));
      final providerHint = tester.terminalState.findText('At least one').single;
      final connected = tester.terminalState.findText('Connected  —').single;
      expect(
        connected.y,
        providerHint.y,
        reason: 'provider connection state should stay on the hint row',
      );

      int cardWidth(String title) {
        final match = tester.terminalState.findText(title).single;
        final line = tester.terminalState.getText().split('\n')[match.y];
        final left = line.lastIndexOf('╭', match.x);
        final right = line.indexOf('╮', match.x);
        return right - left + 1;
      }

      final expectedWidth = cardWidth('Language');
      expect(cardWidth('Theme'), expectedWidth);
      expect(cardWidth('LLM providers'), expectedWidth);
      expect(cardWidth('Auxiliary model'), expectedWidth);
      expect(
        cardWidth('Ready to launch'),
        greaterThanOrEqualTo(expectedWidth * 2 + 2),
        reason: 'the launch card should span both responsive columns',
      );

      expect(tester.terminalState, containsText('Dark  1'));
      expect(tester.terminalState, containsText('Light  1'));
      final darkTheme = tester.terminalState.findText('dracula').single;
      final lightTheme = tester.terminalState.findText('test-light').single;
      expect(lightTheme.x, greaterThan(darkTheme.x));
      expect(lightTheme.y, darkTheme.y);

      final languageLine = tester.terminalState.getText().split(
        '\n',
      )[language.y];
      final languageLeft = languageLine.lastIndexOf('╭', language.x);
      final borderY = language.y + 2;
      expect(
        tester.terminalState.getCellAt(languageLeft, borderY)?.style.color,
        themes.activeTheme.accent,
      );
      await tester.hover(language.x, borderY);
      expect(
        tester.terminalState.getCellAt(languageLeft, borderY)?.style.color,
        themes.activeTheme.outlineBright,
      );
    }, size: const Size(140, 60));
  });

  test('loads a saved TinyFish key without asking for it again', () async {
    await web.setApiKey('tinyfish', 'tf-persisted');
    final reloadedWeb = WebProviderRegistry(userDataDirOverride: tempDir.path)
      ..register(TinyFishWebProvider(envLookup: () => const {}));

    await testNocterm('setup loads saved TinyFish key', (tester) async {
      await tester.pumpComponent(
        Container(
          width: 140,
          height: 60,
          child: CruxTheme(
            data: themes.activeTheme,
            child: SetupGuide(
              providerService: providers,
              webProviderRegistry: reloadedWeb,
              themeController: themes,
              localeController: locale,
              testWeb: () async => null,
              launchUrl: (_) => UrlLaunchResult.launched,
              ensureSemble: (progress) async => progress(1, 'ready'),
              ensureRipgrep: (progress) async => progress(1, 'ready'),
              onFinish: (_) async {},
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 30));

      expect(tester.terminalState, containsText('Saved TinyFish key loaded'));
      expect(tester.terminalState, containsText('Configured'));
      expect(tester.terminalState, containsText('Save changes + test'));
      expect(tester.terminalState, containsText('••••'));
      expect(tester.terminalState.findText('tf-persisted'), isEmpty);
      expect(tester.terminalState.findText('Paste TinyFish API key'), isEmpty);
      expect(
        tester.terminalState.findText('Create account + API key'),
        isEmpty,
      );
      expect(reloadedWeb.getApiKey('tinyfish'), 'tf-persisted');
    }, size: const Size(140, 60));
    await reloadedWeb.dispose();
  });

  test('a persisted connected provider starts with a completed card', () async {
    await providers.setApiKey('test', 'sk-persisted');

    await testNocterm('setup restores provider completion', (tester) async {
      await tester.pumpComponent(
        Container(width: 140, height: 60, child: guide()),
      );
      await tester.pump(const Duration(milliseconds: 20));

      expect(tester.terminalState, containsText('Connected  test'));
      final title = tester.terminalState.findText('LLM providers').single;
      final line = tester.terminalState.getText().split('\n')[title.y];
      final left = line.lastIndexOf('╭', title.x);
      expect(
        tester.terminalState.getCellAt(left, title.y)?.style.color,
        themes.activeTheme.accent,
        reason: 'a persisted connected provider should complete the card',
      );
    }, size: const Size(140, 60));
  });

  test('restores the saved auxiliary-model selection on reopen', () async {
    await providers.setApiKey('test', 'sk-persisted');
    await providers.setAuxiliaryModel('test/test-model');

    await testNocterm('setup restores saved auxiliary model', (tester) async {
      await tester.pumpComponent(
        Container(width: 140, height: 60, child: guide()),
      );
      await tester.pump(const Duration(milliseconds: 20));

      expect(tester.terminalState, containsText('Test Model'));
      expect(
        tester.terminalState,
        containsText('Saved auxiliary model loaded'),
      );
      final title = tester.terminalState.findText('Auxiliary model').single;
      final line = tester.terminalState.getText().split('\n')[title.y];
      final left = line.lastIndexOf('╭', title.x);
      expect(
        tester.terminalState.getCellAt(left, title.y)?.style.color,
        themes.activeTheme.accent,
      );
    }, size: const Size(140, 60));
  });

  test(
    'Esc exits once an LLM is configured without requiring auxiliary setup',

    () async {
      await providers.setApiKey('test', 'sk-persisted');
      var finishedWith = '';

      await testNocterm('setup Esc with configured LLM', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 24,
            child: guide(onFinish: (model) async => finishedWith = model),
          ),
        );
        await tester.pump(const Duration(milliseconds: 20));

        expect(providers.auxiliaryModel, isNull);
        expect(tester.terminalState, containsText('Esc exit setup'));
        await tester.sendEscape();

        await tester.pump();

        expect(finishedWith, 'test/test-model');
        expect(providers.auxiliaryModel, isNull);
      }, size: const Size(80, 24));
    },
  );

  test('Esc stays in setup while no LLM is configured', () async {
    var finishCalls = 0;

    await testNocterm('setup Esc without configured LLM', (tester) async {
      await tester.pumpComponent(
        Container(
          width: 80,
          height: 24,
          child: guide(onFinish: (_) async => finishCalls++),
        ),
      );
      await tester.pump(const Duration(milliseconds: 20));

      expect(tester.terminalState.findText('Esc exit setup'), isEmpty);
      await tester.sendEscape();
      await tester.pump();

      expect(finishCalls, 0);

      expect(tester.terminalState, containsText('CRUX  SETUP'));
    }, size: const Size(80, 24));
  });

  test(
    'Esc exits from a focused key field once an LLM is configured',
    () async {
      await providers.setApiKey('test', 'sk-persisted');
      var finishedWith = '';

      await testNocterm('setup field Esc with configured LLM', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 24,
            child: guide(onFinish: (model) async => finishedWith = model),
          ),
        );
        await tester.pump(const Duration(milliseconds: 20));

        for (var i = 0; i < 16; i++) {
          await tester.sendTab();
        }
        await tester.sendEscape();
        await tester.pump();

        expect(finishedWith, 'test/test-model');
      }, size: const Size(80, 24));
    },
  );

  test('language choices save immediately and include reply policy', () async {
    await testNocterm('setup language settings', (tester) async {
      await tester.pumpComponent(
        Container(width: 80, height: 24, child: guide()),
      );
      await tester.pump(const Duration(milliseconds: 20));

      expect(tester.terminalState, containsText('Interface language'));
      expect(tester.terminalState, containsText('Reply language'));
      expect(tester.terminalState.findText('Verify & save'), isEmpty);

      await tester.sendTab();
      await tester.sendEnter();
      await tester.pump(const Duration(milliseconds: 20));
      expect(locale.activeCode, 'zh');

      await tester.sendTab();
      await tester.sendTab();
      await tester.sendEnter();
      await tester.pump(const Duration(milliseconds: 20));
      expect(locale.replyLanguageCode, 'auto');
    }, size: const Size(80, 24));
  });

  test(
    'mouse click moves the focus border between language controls',
    () async {
      await testNocterm('setup language mouse focus', (tester) async {
        await tester.pumpComponent(
          Container(width: 80, height: 24, child: guide()),
        );
        await tester.pump(const Duration(milliseconds: 20));

        final interfaceChoice = tester.terminalState.findText('English').single;
        final replyChoice = tester.terminalState.findText('Auto-detect').single;

        int leftBorderX(int x, int y) {
          final line = tester.terminalState.getText().split('\n')[y];
          final cardBorder = line.indexOf('│');
          return line.indexOf('│', cardBorder + 1);
        }

        final interfaceBorderX = leftBorderX(
          interfaceChoice.x,
          interfaceChoice.y,
        );
        final replyBorderX = leftBorderX(replyChoice.x, replyChoice.y);
        expect(
          tester.terminalState
              .getCellAt(interfaceBorderX, interfaceChoice.y)
              ?.style
              .color,
          themes.activeTheme.buttonTextFocused,
        );
        expect(
          tester.terminalState
              .getCellAt(replyBorderX, replyChoice.y)
              ?.style
              .color,
          themes.activeTheme.outline,
        );

        await tester.tap(replyChoice.x + 1, replyChoice.y);
        await tester.hover(79, 23);
        await tester.pump(const Duration(milliseconds: 20));

        expect(
          tester.terminalState
              .getCellAt(interfaceBorderX, interfaceChoice.y)
              ?.style
              .color,
          themes.activeTheme.outline,
        );
        expect(
          tester.terminalState
              .getCellAt(replyBorderX, replyChoice.y)
              ?.style
              .color,
          themes.activeTheme.buttonTextFocused,
        );
      }, size: const Size(80, 24));
    },
  );

  test('header is prominent and Ctrl+C uses the supplied quit path', () async {
    var quitCalls = 0;
    await testNocterm('setup header and quit', (tester) async {
      await tester.pumpComponent(
        Container(
          width: 80,
          height: 24,
          child: guide(onQuit: () => quitCalls++),
        ),
      );
      await tester.pump(const Duration(milliseconds: 20));

      expect(tester.terminalState, containsText('CRUX  SETUP'));
      expect(tester.terminalState, containsText('Ctrl+C quit'));
      await tester.sendKeyEvent(
        KeyboardEvent(
          logicalKey: LogicalKey.keyC,
          modifiers: const ModifierKeys(ctrl: true),
        ),
      );
      expect(quitCalls, 1);

      // Ctrl+C must still escape when a secret TextField owns focus.
      for (var i = 0; i < 16; i++) {
        await tester.sendTab();
      }
      await tester.sendKeyEvent(
        KeyboardEvent(
          logicalKey: LogicalKey.keyC,
          modifiers: const ModifierKeys(ctrl: true),
        ),
      );
      expect(quitCalls, 2);
    }, size: const Size(80, 24));
  });

  test('regular providers show only the API key flow', () async {
    await testNocterm('setup key provider', (tester) async {
      await tester.pumpComponent(
        Container(width: 80, height: 24, child: guide()),
      );
      await tester.pump(const Duration(milliseconds: 20));
      for (var i = 0; i < 14; i++) {
        await tester.sendTab();
      }

      expect(tester.terminalState, containsText('API key'));
      expect(tester.terminalState, containsText('Paste API key'));
      expect(tester.terminalState, containsText('Save + test'));
      final input = tester.terminalState.findText('Paste API key').single;
      final save = tester.terminalState.findText('Save + test').single;
      final inputInterior = tester.terminalState.getCellAt(
        input.x + 2,
        input.y,
      );
      expect(
        save.x,
        input.x,
        reason: 'input and action must share a left edge',
      );
      expect(
        inputInterior?.style.backgroundColor,
        themes.activeTheme.surface,
        reason: 'inputs should inherit the card surface, not use a heavy fill',
      );
      expect(
        tester.terminalState.getCellAt(save.x, save.y)?.style.backgroundColor,
        themes.activeTheme.buttonBackground,
      );
      expect(
        themes.activeTheme.buttonBackground,
        isNot(themes.activeTheme.surface),
        reason: 'a standard button must remain visible on a card surface',
      );
      expect(
        themes.activeTheme.buttonBackground,
        isNot(themes.activeTheme.surfaceVariant),
        reason: 'default buttons should not create heavy solid color bars',
      );
      expect(tester.terminalState.findText('Sign in with ChatGPT'), isEmpty);
      expect(tester.terminalState.findText('https://example.invalid'), isEmpty);
    }, size: const Size(80, 24));
  });

  test(
    'provider API key field accepts mouse focus and keyboard input',
    () async {
      await testNocterm('setup provider mouse focus', (tester) async {
        await tester.pumpComponent(
          Container(width: 80, height: 24, child: guide()),
        );
        await tester.pump(const Duration(milliseconds: 20));
        for (var i = 0; i < 14; i++) {
          await tester.sendTab();
        }

        final input = tester.terminalState.findText('Paste API key').single;
        await tester.tap(input.x + 2, input.y);
        await tester.pump(const Duration(milliseconds: 20));
        await tester.enterText('mouse-key');
        await tester.sendTab();
        await tester.sendEnter();
        await tester.pump(const Duration(milliseconds: 20));

        expect(providers.getApiKey('test'), 'mouse-key');
        await tester.sendKey(LogicalKey.pageUp);
        await tester.hover(79, 0);
        await tester.pump(const Duration(milliseconds: 20));
        final providerTitle = tester.terminalState
            .findText('LLM providers')
            .single;
        final providerTitleLine = tester.terminalState.getText().split(
          '\n',
        )[providerTitle.y];
        final providerLeft = providerTitleLine.lastIndexOf(
          '╭',
          providerTitle.x,
        );
        expect(
          tester.terminalState
              .getCellAt(providerLeft, providerTitle.y)
              ?.style
              .color,
          themes.activeTheme.accent,
          reason: 'a verified setup card should use the header accent border',
        );
      }, size: const Size(80, 24));
    },
  );

  test('Codex shows only ChatGPT sign-in and hides endpoint and key', () async {
    final providerDir = Directory(p.join(tempDir.path, 'providers'));
    await File(p.join(providerDir.path, 'codex.toml')).writeAsString('''
type = "codex"
endpoint_url = "https://chatgpt.com/backend-api/codex"

[[models]]
id = "gpt-test"
name = "GPT Test"
context_size = 4096
''');
    providers = ProviderService(
      userProvidersDir: providerDir.path,
      userDataDirOverride: tempDir.path,
    );
    await providers.initialize();

    await testNocterm('setup codex provider', (tester) async {
      await tester.pumpComponent(
        Container(width: 80, height: 24, child: guide()),
      );
      await tester.pump(const Duration(milliseconds: 20));
      for (var i = 0; i < 14; i++) {
        await tester.sendTab();
      }

      expect(tester.terminalState, containsText('Sign in with ChatGPT'));
      expect(tester.terminalState.findText('API key'), isEmpty);
      expect(tester.terminalState.findText('Save + test'), isEmpty);
      expect(
        tester.terminalState.findText('https://chatgpt.com/backend-api/codex'),
        isEmpty,
      );
    }, size: const Size(80, 24));
  });

  test('Codex device login exposes a working copy-code button', () async {
    final providerDir = Directory(p.join(tempDir.path, 'providers'));
    await File(p.join(providerDir.path, 'codex.toml')).writeAsString('''
type = "codex"
endpoint_url = "https://chatgpt.com/backend-api/codex"

[[models]]
id = "gpt-test"
name = "GPT Test"
context_size = 4096
''');
    providers = ProviderService(
      userProvidersDir: providerDir.path,
      userDataDirOverride: tempDir.path,
    );
    await providers.initialize();
    final approval = Completer<String>();
    String? copied;

    await testNocterm('setup codex copies device code', (tester) async {
      await tester.pumpComponent(
        Container(
          width: 80,
          height: 24,
          child: guide(
            beginCodexLogin: () async => (
              verificationUrl: 'https://auth.example/device',
              userCode: 'ABCD-EFGH',
              deviceId: 'device-1',
              interval: Duration.zero,
            ),
            waitForCodexLogin: ({
              required deviceId,
              required userCode,
              required interval,
            }) => approval.future,
            copyToClipboard: (text) {
              copied = text;
              return true;
            },
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 20));

      for (var i = 0; i < 16; i++) {
        await tester.sendTab();
      }
      await tester.sendEnter();
      await tester.pump(const Duration(milliseconds: 20));

      expect(tester.terminalState, containsText('ABCD-EFGH'));
      final copyButton = tester.terminalState.findText('Copy code').single;
      await tester.tap(copyButton.x + 1, copyButton.y);
      await tester.pump(const Duration(milliseconds: 20));
      expect(copied, 'ABCD-EFGH');
      expect(tester.terminalState, containsText('Device code copied'));

      approval.complete('test-codex-credential');
      await tester.pump(const Duration(milliseconds: 20));
    }, size: const Size(80, 24));
  });

  test('failed runtime installs expose a working retry action', () async {
    var sembleAttempts = 0;
    var ripgrepAttempts = 0;
    Future<void> flakySemble(RuntimeProgressCallback progress) async {
      if (++sembleAttempts == 1) throw StateError('model download failed');
      progress(1, 'ready');
    }

    Future<void> flakyRipgrep(RuntimeProgressCallback progress) async {
      if (++ripgrepAttempts == 1) throw StateError('rg download failed');
      progress(1, 'ready');
    }

    await testNocterm('setup runtime retry', (tester) async {
      await tester.pumpComponent(
        Container(
          width: 80,
          height: 24,
          child: guide(ensureSemble: flakySemble, ensureRipgrep: flakyRipgrep),
        ),
      );
      await tester.pump(const Duration(milliseconds: 20));

      for (var i = 0; i < 25; i++) {
        await tester.sendTab();
      }
      await tester.sendKey(LogicalKey.pageDown);
      expect(tester.terminalState, containsText('Retry install'));
      await tester.sendEnter();
      await tester.pump(const Duration(milliseconds: 20));

      expect(sembleAttempts, 2);
      expect(ripgrepAttempts, 2);
      expect(
        tester.terminalState,
        containsText('Semble model and ripgrep are ready'),
      );
    }, size: const Size(80, 24));
  });

  test('runtime downloads report live progress for both assets', () async {
    final sembleGate = Completer<void>();
    final ripgrepGate = Completer<void>();
    await testNocterm('setup runtime progress', (tester) async {
      await tester.pumpComponent(
        Container(
          width: 80,
          height: 24,
          child: guide(
            ensureSemble: (progress) async {
              progress(
                0.42,
                'downloading_model',
                const RuntimeTransferStats(
                  receivedBytes: 8 * 1024 * 1024,
                  totalBytes: 20 * 1024 * 1024,
                  bytesPerSecond: 2.5 * 1024 * 1024,
                  source: 'hf-mirror.com',
                ),
              );
              await sembleGate.future;
            },
            ensureRipgrep: (progress) async {
              progress(
                0.65,
                'downloading',
                const RuntimeTransferStats(
                  receivedBytes: 4 * 1024 * 1024,
                  totalBytes: 8 * 1024 * 1024,
                  bytesPerSecond: 1024 * 1024,
                  source: 'github.com',
                ),
              );
              await ripgrepGate.future;
            },
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 20));

      for (var i = 0; i < 10; i++) {
        await tester.sendKey(LogicalKey.pageDown);
      }
      expect(tester.terminalState, containsText('42%'));
      expect(tester.terminalState, containsText('65%'));
      expect(tester.terminalState, containsText('downloading model'));
      expect(tester.terminalState, containsText('8.0 MB / 20.0 MB'));
      expect(tester.terminalState, containsText('2.5 MB/s'));
      expect(tester.terminalState, containsText('hf-mirror.com'));

      sembleGate.complete();
      ripgrepGate.complete();
      await tester.pump(const Duration(milliseconds: 20));
      expect(tester.terminalState.findText('100%'), hasLength(2));
      expect(tester.terminalState, containsText('ready'));
    }, size: const Size(80, 24));
  });

  test('TinyFish input and standard action button share a left edge', () async {
    await testNocterm('setup web alignment', (tester) async {
      await tester.pumpComponent(
        Container(width: 80, height: 24, child: guide()),
      );
      await tester.pump(const Duration(milliseconds: 20));
      for (var i = 0; i < 22; i++) {
        await tester.sendTab();
      }

      final input = tester.terminalState
          .findText('Paste TinyFish API key')
          .single;
      final stepOne = tester.terminalState
          .findText('1  Create account + API key')
          .single;
      final stepTwo = tester.terminalState.findText('2  API key').single;
      final save = tester.terminalState
          .findText('3  Save + test search')
          .single;
      expect(stepTwo.x, stepOne.x);
      expect(save.x, stepOne.x);
      expect(save.x, input.x);
    }, size: const Size(80, 24));
  });

  test('keyboard flow saves every required setting and finishes', () async {
    var finishedWith = '';
    await testNocterm('setup complete flow', (tester) async {
      await tester.pumpComponent(
        Container(
          width: 80,
          height: 24,
          child: guide(onFinish: (model) async => finishedWith = model),
        ),
      );
      await tester.pump(const Duration(milliseconds: 20));

      // Focus 16 is the provider secret field.
      for (var i = 0; i < 16; i++) {
        await tester.sendTab();
      }
      await tester.enterText('sk-test');
      await tester.sendTab();
      await tester.sendEnter();
      await tester.pump(const Duration(milliseconds: 20));
      expect(providers.getApiKey('test'), 'sk-test');

      // Move through the auxiliary picker and verify its sole model.
      for (var i = 0; i < 3; i++) {
        await tester.sendTab();
      }
      await tester.sendEnter();
      await tester.pump(const Duration(milliseconds: 20));
      expect(providers.auxiliaryModel, 'test/test-model');

      // TinyFish open button → key field → save/test.
      await tester.sendTab();
      await tester.sendTab();
      await tester.enterText('tf-test');
      await tester.sendTab();
      await tester.sendEnter();
      await tester.pump(const Duration(milliseconds: 20));
      expect(web.getApiKey('tinyfish'), 'tf-test');

      await tester.sendTab();
      await tester.sendEnter();
      await tester.pump(const Duration(milliseconds: 20));
      expect(finishedWith, 'test/test-model');
    }, size: const Size(80, 24));
  });

  group('terminal font card', () {
    late Directory fontDir;
    late TerminalFontService fontService;
    late _FakeFontService fakeFont;

    setUp(() async {
      fontDir = await Directory.systemTemp.createTemp('crux_setup_font_');
      final wtPackage = Directory(
        p.join(fontDir.path, 'Packages', 'Microsoft.WindowsTerminal_8wekyb3d8bbwe'),
      )..createSync(recursive: true);
      final settingsFile = File(
        p.join(wtPackage.path, 'LocalState', 'settings.json'),
      )..createSync(recursive: true);
      settingsFile.writeAsStringSync('{"profiles": {"defaults": {}}}');
      fontService = TerminalFontService(localAppData: () => fontDir.path);
      fakeFont = _FakeFontService(fontService);
    });

    tearDown(() async {
      if (await fontDir.exists()) await fontDir.delete(recursive: true);
    });

    Map<String, String> Function() wtEnvironment() =>
        () => const {'WT_SESSION': '{abc-123}'};

    test('renders for Windows Terminal with a settings file only', () async {
      await testNocterm('setup font card renders', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 60,
            child: guide(
              environment: wtEnvironment(),
              terminalFont: fakeFont,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 30));

        expect(fakeFont.findCalls, greaterThan(0));
        expect(fakeFont.statusText, isNotNull);
        // Narrow layout stacks the font card below the fold; page down
        // until it renders (same pattern as the short-terminal test).
        var sawCard = false;
        for (var i = 0; i < 12 && !sawCard; i++) {
          sawCard = tester.terminalState.findText('Terminal font').isNotEmpty;
          await tester.sendKey(LogicalKey.pageDown);
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(sawCard, isTrue);
        expect(tester.terminalState, containsText('Optional · opt-in'));
      }, size: const Size(80, 60));

      await testNocterm('setup font card hidden without WT_SESSION', (
        tester,
      ) async {
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 60,
            child: guide(
              environment: () => const {},
              terminalFont: fakeFont,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 30));

        expect(tester.terminalState.findText('Terminal font'), isEmpty);
      }, size: const Size(80, 60));
    });

    test('never writes settings until the user acts', () async {
      await testNocterm('setup font card zero writes', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 30,
            child: guide(
              environment: wtEnvironment(),
              terminalFont: fakeFont,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 30));

        expect(fakeFont.applyCalls, 0);
      }, size: const Size(80, 30));
    });

    test('Apply on focus 32 sends the selected cell width preset', () async {
      await testNocterm('setup font card apply', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 30,
            child: guide(
              environment: wtEnvironment(),
              terminalFont: fakeFont,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 30));

        // Focus 18 (codex sign-in) is skipped for non-codex providers, so
        // 31 tabs land on 32 (Apply).
        for (var i = 0; i < 31; i++) {
          await tester.sendTab();
        }
        await tester.sendEnter();
        await tester.pump(const Duration(milliseconds: 30));

        expect(fakeFont.applyCalls, 1);
        expect(
          fakeFont.lastEdit?.cellWidthPreset,
          CellWidthPreset.defaultWidth,
        );
      }, size: const Size(80, 30));
    });

    test('the install button invokes the injected installer', () async {
      var installCalls = 0;
      await testNocterm('setup font card install', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 60,
            child: guide(
              environment: wtEnvironment(),
              terminalFont: fakeFont,
              installMapleFont: (_) async {
                installCalls++;
              },
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 30));

        // Page down until the install button renders (narrow layout).
        var matches = tester.terminalState.findText(' Install Maple Mono ');
        for (var i = 0; i < 12 && matches.isEmpty; i++) {
          await tester.sendKey(LogicalKey.pageDown);
          await tester.pump(const Duration(milliseconds: 20));
          matches = tester.terminalState.findText(' Install Maple Mono ');
        }
        final install = matches.single;
        await tester.tap(install.x + 1, install.y);
        await tester.pump(const Duration(milliseconds: 30));

        expect(installCalls, 1);
      }, size: const Size(80, 60));
    });
  });
}

/// Records [applyFontSettings] calls while delegating reads to a real
/// [TerminalFontService] backed by a temp directory.
class _FakeFontService extends TerminalFontService {
  final TerminalFontService _inner;
  var applyCalls = 0;
  var findCalls = 0;
  String? statusText;
  FontSettingsEdit? lastEdit;

  _FakeFontService(this._inner) : super(localAppData: _inner.localAppData);

  @override
  File? findSettingsFile() {
    findCalls++;
    return _inner.findSettingsFile();
  }

  @override
  Future<TerminalFontStatus?> loadStatus() async {
    final status = await _inner.loadStatus();
    statusText = status == null ? 'null' : 'file=${status.settingsFile.path}';
    return status;
  }

  @override
  Future<File?> applyFontSettings(FontSettingsEdit edit) async {
    applyCalls++;
    lastEdit = edit;
    return _inner.applyFontSettings(edit);
  }
}
