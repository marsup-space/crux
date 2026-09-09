// Verifies that opening a fullpane from the home screen (the `my notes`
// box's `open` button) stacks the fullpane ON TOP of home — the home
// early-return in ChatPanel.build used to swallow showFullpane entirely.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:crux/src/components/chat_panel.dart';
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
    tempDir = await Directory.systemTemp.createTemp('crux_home_notes_');
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

  test('notes fullpane opens on top of home and esc returns to home', () async {
    final bootState = await loadChatPanelBootState(
      userProvidersDir: tempDir.path,
      providerService: providerService,
      store: store,
      projectPath: tempDir.path,
    );
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

    await testNocterm('home notes fullpane', (tester) async {
      await tester.pumpComponent(
        Container(
          width: 120,
          height: 32,
          child: CruxTheme(
            data: themeController.activeTheme,
            child: ChatPanel(
              userProvidersDir: tempDir.path,
              themeController: themeController,
              bootState: bootState,
              recentProjectsStore: recents,
              showHomeOnLaunch: true,
            ),
          ),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      for (var i = 0; i < 3; i++) {
        await tester.pump();
      }

      // Home is showing (the dashboard legend).
      expect(tester.terminalState.containsText('esc chat'), isTrue);

      // Tab a few times so home auto-scrolls the notes box into view
      // (focus follows the tab order; the notes box title then renders).
      var notesVisible = false;
      for (var i = 0; i < 8 && !notesVisible; i++) {
        await tester.sendKeyEvent(KeyboardEvent(logicalKey: LogicalKey.tab));
        await tester.pump();
        notesVisible = tester.terminalState.containsText('my notes');
      }
      expect(notesVisible, isTrue, reason: 'notes box scrolled into view');

      // Click the `open` button inside the visible notes box.
      final open = tester.terminalState.findText('open').first;
      await tester.hover(open.x + 1, open.y);
      await tester.pump();
      await tester.tap(open.x + 1, open.y);
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }

      // The fullpane (title bar with close button) is now on top of home.
      expect(
        tester.terminalState.containsText('✕ close'),
        isTrue,
        reason: 'fullpane opened over home',
      );

      // Esc closes the fullpane, returning to the dashboard.
      await tester.sendKeyEvent(KeyboardEvent(logicalKey: LogicalKey.escape));
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
      expect(tester.terminalState.containsText('✕ close'), isFalse);
      expect(
        tester.terminalState.containsText('esc chat'),
        isTrue,
        reason: 'esc returns to home, not chat',
      );
    });
  });
}
