import 'dart:async';

import '../../models/coding_plan_usage.dart';
import '../../models/subagent.dart';
import '../../storage/agent_store.dart';
import '../../storage/database.dart' as db;
import '../../tools/registry.dart';
import '../../tools/tool_def.dart';
import '../providers/coding_plan_provider.dart';
import '../providers/credit_balance_provider.dart';
import '../provider_service.dart';
import '../tool_executor.dart';
import 'subagent_prompts.dart';
import 'subagent_runner.dart';

/// Normalized budget verdict for one model (see plan §模型分配).
enum BudgetLevel { ample, tight, exhausted }

/// The in-process subagent orchestrator: owns every live run, the
/// per-model concurrency accounting, dispatch semantics (send / hire /
/// fork / queue / cancel), and the report-envelope callback into the
/// main session.
///
/// The main agent is NEVER blocked: `send` / `hire` schedule the run
/// and return immediately; the report arrives later through
/// [onReportEnvelope]. Runs live only here — nothing about them is
/// persisted, so a restart leaves every roster row `ready` (the store
/// self-heals via [AgentStore.resetAllToReady]).
class SubagentManager {
  final AgentStore store;
  final ProviderService providerService;
  final ToolExecutor toolExecutor;
  final ToolRegistry toolRegistry;
  final SubagentControllerLike toggles;

  /// Called with the formatted report envelope when a run ends. The
  /// host injects it into the main session as a system-note event.
  final void Function(String envelope, db.Agent agent, String status)?
  onReportEnvelope;

  /// Called whenever a run's live status changes (chip refresh).
  final void Function()? onRunsChanged;

  final Map<String, SubagentRunner> _runs = {};
  final Map<String, List<_QueuedDispatch>> _queues = {};
  final String workingDirectory;
  final String userLanguage;

  /// The workspace scope for every roster operation (v37): hires,
  /// lookups, name allocation and status flips all filter on this.
  /// Equals [workingDirectory] — the process workspace root, which is
  /// also where the runs execute. One manager serves one workspace,
  /// so the in-memory `_runs` / `_queues` maps stay name-keyed; the
  /// cross-workspace uniqueness lives in the store's composite
  /// `(project_path, name)` key.
  String get projectPath => workingDirectory;

  /// Upper bound for the one-shot coding-plan probe when no snapshot exists
  /// yet. Must exceed the slowest provider's usage-endpoint timeout (Codex's
  /// legacy `/wham/usage` allows 10s — see `codex_provider.dart`), otherwise
  /// an exhausted plan that simply answers slowly is misread as "ample on
  /// missing data" and the exhausted model gets hired. 12s covers that with
  /// headroom; tests inject a shorter window.
  final Duration budgetProbeTimeout;

  SubagentManager({
    required this.store,
    required this.providerService,
    required this.toolExecutor,
    required this.toolRegistry,
    required this.toggles,
    required this.workingDirectory,
    this.onReportEnvelope,
    this.onRunsChanged,
    this.userLanguage = 'English',
    this.budgetProbeTimeout = const Duration(seconds: 12),
  });

  /// Live runs (for find_agents / chips / check_agent).
  Map<String, SubagentRunner> get runs => Map.unmodifiable(_runs);

  bool isBusy(String agentName) => _runs.containsKey(agentName);

