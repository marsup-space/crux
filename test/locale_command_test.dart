import 'dart:io';

import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:crux/src/commands/command_executor.dart';
import 'package:crux/src/components/ui/toast.dart';
import 'package:crux/src/i18n/locale_config_store.dart';
import 'package:crux/src/i18n/locale_controller.dart';
import 'package:crux/src/models/session_runtime_state.dart';
import 'package:crux/src/services/provider_service.dart';
import 'package:crux/src/services/web_provider_registry.dart';
import 'package:crux/src/storage/storage.dart';

void main() {
  test(
    '/language reports, rejects unknown codes, switches, and persists',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'crux_language_command_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });

      final configStore = LocaleConfigStore(
        File(p.join(directory.path, 'config.toml')),
      );
      final controller = await LocaleController.create(
        configStore: configStore,
      );
      final providerService = ProviderService(
        userProvidersDir: p.join(directory.path, 'providers'),
      );
      final database = CruxDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final store = SessionStore(database);
      final session = await store.create(
        title: 'Language Test',
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
        localeController: controller,
        sendTurn: ({text}) async {},
        findLastUserMessage: () async => null,
        deleteMessagesFrom: (_) async {},
        sendBtwTurn: (_) async {},
        clearBtwTurns: (_) {},
      );

      final executor = CommandExecutor();
      await executor.execute('/language', context);
      expect(toasts.last.$1, contains('Current language: English'));

      await executor.execute('/language nope', context);
      expect(toasts.last.$1, contains('Unknown language "nope"'));
      expect(toasts.last.$1, contains('Available:'));
      expect(toasts.last.$2, ToastMode.error);

      await executor.execute('/language zh', context);
      expect(controller.activeCode, 'zh');
      expect(await configStore.readLocale(), 'zh');
      expect(toasts.last.$1, contains('语言已切换为'));
      expect(toasts.last.$2, ToastMode.status);
    },
  );

  test(
    '/reply-language reports, rejects unknown codes, switches, and persists',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'crux_replylang_command_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });

      final configStore = LocaleConfigStore(
        File(p.join(directory.path, 'config.toml')),
      );
      final controller = await LocaleController.create(
        configStore: configStore,
      );
      final providerService = ProviderService(
        userProvidersDir: p.join(directory.path, 'providers'),
      );
      final database = CruxDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final store = SessionStore(database);
      final session = await store.create(
        title: 'Reply Language Test',
        model: '',
        projectPath: directory.path,
      );
      final runtime = SessionRuntimeState(sessionId: session.id);
      final toasts = <(String, ToastMode?)>[];
      final rebuilt = <int>[];

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
        localeController: controller,
        rebuildSystemPrompt: (sid) async => rebuilt.add(sid),
        sendTurn: ({text}) async {},
        findLastUserMessage: () async => null,
        deleteMessagesFrom: (_) async {},
        sendBtwTurn: (_) async {},
        clearBtwTurns: (_) {},
      );

      final executor = CommandExecutor();
      await executor.execute('/reply-language', context);
      expect(
        toasts.last.$1,
        contains('Current reply language: Follow language'),
      );

      await executor.execute('/reply-language nope', context);
      expect(toasts.last.$1, contains('Unknown reply language "nope"'));
      expect(toasts.last.$1, contains('Available:'));
      expect(toasts.last.$2, ToastMode.error);

      await executor.execute('/reply-language auto', context);
      expect(controller.replyLanguageCode, 'auto');
      expect(await configStore.readReplyLanguage(), 'auto');
      expect(toasts.last.$1, contains('Reply language switched to Auto'));
      expect(toasts.last.$2, ToastMode.status);
      // Switching the policy rebuilds the current session's prompt.
      expect(rebuilt, [session.id]);
    },
  );
}
