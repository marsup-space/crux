// Tests for SessionController._resolveReasoningEffort — the
// fallback that reconciles a session's stored reasoning effort
// against the active model's preset list. Without this, switching
// to a model that filters its preset list (Kimi K3 hides everything
// but `[off, max]`) would leave the session's stored effort
// (`normal`, the historical default) untouched — the chip would
// render the unsupported value while the picker offered only the
// filtered subset, and the wire request would carry the
// unsupported value to the API (which 400s for Kimi).
import 'dart:io';

import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'package:crux/src/components/session_controller.dart';
import 'package:crux/src/services/chat_service.dart';
import 'package:crux/src/services/llm_client.dart';
import 'package:crux/src/services/provider_service.dart';
import 'package:crux/src/services/tool_executor.dart';
import 'package:crux/src/services/web_provider_registry.dart';
import 'package:crux/src/storage/storage.dart';
import 'package:crux/src/tools/file_read_tracker.dart';
import 'package:crux/src/tools/registry.dart';

void main() {
  late Directory originalCwd;
  late Directory tempDir;
  late CruxDatabase db;
  late ProviderService providerService;
  late SessionStore store;
  late SessionController controller;

  /// Set up a `kimi` provider matching the production TOML —
  /// K3 and K2.8 Preview expose the full `[off, low, high, max]`
  /// scale (`normal` is renamed to `high` on the wire because no
  /// middle tier exists). The default is `high` for K3 and `max`
  /// for K2.8 Preview.
  Future<void> installKimiProvider() async {
    await File('${tempDir.path}/kimi.toml').writeAsString('''
type = "kimi"
endpoint_url = "https://api.kimi.com/coding/v1"

[[models]]
id = "k3-1m"
name = "Kimi K3 (1M context)"
context_size = 1048576
reasoning_effort = "high"
thinking = true

[models.reasoning_labels]
normal = "high"

[[models]]
id = "kimi-for-coding"
name = "Kimi K2.8 Preview"
context_size = 1048576
reasoning_effort = "max"
thinking = true

[models.reasoning_labels]
normal = "high"
''');
    await providerService.reload();
  }

  /// Generic OpenAI-compatible provider with the standard
  /// five-level preset scale. Used as a "model with no
  /// filtering" baseline — the stored value is always in
  /// the preset list, so case 1 of the fallback is the
  /// expected hit.
  Future<void> installGenericProvider() async {
    await File('${tempDir.path}/generic.toml').writeAsString('''
type = "openai_compatible"
endpoint_url = "https://api.example.com/v1"

[[models]]
id = "default-model"
name = "Default"
context_size = 128000
reasoning_effort = "high"
''');
    await providerService.reload();
  }

  setUp(() async {
    originalCwd = Directory.current;
    tempDir = await Directory.systemTemp.createTemp('crux_resolve_effort_');
    Directory.current = tempDir;
    db = CruxDatabase.forTesting(NativeDatabase.memory());
    providerService = ProviderService(userProvidersDir: tempDir.path);
    store = SessionStore(db, instanceId: 'local');
    final toolRegistry = ToolRegistry()
      ..registerDefaults(
        FileReadTracker(),
        sessionStore: store,
        webProviderRegistry: WebProviderRegistry(),
      );
    controller = SessionController(
      store: store,
      providerService: providerService,
      chatService: ChatService(
        store,
        providerService,
        LlmClient(),
        ToolExecutor(toolRegistry),
      ),
      refresh: () {},
    );
  });

  tearDown(() async {
    await db.close();
    Directory.current = originalCwd;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  /// Each test creates a session, refreshes the in-memory
  /// session list (`controller.initSessions()`), and only
  /// then calls `controller.runtime(id)`. The runtime's
  /// `_resolveReasoningEffort` reads the model from
  /// `SessionController.sessions` (via `findSession`), so
  /// without init the lookup misses and the fallback never
  /// sees the model — every test would return null.
  /// Each test creates a session, refreshes the in-memory
  /// session list (`controller.initSessions()`), and only
  /// then calls `controller.runtime(id)`. The runtime's
  /// `_resolveReasoningEffort` reads the model from
  /// `SessionController.sessions` (via `findSession`), so
  /// without init the lookup misses and the fallback never
  /// sees the model — every test would return null.
  ///
  /// macOS quirk: `Directory.systemTemp.createTemp()` returns
  /// `/var/folders/...` but `Directory.current.path` resolves
  /// to `/private/var/folders/...` (the symlink target).
  /// `store.list(projectPath: ...)` does a string-equal
  /// match, so a session stored with the former won't be
  /// found when queried with the latter. We pass
  /// `Directory.current.path` (the canonical path) to both
  /// the create and the in-memory lookup, matching
  /// `initSessions`'s own `Directory.current.path` usage.
  Future<int> createAndLoad(String modelKey) async {
    final canonical = Directory.current.path;
    final session = await store.create(
      title: 't',
      model: modelKey,
      projectPath: canonical,
    );
    await controller.initSessions();
    return session.id;
  }

  test(
    'stored value in preset list passes through unchanged (case 1)',
    () async {
      await installGenericProvider();
      // Generic provider exposes the full five-level scale; the
      // stored "high" is in the list, so the runtime mirrors
      // it verbatim.
      final id = await createAndLoad('generic/default-model');
      final rt = controller.runtime(id);
      expect(
        rt.reasoningEffort,
        'high',
        reason: 'stored value supported by the model passes through',
      );
    },
  );

  test('Kimi K3: stored "normal" passes through unchanged (case 1 — '
      'K3 now exposes the full scale)', () async {
    await installKimiProvider();
    // K3 now accepts low / high / max on the wire, so the
    // full five-level Crux scale is in the preset list. A
    // stored "normal" is in the list and passes through as
    // case 1 — no fallback needed.
    final id = await createAndLoad('kimi/k3-1m');
    final session = controller.findSession(id)!;
    session.reasoningEffort = 'normal';
    await store.update(id, reasoningEffort: 'normal');
    final rt = controller.runtime(id);
    expect(
      rt.reasoningEffort,
      'normal',
      reason:
          'K3 now accepts the full five-level scale — "normal" '
          'is in the preset list and passes through unchanged',
    );
  });

  test('Kimi K2.8 Preview: stored "normal" remains supported', () async {
    await installKimiProvider();
    final id = await createAndLoad('kimi/kimi-for-coding');
    final session = controller.findSession(id)!;
    session.reasoningEffort = 'normal';
    await store.update(id, reasoningEffort: 'normal');
    final rt = controller.runtime(id);
    expect(rt.reasoningEffort, 'normal');
    final presets = providerService
        .llmProviderByName('kimi')!
        .reasoningPresetsFor(
          'kimi-for-coding',
          providerLabels: providerService
              .providerByName('kimi')!
              .reasoningLabels,
          modelLabels: providerService
              .providerByName('kimi')!
              .modelById('kimi-for-coding')!
              .reasoningLabels,
        );
    expect(presets.map((p) => p.internalValue).toList(), [
      'off',
      'low',
      'normal',
      'high',
      'max',
    ]);
    expect(presets.map((p) => p.displayLabel).toList(), [
      'off',
      'low',
      'high',
      'high',
      'max',
    ]);
  });

  test('stored value in preset list passes through even on Kimi (case 1, '
      'Kimi variant)', () async {
    await installKimiProvider();
    // Session was created on Kimi K3, so the stored effort
    // was already "high" (model's TOML default). After
    // loading, the runtime should keep "high" — no fallback
    // needed.
    final id = await createAndLoad('kimi/k3-1m');
    final rt = controller.runtime(id);
    expect(
      rt.reasoningEffort,
      'high',
      reason:
          'stored value already matches the model default — no fallback needed',
    );
  });

  test('model with no presets (reasoning_effort = "none") keeps the '
      'stored value as-is', () async {
    await File('${tempDir.path}/none.toml').writeAsString('''
type = "openai_compatible"
endpoint_url = "https://api.example.com/v1"

[[models]]
id = "no-thinking-model"
name = "No thinking"
context_size = 128000
reasoning_effort = "none"
''');
    await providerService.reload();
    final id = await createAndLoad('none/no-thinking-model');
    final session = controller.findSession(id)!;
    session.reasoningEffort = 'normal';
    await store.update(id, reasoningEffort: 'normal');
    final rt = controller.runtime(id);
    // The model exposes no presets; the stored value is kept
    // verbatim. The wire request is built from the
    // reasoningEffort argument, which the chat_turn_executor
    // passes through regardless of the preset list — the
    // provider's buildRequestBody is what finally maps
    // (or ignores) it.
    expect(rt.reasoningEffort, 'normal');
  });
}