  /// `remainingBudget(model)`: the plan's unified budget probe.
  ///
  /// The coding-plan snapshot lives on the [LlmProvider] mixin, not the
  /// [ProviderConfig] — so resolve through `llmProviderByName` (a
  /// `providerByName` result is never a [CodingPlanProvider]; that latent
  /// mismatch made this branch dead and let an exhausted model through).
  ///
  /// When the provider is a coding-plan source but has no snapshot yet
  /// (polling never started — e.g. the user drives a different model), the
  /// probe STARTS a live fetch and waits briefly for the first snapshot so
  /// an exhausted weekly window actually blocks the hire instead of being
  /// read as "ample on missing data". A provider with no API key can't be
  /// probed — fail open. A fetch that stays empty still reports
  /// [BudgetLevel.ample]: the probe never blocks dispatch on missing data.
  Future<BudgetLevel> remainingBudget(String model) async {
    final providerName = _providerNameForModel(model);
    if (providerName == null) return BudgetLevel.ample;
    final llm = providerService.llmProviderByName(providerName);
    if (llm is CodingPlanProvider) {
      var usage = llm.latestCodingPlanUsage;
      if (usage == null) {
        // No snapshot yet — kick a live fetch and wait for the first tick
        // (bounded) so the verdict reflects real quota, not a blind ample.
        final key = providerService.getApiKey(providerName);
        if (key != null && key.isNotEmpty) {
          usage = await _probeCodingPlanOnce(llm, providerName, key);
        }
      }
      if (usage == null) return BudgetLevel.ample;
      // Judge by the WORST real window, not just the 5h one: a provider can
      // have an empty 5h window yet a fully-exhausted weekly window (Codex
      // with a burned 7-day quota: 5h=100% free, 1w=0%, allowed:false).
      // Reading only `intervalRemainingPct` there reports the model as ample
      // and hires it straight into a rate-limited wall. Take the minimum
      // across whichever windows the snapshot actually carries.
      var pct = 100;
      var sawWindow = false;
      if (usage.hasIntervalWindow) {
        pct = usage.intervalRemainingPct;
        sawWindow = true;
      }
      if (usage.hasWeeklyWindow) {
        pct = sawWindow && pct < usage.weeklyRemainingPct
            ? pct
            : usage.weeklyRemainingPct;
        sawWindow = true;
      }
      if (!sawWindow) return BudgetLevel.ample;
      if (pct <= 0) return BudgetLevel.exhausted;
      if (pct <= 10) return BudgetLevel.tight;
      return BudgetLevel.ample;
    }
    if (llm is CreditBalanceProvider) {
      final balance = llm.latestCreditBalance;
      if (balance == null) return BudgetLevel.ample;
      if (!balance.isAvailable) return BudgetLevel.exhausted;
      return BudgetLevel.ample;
    }
    return BudgetLevel.ample;
  }

