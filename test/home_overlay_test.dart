import 'dart:io';

import 'package:drift/native.dart';
import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:crux/src/components/chat_panel.dart';
import 'package:crux/src/i18n/locale_config_store.dart';
import 'package:crux/src/i18n/locale_controller.dart';
import 'package:crux/src/services/provider_service.dart';
import 'package:crux/src/services/recent_projects_store.dart';
import 'package:crux/src/storage/storage.dart';
import 'package:crux/src/theme/crux_theme.dart';
import 'package:crux/src/theme/theme_config_store.dart';
import 'package:crux/src/theme/theme_controller.dart';
import 'package:crux/src/theme/theme_registry.dart';

void main() {
  late Directory tempDir;
  late CruxDatabase db;
  late SessionStore store;
  late ProviderService providerService;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('crux_home_overlay_');
    db = CruxDatabase.forTesting(NativeDatabase.memory());
    store = SessionStore(db);
    providerService = ProviderService(userProvidersDir: tempDir.path);
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<({ThemeController theme, RecentProjectsStore recents})>
  createDependencies() async {
    final themeController = await ThemeController.create(
      registry: ThemeRegistry(
        themes: {'dracula': CruxThemeData.draculaFallback},
        orderedIds: const ['dracula'],
      ),
      configStore: ThemeConfigStore(File(p.join(tempDir.path, 'config.toml'))),
    );
    final recents = RecentProjectsStore.forTesting(
      p.join(tempDir.path, 'recent_projects.json'),
    );
    return (theme: themeController, recents: recents);
  }

  test('home is a full-screen swap: no chat chrome, esc returns', () async {
    final bootState = await loadChatPanelBootState(
      userProvidersDir: tempDir.path,
      providerService: providerService,
      store: store,
      projectPath: tempDir.path,
    );
    final deps = await createDependencies();

    await testNocterm('home screen swap', (tester) async {
      await tester.pumpComponent(
        Container(
          width: 120,
          height: 32,
          child: CruxTheme(
            data: deps.theme.activeTheme,
            child: ChatPanel(
              userProvidersDir: tempDir.path,
              themeController: deps.theme,
              bootState: bootState,
              recentProjectsStore: deps.recents,
              showHomeOnLaunch: true,
            ),
          ),
        ),
      );
      await tester.pump();

      // Home is an independent full screen — no modal chrome. No
      // close button from a Fullpane, and the chat interface is not
      // built underneath (the chat input's "paste" button is gone; the
      // home quick-chat field has its own prompt, not the full input).
      expect(
        tester.terminalState.findText('✕ close').isEmpty,
        isTrue,
        reason: 'home must not show a Fullpane close button',
      );
      expect(
        tester.terminalState.findText('paste').isEmpty,
        isTrue,
        reason: 'chat input must not render while home is open',
      );
      // Home's hero (version line) confirms the screen is up.
      expect(
        tester.terminalState.findText('v0.').isNotEmpty,
        isTrue,
        reason: 'home hero should render the version label',
      );

      // esc returns to the chat interface.
      await tester.sendKeyEvent(KeyboardEvent(logicalKey: LogicalKey.escape));
      await tester.pump();
      expect(
        tester.terminalState.findText('paste').isNotEmpty,
        isTrue,
        reason: 'chat input returns after leaving home',
      );
    }, size: const Size(120, 32));

    deps.theme.dispose();
    deps.recents.dispose();
  });

  test('home does not open when showHomeOnLaunch is false', () async {
    final bootState = await loadChatPanelBootState(
      userProvidersDir: tempDir.path,
      providerService: providerService,
      store: store,
      projectPath: tempDir.path,
    );
    final deps = await createDependencies();

    await testNocterm('home screen suppressed', (tester) async {
      await tester.pumpComponent(
        Container(
          width: 120,
          height: 32,
          child: CruxTheme(
            data: deps.theme.activeTheme,
            child: ChatPanel(
              userProvidersDir: tempDir.path,
              themeController: deps.theme,
              bootState: bootState,
              recentProjectsStore: deps.recents,
              // showHomeOnLaunch defaults to false.
            ),
          ),
        ),
      );
      await tester.pump();
      // Without the launch flag the chat screen renders — its input
      // prompt is present and home's version hero is not.
      expect(
        tester.terminalState.findText('> ').isNotEmpty,
        isTrue,
        reason: 'chat input should render without the launch flag',
      );
      expect(
        tester.terminalState.findText('██████╗').isEmpty,
        isTrue,
        reason: 'home logo must not appear without the launch flag',
      );
    }, size: const Size(120, 32));

    deps.theme.dispose();
    deps.recents.dispose();
  });

  test('home settings button opens setup directly', () async {
    final bootState = await loadChatPanelBootState(
      userProvidersDir: tempDir.path,
      providerService: providerService,
      store: store,
      projectPath: tempDir.path,
    );
    final deps = await createDependencies();
    final locale = await LocaleController.create(
      configStore: LocaleConfigStore(
        File(p.join(tempDir.path, 'locale-config.toml')),
      ),
    );

    await testNocterm('home setup button routing', (tester) async {
      await tester.pumpComponent(
        Container(
          width: 120,
          height: 40,
          child: CruxTheme(
            data: deps.theme.activeTheme,
            child: ChatPanel(
              userProvidersDir: tempDir.path,
              themeController: deps.theme,
              localeController: locale,
              bootState: bootState,
              recentProjectsStore: deps.recents,
              showHomeOnLaunch: true,
              setupEnsureSemble: (progress) async => progress(1, 'ready'),
              setupEnsureRipgrep: (progress) async => progress(1, 'ready'),
            ),
          ),
        ),
      );
      await tester.pump();

      final setup = tester.terminalState.findText('setup').single;
      await tester.tap(setup.x, setup.y);
      await tester.pump(const Duration(milliseconds: 20));

      expect(tester.terminalState, containsText('CRUX  SETUP'));
    }, size: const Size(120, 40));

    locale.dispose();
    deps.theme.dispose();
    deps.recents.dispose();
  });

  test('first-run setup takes precedence over the home screen', () async {
    final bootState = await loadChatPanelBootState(
      userProvidersDir: tempDir.path,
      providerService: providerService,
      store: store,
      projectPath: tempDir.path,
    );
    final deps = await createDependencies();
    final locale = await LocaleController.create(
      configStore: LocaleConfigStore(
        File(p.join(tempDir.path, 'locale-config.toml')),
      ),
    );

    await testNocterm('setup launch routing', (tester) async {
      await tester.pumpComponent(
        Container(
          width: 120,
          height: 32,
          child: CruxTheme(
            data: deps.theme.activeTheme,
            child: ChatPanel(
              userProvidersDir: tempDir.path,
              themeController: deps.theme,
              localeController: locale,
              bootState: bootState,
              recentProjectsStore: deps.recents,
              showHomeOnLaunch: true,
              showSetupOnLaunch: true,
              setupEnsureSemble: (progress) async => progress(1, 'ready'),
              setupEnsureRipgrep: (progress) async => progress(1, 'ready'),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 20));

      expect(tester.terminalState, containsText('CRUX  SETUP'));
      expect(tester.terminalState.findText('v0.').isEmpty, isTrue);
    }, size: const Size(120, 32));

    locale.dispose();
    deps.theme.dispose();
    deps.recents.dispose();
  });
}
