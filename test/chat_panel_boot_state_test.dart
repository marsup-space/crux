import 'dart:io';

import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'package:crux/src/components/chat_panel.dart';
import 'package:crux/src/services/provider_service.dart';
import 'package:crux/src/storage/storage.dart';

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
  });
}