  /// Start a one-shot coding-plan poll and wait (bounded) for the first
  /// snapshot. Returns the snapshot, or null when the fetch yielded nothing
  /// within the window (the caller then fails open).
  Future<CodingPlanUsage?> _probeCodingPlanOnce(
    CodingPlanProvider provider,
    String providerName,
    String apiKey,
  ) async {
    provider.startCodingPlanPolling(
      apiKey: apiKey,
      baseUrl: providerService.providerByName(providerName)?.endpointUrl,
    );
    final deadline = budgetProbeTimeout;
    final sw = Stopwatch()..start();
    while (sw.elapsed < deadline) {
      final usage = provider.latestCodingPlanUsage;
      if (usage != null) return usage;
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    return provider.latestCodingPlanUsage;
  }

  // ── Dispatch entry points ────────────────────────────────────

  /// send_agent semantics: ready → message becomes the task and the
  /// run starts; busy → queue (default) or fork per [ifBusy].
  Future<String> send({
    required String agentName,
    required String intention,
    required String message,
    String ifBusy = 'queue',
    required int sessionId,
  }) async {
    final profile = await _profileOrError(agentName);
    if (profile == null) {
      return 'Unknown agent "$agentName". Call find_agents first.';
    }
    if (isBusy(agentName)) {
      if (ifBusy == 'fork') {
        return forkThenDispatch(
          source: profile,
          intention: intention,
          message: message,
          sessionId: sessionId,
        );
      }
      _queues
          .putIfAbsent(agentName, () => [])
          .add(_QueuedDispatch(intention: intention, message: message));
      return 'agent://$agentName is busy — message queued (position '
          '${_queues[agentName]!.length}). It will be delivered when the '
          'current run ends.';
    }
    await _startRun(profile, intention, message, sessionId);
    // The agent's model is bound for life (plan §模型分配: "绑定死"), so we
    // never swap it on send. But if that bound model's budget has since run
    // out, warn the dispatcher so it can fork to a live model instead of
    // dispatching into a guaranteed quota failure.
    final boundBudget = await remainingBudget(profile.model);
    final budgetNote = boundBudget == BudgetLevel.exhausted
        ? ' WARNING: the bound model ${profile.model} is out of budget — '
              'this run will likely fail. send_agent with ifBusy: "fork" to '
              'redispatch on a live pool model.'
        : '';
    return 'Dispatched agent://$agentName (intention: $intention). It runs '
        'in the background and will report back when done.$budgetNote';
  }

  /// hire_agent semantics: create the roster row (model resolved
  /// through the role pool) and immediately run the first task.
  Future<String> hire({
    required SubagentRole role,
    required String domain,
    required String intention,
    required String message,
    required int sessionId,
  }) async {
    if (!toggles.anyOn) {
      return 'Subagent mode is off — enable it with /subagent first.';
    }
    final model = await _pickModelForHire(role);
    if (model == null) {
      return 'No model available for ${role.name}s: the '
          '[subagent.${role.name}s] pool is empty or every model is '
          'saturated / out of budget. Configure it in config.toml.';
    }
    final profile = await store.hire(
      projectPath: projectPath,
      role: role,
      model: model,
      domain: domain,
      createdBySessionId: sessionId,
    );
    await _startRun(profile, intention, message, sessionId);
    return 'Hired agent://${profile.name} (${role.name}, $domain, $model) '
        'and dispatched the first task (intention: $intention).';
  }

  /// fork path: copy the source profile under a fresh pool name,
  /// preferring the source model, and dispatch immediately.
  Future<String> forkThenDispatch({
    required db.Agent source,
    required String intention,
    required String message,
    required int sessionId,
  }) async {
    final role = _roleOf(source);
    var model = source.model;
    if (await remainingBudget(model) == BudgetLevel.exhausted ||
        !_hasCapacity(model)) {
      model = await _pickModelForHire(role, excludingCurrent: false) ?? model;
    }
    final forked = await store.hire(
      projectPath: projectPath,
      role: role,
      model: model,
      domain: source.domain,
      createdBySessionId: sessionId,
    );
    if (source.knowledge.isNotEmpty || source.worklog.isNotEmpty) {
      await store.writeDistilled(
        projectPath: projectPath,
        name: forked.name,
        knowledge: source.knowledge,
        worklog: source.worklog,
      );
    }
    final fresh = (await store.byName(projectPath, forked.name))!;
    await _startRun(fresh, intention, message, sessionId);
    return 'agent://${source.name} was busy — forked to agent://${forked.name} '
        '(same domain knowledge, model $model) and dispatched the task.';
  }

  /// cancel_agent: interrupt the live run, drop queued messages,
  /// status back to ready. Reason lands in the report.
  Future<String> cancel(String agentName, {String? reason}) async {
    final runner = _runs.remove(agentName);
    if (runner == null) {
      _queues.remove(agentName);
      return 'agent://$agentName had no live run (queue cleared if any).';
    }
    runner.cancel();
    _queues.remove(agentName);
    await store.markReady(projectPath, agentName);
    onRunsChanged?.call();
    return 'Cancelled agent://$agentName'
        '${reason == null ? '' : ' (reason: $reason)'}. '
        'Roster profile kept; status is ready.';
  }

  /// check_agent: live snapshot for busy agents; roster summary for
  /// ready ones (no LLM call).
  Future<String> check(String agentName) async {
    final runner = _runs[agentName];
    if (runner != null) {
      final s = runner.snapshot();
      return 'agent://$agentName — ${s.status} at round ${s.round}'
          '${s.lastTool == null ? '' : ', last tool: ${s.lastTool}'}';
    }
    final profile = await store.byName(projectPath, agentName);
    if (profile == null) return 'Unknown agent "$agentName".';
    return 'agent://$agentName — ready. Domain: ${profile.domain}, '
        'model: ${profile.model}, last intention: '
        '${profile.lastIntention.isEmpty ? "(none)" : profile.lastIntention}.';
  }

  // ── Internals ────────────────────────────────────────────────

  Future<db.Agent?> _profileOrError(String agentName) =>
      store.byName(projectPath, agentName);

  Future<void> _startRun(
    db.Agent profile,
    String intention,
    String message,
    int sessionId,
  ) async {
    await store.markBusy(
      projectPath,
      profile.name,
      sessionId: sessionId,
      intention: intention,
    );
    final role = _roleOf(profile);
    final runner = SubagentRunner(
      agentName: profile.name,
      profile: profile,
      role: role,
      intention: intention,
      message: message,
      providerService: providerService,
      toolExecutor: toolExecutor,
      tools: _toolsForRole(role),
      sessionId: sessionId,
      workingDirectory: workingDirectory,
      userLanguage: userLanguage,
      maxRounds: toggles.roundLimit,
      contextCapacity: _contextCapacityFor(profile.model),
      onDistilled: (name, products) => store.writeDistilled(
        projectPath: projectPath,
        name: name,
        knowledge: products.knowledge,
        worklog: products.worklog,
      ),
      onStatus: (_) => onRunsChanged?.call(),
      onDone: (status, report) => _onRunDone(profile, status, report),
    );
    _runs[profile.name] = runner;
    onRunsChanged?.call();
    unawaited(runner.start());
  }

  Future<void> _onRunDone(
    db.Agent profile,
    String status,
    String report,
  ) async {
    _runs.remove(profile.name);
    await store.markReady(projectPath, profile.name);
    onRunsChanged?.call();

    final fresh = await store.byName(projectPath, profile.name);
    final envelope = subagentReportEnvelope(
      agentName: profile.name,
      role: _roleOf(profile),
      domain: profile.domain,
      intention: profile.lastIntention,
      status: status,
      report: report,
    );
    onReportEnvelope?.call(envelope, fresh ?? profile, status);

    // Drain the queue: the next queued dispatch starts immediately.
    final queue = _queues[profile.name];
    if (queue != null && queue.isNotEmpty) {
      final next = queue.removeAt(0);
      if (queue.isEmpty) _queues.remove(profile.name);
      final current = await store.byName(projectPath, profile.name);
      if (current != null) {
        await _startRun(
          current,
          next.intention,
          next.message,
          _ownerOf(profile),
        );
      }
    }
  }

  int _ownerOf(db.Agent profile) => profile.runOwnerSessionId ?? 0;

  SubagentRole _roleOf(db.Agent profile) =>
      profile.role == 'expert' ? SubagentRole.expert : SubagentRole.worker;

  List<ToolDef> _toolsForRole(SubagentRole role) {
    if (role == SubagentRole.worker) {
      // Everything except the subagent tools themselves (no recursion).
      return [
        for (final tool in toolRegistry.all)
          if (!tool.name.startsWith('find_agents') &&
              !tool.name.startsWith('hire_agent') &&
              !tool.name.startsWith('send_agent') &&
              !tool.name.startsWith('check_agent') &&
              !tool.name.startsWith('cancel_agent'))
            tool,
      ];
    }
    return [
      for (final tool in toolRegistry.all)
        if (kExpertToolNames.contains(tool.name)) tool,
    ];
  }

  /// Pool-order model pick: first entry with free concurrency AND
  /// budget. Null when the whole pool is unavailable.
  Future<String?> _pickModelForHire(
    SubagentRole role, {
    bool excludingCurrent = false,
  }) async {
    final pool = toggles.poolFor(role);
    for (final entry in pool.models) {
      if (_runningOnModel(entry.model) >= entry.concurrency) continue;
      if (await remainingBudget(entry.model) == BudgetLevel.exhausted) {
        continue;
      }
      return entry.model;
    }
    return null;
  }

  bool _hasCapacity(String model) {
    for (final role in SubagentRole.values) {
      final entry = toggles.poolFor(role).entryFor(model);
      if (entry != null) {
        return _runningOnModel(model) < entry.concurrency;
      }
    }
    return _runningOnModel(model) < 1;
  }

  int _runningOnModel(String model) {
    // The live-run map carries profiles; count by bound model. The
    // roster is the durable fallback for cross-restart correctness
    // (within one process the map is authoritative).
    var count = 0;
    for (final runner in _runs.values) {
      if (runner.profile.model == model) count++;
    }
    return count;
  }

  String? _providerNameForModel(String model) {
    final slash = model.indexOf('/');
    return slash <= 0 ? null : model.substring(0, slash);
  }

  dynamic _providerForModel(String model) {
    final name = _providerNameForModel(model);
    if (name == null) return null;
    return providerService.providerByName(name);
  }

  /// The bound model's context window, from the provider's model
  /// config; a conservative default when metadata is unavailable.
  int _contextCapacityFor(String model) {
    final provider = _providerForModel(model);
    if (provider == null) return 128000;
    final slash = model.indexOf('/');
    final modelId = model.substring(slash + 1);
    final config = provider.modelById(modelId);
    return config?.contextSize ?? 128000;
  }
}

/// Minimal view of [SubagentController] the manager needs (keeps the
/// manager testable without nocterm ChangeNotifier machinery).
abstract class SubagentControllerLike {
  bool get workersOn;
  bool get expertsOn;
  bool get anyOn;

  /// The global agent-run round limit (null = unlimited). Read live at
  /// each dispatch so a config change applies without a restart.
  int? get roundLimit;
  SubagentModelConfig poolFor(SubagentRole role);
}

class _QueuedDispatch {
  final String intention;
  final String message;
  const _QueuedDispatch({required this.intention, required this.message});
}
