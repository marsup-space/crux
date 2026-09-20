import 'dart:io';

import 'package:crux/src/models/coding_plan_usage.dart';
import 'package:crux/src/models/provider_config.dart';
import 'package:crux/src/models/subagent.dart';
import 'package:crux/src/services/llm_provider.dart';
import 'package:crux/src/services/provider_service.dart';
import 'package:crux/src/services/providers/anthropic_compatible_provider.dart';
import 'package:crux/src/services/providers/coding_plan_provider.dart';
import 'package:crux/src/services/subagent/subagent_manager.dart';
import 'package:crux/src/storage/agent_store.dart';
import 'package:crux/src/storage/database.dart';
import 'package:crux/src/tools/registry.dart';
import 'package:crux/src/services/tool_executor.dart';
import 'package:drift/native.dart';
import 'package:test/test.dart';

/// Test-only coding-plan provider with a controllable snapshot. The
/// manager's budget probe reads `latestCodingPlanUsage` synchronously.
class _FakeCodingPlanProvider extends AnthropicCompatibleProvider
    with CodingPlanProvider {
  _FakeCodingPlanProvider({this.snapshot});

  /// The snapshot the probe observes. Null = "no data yet".
  CodingPlanUsage? snapshot;

  /// When set, [startCodingPlanPolling] simulates a live fetch that
  /// lands this snapshot after a microtask (the probe-then-wait path).
  CodingPlanUsage? snapshotAfterProbe;

  var pollStarts = 0;

  @override
  String get name => 'codex';

  /// The probe reads this getter; the mixin bases it on a private field
  /// written only by a successful tick. Override so the test controls the
  /// observed snapshot directly.
  @override
  CodingPlanUsage? get latestCodingPlanUsage => snapshot;

  @override
  void startCodingPlanPolling({
    required String apiKey,
    Duration? interval,
    String? baseUrl,
  }) {
    pollStarts++;
    final pending = snapshotAfterProbe;
    if (pending != null) {
      // Simulate the async first tick delivering a snapshot.
      Future<void>.microtask(() => snapshot = pending);
    }
  }

  @override
  Future<CodingPlanUsage> getCodingPlanUsage() async =>
      snapshot ??
      (throw const CodingPlanUsageError(
        CodingPlanUsageErrorKind.network,
        'no snapshot',
      ));
}

/// A [ProviderService] stub that returns a fixed [LlmProvider] (carrying
/// the coding-plan mixin) for the provider name under test, so the
/// manager's `is CodingPlanProvider` branch actually engages.
class _CodingPlanProviderService extends ProviderService {
  _CodingPlanProviderService({
    required super.userProvidersDir,
    required this.providerName,
    required this.llmProvider,
    this.hasKey = true,
  });

  final String providerName;
  final LlmProvider llmProvider;
  final bool hasKey;

  @override
  String? getApiKey(String name) =>
      (name == providerName && hasKey) ? 'sk-test' : null;

  @override
  LlmProvider? llmProviderByName(String name) =>
      name == providerName ? llmProvider : null;

  @override
  ProviderConfig? providerByName(String name) => null; // force null usageCfg
}

class _TogglesOn implements SubagentControllerLike {
  const _TogglesOn();
  @override
  bool get workersOn => true;
  @override
  bool get expertsOn => true;
  @override
  bool get anyOn => true;
  @override
  int? get roundLimit => 40;
  @override
  SubagentModelConfig poolFor(SubagentRole role) =>
      const SubagentConfig().forRole(role);
}

SubagentManager _manager(
  AgentStore store,
  ProviderService providers,
  Directory tmpDir,
) => SubagentManager(
  store: store,
  providerService: providers,
  toolExecutor: ToolExecutor(ToolRegistry()),
  toolRegistry: ToolRegistry(),
  toggles: const _TogglesOn(),
  workingDirectory: tmpDir.path,
  // Tests must not wait out the production 12s probe window.
  budgetProbeTimeout: const Duration(milliseconds: 300),
);

