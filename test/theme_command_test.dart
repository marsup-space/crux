import 'dart:io';

import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:crux/src/commands/command_executor.dart';
import 'package:crux/src/components/ui/toast.dart';
import 'package:crux/src/models/session_runtime_state.dart';
import 'package:crux/src/services/provider_service.dart';
import 'package:crux/src/services/web_provider_registry.dart';
import 'package:crux/src/storage/storage.dart';
import 'package:crux/src/theme/theme_config_store.dart';
import 'package:crux/src/theme/theme_controller.dart';
import 'package:crux/src/theme/theme_loader.dart';

void main() {
  test('/theme reports, rejects unknown IDs, switches, and persists', () async {
    final directory = await Directory.systemTemp.createTemp(
      'crux_theme_command_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    final registry = await ThemeLoader(
      bundledDirectory: Directory(p.join(Directory.current.path, 'themes')),
      userDirectory: Directory(p.join(directory.path, 'themes')),
    ).load();
    final configStore = ThemeConfigStore(
      File(p.join(directory.path, 'config.toml')),
    );
    final controller = await ThemeController.create(
      registry: registry,
      configStore: configStore,
    );
    final providerService = ProviderService(
      userProvidersDir: p.join(directory.path, 'providers'),
    );
    final database = CruxDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final store = SessionStore(database);
    final session = await store.create(
      title: 'Theme Test',
      model: '',
      projectPath: directory.path,
    );
    final runtime = SessionRuntimeState(sessionId: session.id);
    final toasts = <(String, ToastMode?)>[];

    final context = CommandContext(
      store: store,
      providerService: providerService,
      providerServiceReady: false,
      webProviderRegistry: WebProviderRegistry(),
      currentSession: session,
      currentSessionId: session.id,
      sessions: [session],
      currentMessages: const [],
      projectPath: directory.path,
      refresh: () {},
      showToast: (message, {ToastMode? mode}) => toasts.add((message, mode)),
      switchSession: (_) async {},
      initSessions: () async {},
      createNewSession: () async {},
      runtime: (_) => runtime,
      persistThinkingLevel: (_) {},
      persistChatDisplayMode: (_) {},
      persistTemperature: (_) async {},
      resolveAuxiliaryModel: () {},
      themeController: controller,
      sendTurn: ({text}) async {},
      findLastUserMessage: () async => null,
      deleteMessagesFrom: (_) async {},
      sendBtwTurn: (_) async {},
      clearBtwTurns: (_) {},
    );

    final executor = CommandExecutor();
    await executor.execute('/theme', context);
    expect(toasts.last.$1, contains('Current theme: dracula'));

    await executor.execute('/theme nope', context);
    expect(toasts.last.$1, contains('Available:'));
    expect(toasts.last.$2, ToastMode.error);

    await executor.execute('/theme github', context);
    expect(controller.activeId, 'github');
    expect(await configStore.readThemeId(), 'github');
    expect(toasts.last.$2, ToastMode.status);
  });
}
