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
    tempDir = await Directory.systemTemp.createTemp('crux_boot_state_');
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

  test('loads selected session state before ChatPanel mounts', () async {
    final bootState = await loadChatPanelBootState(
      userProvidersDir: tempDir.path,
      providerService: providerService,
      store: store,
      projectPath: tempDir.path,
    );

    expect(bootState.providerService, same(providerService));
    expect(bootState.store, same(store));
    expect(bootState.sessions, isNotEmpty);
    expect(bootState.currentSessionId, bootState.sessions.first.id);
    expect(bootState.messageCache, contains(bootState.currentSessionId));
    expect(bootState.messageCache[bootState.currentSessionId], isEmpty);
    expect(bootState.currentFileReadState, isEmpty);
    expect(bootState.sessions.first.projectPath, tempDir.path);
  });

  test('chooses an existing idle session and preloads its messages', () async {
    final existing = await store.create(
      title: 'Existing',
      model: 'local/test',
      projectPath: tempDir.path,
    );
    await store.messageStore.addMessage(
      existing.id,
      role: 'user',
      content: 'hello',
    );
    await store.saveFileReadState(existing.id, '/tmp/read.dart', 123);

    final bootState = await loadChatPanelBootState(
      userProvidersDir: tempDir.path,
      providerService: providerService,
      store: store,
      projectPath: tempDir.path,
    );

    expect(bootState.currentSessionId, existing.id);
    expect(bootState.sessions.single.id, existing.id);
    expect(bootState.messageCache[existing.id], hasLength(1));
    expect(bootState.messageCache[existing.id]!.single.content, 'hello');
    expect(bootState.currentFileReadState, {'/tmp/read.dart': 123});
    // messagesTotal must equal the seeded count (1). The chat panel
    // reads this to decide whether to kick off the chunked loader
    // for the remaining messages — with only one row, the count
    // equals what we already loaded, so no background fill needed.
    expect(bootState.messagesTotal, 1);
  });

  test('boot loads only the first chunk and reports the total for '
      'partial sessions', () async {
    // The boot loader fetches the latest 50 messages (or fewer if
    // the session is smaller) and surfaces `messagesTotal` so the
    // chat panel can resume chunked loading for the rest. This is
    // what makes cold-start on a 1000-message session feel as fast
    // as cold-start on a 50-message session — the splash screen
    // clears once the first chunk is in.
    final existing = await store.create(
      title: 'Big',
      model: 'local/test',
      projectPath: tempDir.path,
    );
    for (var i = 0; i < 120; i++) {
      await store.messageStore.addMessage(
        existing.id,
        role: 'user',
        content: 'message #$i',
      );
    }

    final bootState = await loadChatPanelBootState(
      userProvidersDir: tempDir.path,
      providerService: providerService,
      store: store,
      projectPath: tempDir.path,
    );

    expect(
      bootState.messageCache[existing.id],
      hasLength(50),
      reason:
          'boot should pre-load only the first chunk (50), '
          'not the full session — the rest fills in via the '
          'background chunked loader kicked off by ChatPanel',
    );
    expect(
      bootState.messageCache[existing.id]!.first.content,
      'message #70',
      reason:
          'first chunk is the latest 50 messages — the tail '
          'of the persisted list',
    );
    expect(
      bootState.messageCache[existing.id]!.last.content,
      'message #119',
      reason:
          'first chunk ends with the most recently persisted '
          'message, so the user sees the bottom of their latest '
          'conversation immediately on first paint',
    );
    expect(
      bootState.messagesTotal,
      120,
      reason:
          'messagesTotal must reflect the FULL session count '
          'so ChatPanel can compute "70 more messages to load" '
          'and kick off the chunked loader to fill them in',
    );
  });

  test('mounts ChatPanel with preloaded boot state', () async {
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
    final recentProjectsStore = RecentProjectsStore.forTesting(
      p.join(tempDir.path, 'recent_projects.json'),
    );

    await testNocterm('chat panel boot state first paint', (tester) async {
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
              recentProjectsStore: recentProjectsStore,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(tester.terminalState.getText().trim(), isNotEmpty);
    }, size: const Size(120, 32));

    themeController.dispose();
    recentProjectsStore.dispose();
  });
}
