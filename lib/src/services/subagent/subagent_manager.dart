import 'dart:async';

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
  });

  /// Live runs (for find_agents / chips / check_agent).
  Map<String, SubagentRunner> get runs => Map.unmodifiable(_runs);

  bool isBusy(String agentName) => _runs.containsKey(agentName);

  /// `remainingBudget(model)`: the plan's unified budget probe.
  ///
  /// Coding-plan providers report window percentages; credit-balance
  /// providers report availability. A provider with neither mixin (or
  /// a fetch error / stale cache) reports [BudgetLevel.ample] — the
  /// probe never blocks dispatch on missing data.
  BudgetLevel remainingBudget(String model) {
    final provider = _providerForModel(model);
    if (provider == null) return BudgetLevel.ample;
    if (provider is CodingPlanProvider) {
      final usage = provider.latestCodingPlanUsage;
      if (usage == null) return BudgetLevel.ample;
      final pct = usage.hasIntervalWindow
          ? usage.intervalRemainingPct
          : usage.weeklyRemainingPct;
      if (pct <= 0) return BudgetLevel.exhausted;
      if (pct <= 10) return BudgetLevel.tight;
      return BudgetLevel.ample;
    }
    if (provider is CreditBalanceProvider) {
      final balance = provider.latestCreditBalance;
      if (balance == null) return BudgetLevel.ample;
      if (!balance.isAvailable) return BudgetLevel.exhausted;
      return BudgetLevel.ample;
    }
    return BudgetLevel.ample;
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
      _queues.putIfAbsent(agentName, () => []).add(
        _QueuedDispatch(intention: intention, message: message),
      );
      return 'agent://$agentName is busy — message queued (position '
          '${_queues[agentName]!.length}). It will be delivered when the '
          'current run ends.';
    }
    await _startRun(profile, intention, message, sessionId);
    return 'Dispatched agent://$agentName (intention: $intention). It runs '
        'in the background and will report back when done.';
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
    final model = _pickModelForHire(role);
    if (model == null) {
      return 'No model available for ${role.name}s: the '
          '[subagent.${role.name}s] pool is empty or every model is '
          'saturated / out of budget. Configure it in config.toml.';
    }
    final profile = await store.hire(role: role, model: model, domain: domain);
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
    if (remainingBudget(model) == BudgetLevel.exhausted ||
        !_hasCapacity(model)) {
      model = _pickModelForHire(role, excludingCurrent: false) ?? model;
    }
    final forked = await store.hire(role: role, model: model, domain: source.domain);
    if (source.knowledge.isNotEmpty || source.worklog.isNotEmpty) {
      await store.writeDistilled(
        name: forked.name,
        knowledge: source.knowledge,
        worklog: source.worklog,
      );
    }
    final fresh = (await store.byName(forked.name))!;
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
    await store.markReady(agentName);
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
    final profile = await store.byName(agentName);
    if (profile == null) return 'Unknown agent "$agentName".';
    return 'agent://$agentName — ready. Domain: ${profile.domain}, '
        'model: ${profile.model}, last intention: '
        '${profile.lastIntention.isEmpty ? "(none)" : profile.lastIntention}.';
  }

  // ── Internals ────────────────────────────────────────────────

  Future<db.Agent?> _profileOrError(String agentName) =>
      store.byName(agentName);

  Future<void> _startRun(
    db.Agent profile,
    String intention,
    String message,
    int sessionId,
  ) async {
    await store.markBusy(
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
      contextCapacity: _contextCapacityFor(profile.model),
      onDistilled: (name, products) => store.writeDistilled(
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

  Future<void> _onRunDone(db.Agent profile, String status, String report) async {
    _runs.remove(profile.name);
    await store.markReady(profile.name);
    onRunsChanged?.call();

    final fresh = await store.byName(profile.name);
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
      final current = await store.byName(profile.name);
      if (current != null) {
        await _startRun(current, next.intention, next.message, _ownerOf(profile));
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
  String? _pickModelForHire(SubagentRole role, {bool excludingCurrent = false}) {
    final pool = toggles.poolFor(role);
    for (final entry in pool.models) {
      if (_runningOnModel(entry.model) >= entry.concurrency) continue;
      if (remainingBudget(entry.model) == BudgetLevel.exhausted) continue;
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

  dynamic _providerForModel(String model) {
    final slash = model.indexOf('/');
    if (slash <= 0) return null;
    return providerService.providerByName(model.substring(0, slash));
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
  SubagentModelConfig poolFor(SubagentRole role);
}

class _QueuedDispatch {
  final String intention;
  final String message;
  const _QueuedDispatch({required this.intention, required this.message});
}