void main() {
  late Directory tmpDir;
  late CruxDatabase db;
  late AgentStore store;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('subagent_budget_');
    db = CruxDatabase.forTesting(NativeDatabase.memory());
    store = AgentStore(db);
  });

  tearDown(() async {
    await db.close();
    await tmpDir.delete(recursive: true);
  });

  group('remainingBudget (CodingPlan branch now reachable)', () {
    test('existing weekly-0 snapshot → exhausted, no re-poll', () async {
      final cp = _FakeCodingPlanProvider(
        snapshot: CodingPlanUsage(
          providerName: 'codex',
          modelName: 'general',
          intervalRemainingPct: 0,
          weeklyRemainingPct: 0,
          fetchedAt: DateTime.now(),
          hasIntervalWindow: false,
        ),
      );
      final manager = _manager(
        store,
        _CodingPlanProviderService(
          userProvidersDir: tmpDir.path,
          providerName: 'codex',
          llmProvider: cp,
        ),
        tmpDir,
      );
      expect(
        await manager.remainingBudget('codex/gpt-5.6-terra'),
        BudgetLevel.exhausted,
      );
      expect(cp.pollStarts, 0); // already had data → no probe
    });

    test(
      'empty 5h window + exhausted weekly → exhausted (worst-window)',
      () async {
        // Regression for the live Codex failure: the 5h window is empty
        // (100% remaining) but the weekly window is fully burned (0%,
        // allowed:false). Reading ONLY the interval window reports ample and
        // hires terra into a rate-limited wall. The probe must judge by the
        // worst real window.
        final cp = _FakeCodingPlanProvider(
          snapshot: CodingPlanUsage(
            providerName: 'codex',
            modelName: 'general',
            intervalRemainingPct: 100, // 5h window empty
            weeklyRemainingPct: 0, // 1w window exhausted
            fetchedAt: DateTime.now(),
            hasIntervalWindow: true,
            hasWeeklyWindow: true,
          ),
        );
        final manager = _manager(
          store,
          _CodingPlanProviderService(
            userProvidersDir: tmpDir.path,
            providerName: 'codex',
            llmProvider: cp,
          ),
          tmpDir,
        );
        expect(
          await manager.remainingBudget('codex/gpt-5.6-terra'),
          BudgetLevel.exhausted,
        );
      },
    );

    test('ample 5h + tight weekly → tight (worst-window)', () async {
      final cp = _FakeCodingPlanProvider(
        snapshot: CodingPlanUsage(
          providerName: 'codex',
          modelName: 'general',
          intervalRemainingPct: 80,
          weeklyRemainingPct: 5,
          fetchedAt: DateTime.now(),
          hasIntervalWindow: true,
          hasWeeklyWindow: true,
        ),
      );
      final manager = _manager(
        store,
        _CodingPlanProviderService(
          userProvidersDir: tmpDir.path,
          providerName: 'codex',
          llmProvider: cp,
        ),
        tmpDir,
      );
      expect(
        await manager.remainingBudget('codex/gpt-5.6-terra'),
        BudgetLevel.tight,
      );
    });

    test('weekly pct 5 → tight', () async {
      final cp = _FakeCodingPlanProvider(
        snapshot: CodingPlanUsage(
          providerName: 'codex',
          modelName: 'general',
          intervalRemainingPct: 5,
          weeklyRemainingPct: 5,
          fetchedAt: DateTime.now(),
        ),
      );
      final manager = _manager(
        store,
        _CodingPlanProviderService(
          userProvidersDir: tmpDir.path,
          providerName: 'codex',
          llmProvider: cp,
        ),
        tmpDir,
      );
      expect(
        await manager.remainingBudget('codex/gpt-5.6-terra'),
        BudgetLevel.tight,
      );
    });

    test('null snapshot → probes once, lands data → exhausted', () async {
      // Regression: codex bound but its polling never ran → snapshot null
      // → the OLD code returned ample on missing data and picked the
      // exhausted terra model. The probe must trigger a live fetch and
      // observe the landing snapshot.
      final cp = _FakeCodingPlanProvider(snapshot: null)
        ..snapshotAfterProbe = CodingPlanUsage(
          providerName: 'codex',
          modelName: 'general',
          intervalRemainingPct: 0,
          weeklyRemainingPct: 0,
          fetchedAt: DateTime.now(),
        );
      final manager = _manager(
        store,
        _CodingPlanProviderService(
          userProvidersDir: tmpDir.path,
          providerName: 'codex',
          llmProvider: cp,
        ),
        tmpDir,
      );
      expect(cp.pollStarts, 0);
      final level = await manager.remainingBudget('codex/gpt-5.6-terra');
      expect(cp.pollStarts, greaterThan(0)); // probed
      expect(level, BudgetLevel.exhausted); // landed data wins
    });

    test(
      'null snapshot, fetch yields nothing → ample (never blocks)',
      () async {
        final cp = _FakeCodingPlanProvider(snapshot: null); // stays null
        final manager = _manager(
          store,
          _CodingPlanProviderService(
            userProvidersDir: tmpDir.path,
            providerName: 'codex',
            llmProvider: cp,
          ),
          tmpDir,
        );
        final level = await manager.remainingBudget('codex/gpt-5.6-terra');
        expect(cp.pollStarts, greaterThan(0)); // still probed
        expect(level, BudgetLevel.ample); // fail-open
      },
    );

    test('no API key → cannot probe → ample (fail-open)', () async {
      final cp = _FakeCodingPlanProvider(snapshot: null);
      final manager = _manager(
        store,
        _CodingPlanProviderService(
          userProvidersDir: tmpDir.path,
          providerName: 'codex',
          llmProvider: cp,
          hasKey: false,
        ),
        tmpDir,
      );
      // No key configured → probe can't start → fail-open.
      expect(
        await manager.remainingBudget('codex/gpt-5.6-terra'),
        BudgetLevel.ample,
      );
      expect(cp.pollStarts, 0);
    });
  });

  group('ProviderService.llmProviderByName instance sharing', () {
    // Regression for the field bug: the budget probe and PollingCoordinator
    // used to resolve SEPARATE CodexProvider instances (resolveProvider
    // returns a fresh object each call), so the poll wrote the snapshot to
    // one instance while the probe read an empty one — an exhausted plan
    // (codex 1w = 100%, allowed:false) was hired anyway.
    test('same provider name resolves to the SAME cached instance', () async {
      final dir = await Directory.systemTemp.createTemp('psvc_cache_');
      addTearDown(() => dir.delete(recursive: true));
      // A minimal codex provider TOML so the loader registers it.
      File('${dir.path}/codex.toml').writeAsStringSync('''
type = "codex"
endpoint_url = "https://chatgpt.com/backend-api/codex"

[[models]]
id = "gpt-5.6-terra"
name = "terra"
context_size = 256000
''');
      final service = ProviderService(userProvidersDir: dir.path);
      await service.initialize();

      final a = service.llmProviderByName('codex');
      final b = service.llmProviderByName('codex');
      expect(a, isNotNull);
      expect(
        identical(a, b),
        isTrue,
        reason: 'the budget probe and the poller must share one instance',
      );
      expect(a, isA<CodingPlanProvider>());
    });

    test('reload clears the cache and re-resolves', () async {
      final dir = await Directory.systemTemp.createTemp('psvc_reload_');
      addTearDown(() => dir.delete(recursive: true));
      File('${dir.path}/codex.toml').writeAsStringSync('''
type = "codex"
endpoint_url = "https://chatgpt.com/backend-api/codex"

[[models]]
id = "gpt-5.6-terra"
name = "terra"
context_size = 256000
''');
      final service = ProviderService(userProvidersDir: dir.path);
      await service.initialize();
      final before = service.llmProviderByName('codex');
      await service.reload();
      final after = service.llmProviderByName('codex');
      expect(
        identical(before, after),
        isFalse,
        reason: 'reload must drop the stale instance',
      );
    });
  });
}
