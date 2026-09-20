import 'dart:async';

import 'package:nocterm/nocterm.dart';

import '../../models/subagent.dart';
import 'subagent_config_store.dart';
import 'subagent_manager.dart' show SubagentControllerLike;

/// The live subagent-mode toggles + model-pool configuration.
///
/// The switches are PER-SESSION state: each session persists its own
/// `workersOn` / `expertsOn` pair in the sessions table (columns
/// `subagent_workers_on` / `subagent_experts_on`), and the controller
/// follows the active session — switching sessions switches the
/// effective mode. A session that never flipped a switch reads as
/// `null` and falls back to the global default from
/// `config.toml [subagent]`; once flipped, the session value is
/// authoritative and survives restarts.
///
/// The model pools stay global config (shared by all sessions) and
/// live in [configStore].
///
/// The controller is deliberately presentation-free: it knows nothing
/// about runs or the roster. The manager/tools read [toggles] and
/// [pools] from here; this class stays the single source of truth
/// for "is subagent mode on, and which models may agents run on".
class SubagentController extends ChangeNotifier
    implements SubagentControllerLike {
  final SubagentConfigStore configStore;

  /// Persists the per-session switches. Null in tests / headless
  /// setups — writes then become no-ops and reads fall back to the
  /// in-memory value.
  final Future<void> Function(
    int sessionId, {
    required bool? workersOn,
    required bool? expertsOn,
  })?
  persistToggles;

  /// Loads the persisted switches for one session. Null in tests —
  /// every session then reads as "never set" (global default).
  final Future<({bool? workers, bool? experts})> Function(int sessionId)?
  loadToggles;

  final String? startupWarning;

  /// The global default (config.toml). Used for sessions that never
  /// flipped a switch.
  final SubagentRuntimeToggles _globalDefault;

  /// The global model pools, cached at create / [reloadPools] time
  /// so [poolFor] stays synchronous (the manager's hire path reads
  /// it on every dispatch).
  SubagentConfig _pools;

  /// The active session's persisted values. `null` on a field =
  /// never set → global default applies.
  bool? _sessionWorkersOn;
  bool? _sessionExpertsOn;

  int? _activeSessionId;

  /// Set when a switch flipped since the last user turn; consumed by
  /// the turn orchestrator to attach the mode announcement to the
  /// next user message (plan §模式切换与 cache item 2). One-shot per
  /// flip: reading clears it.
  bool _announcementPending = false;

  /// Whether a mode announcement is waiting to ride the next user
  /// message. True after any setToggle call until the next
  /// [consumePendingAnnouncement].
  bool get announcementPending => _announcementPending;

  /// The one-shot read: returns the pending flag and clears it. The
  /// orchestrator calls this when building a user turn — the FIRST
  /// message after a flip carries the announcement, later ones don't.
  bool consumePendingAnnouncement() {
    final pending = _announcementPending;
    _announcementPending = false;
    return pending;
  }

  // Private factory-shape constructor: `create` is the only public
  // entry (it does the async config read + fallback handling).
  // Positional formals — named parameters cannot start with `_`.
  SubagentController._(
    this.configStore,
    this._globalDefault,
    this._pools, {
    this.persistToggles,
    this.loadToggles,
    this.startupWarning,
  });
  static Future<SubagentController> create({
    required SubagentConfigStore configStore,
    Future<void> Function(
      int sessionId, {
      required bool? workersOn,
      required bool? expertsOn,
    })?
    persistToggles,
    Future<({bool? workers, bool? experts})> Function(int sessionId)?
    loadToggles,
  }) async {
    SubagentRuntimeToggles defaults;
    SubagentConfig pools;
    String? warning;
    try {
      defaults = await configStore.readToggles();
    } catch (error) {
      defaults = const SubagentRuntimeToggles();
      warning = 'Could not read subagent configuration: $error';
    }
    try {
      pools = await configStore.readPools();
    } catch (error) {
      pools = const SubagentConfig();
      warning ??= 'Could not read subagent model pools: $error';
    }
    return SubagentController._(
      configStore,
      defaults,
      pools,
      persistToggles: persistToggles,
      loadToggles: loadToggles,
      startupWarning: warning,
    );
  }

  /// The effective toggles for the active session: the session's
  /// persisted value where set, else the global default.
  SubagentRuntimeToggles get toggles => SubagentRuntimeToggles(
    workersOn: _sessionWorkersOn ?? _globalDefault.workersOn,
    expertsOn: _sessionExpertsOn ?? _globalDefault.expertsOn,
  );

  SubagentRuntimeToggles get globalDefault => _globalDefault;

  /// Make [sessionId] the active session: loads its persisted
  /// switches (async; notifies listeners when the values land).
  Future<void> attachSession(int sessionId) async {
    if (_activeSessionId == sessionId) return;
    _activeSessionId = sessionId;
    if (loadToggles == null) {
      _sessionWorkersOn = null;
      _sessionExpertsOn = null;
      notifyListeners();
      return;
    }
    try {
      final loaded = await loadToggles!(sessionId);
      // A rapid A→B→A switch may have moved on; drop stale loads.
      if (_activeSessionId != sessionId) return;
      _sessionWorkersOn = loaded.workers;
      _sessionExpertsOn = loaded.experts;
    } catch (_) {
      if (_activeSessionId != sessionId) return;
      _sessionWorkersOn = null;
      _sessionExpertsOn = null;
    }
    notifyListeners();
  }

  @override
  bool get workersOn => toggles.workersOn;
  @override
  bool get expertsOn => toggles.expertsOn;
  @override
  bool get anyOn => toggles.anyOn;

  /// The global agent-run round limit (null = unlimited). Cached with
  /// the model pools at create / [reloadPools] time, so a config
  /// fullpane save takes effect on the next dispatch.
  @override
  int? get roundLimit => _pools.maxRounds;

  @override
  SubagentModelConfig poolFor(SubagentRole role) => _pools.forRole(role);

  /// Re-read the model pools from config.toml. Call after the config
  /// fullpane saves — hire's model picker must see the new pools
  /// without a restart.
  Future<void> reloadPools() async {
    try {
      _pools = await configStore.readPools();
      notifyListeners();
    } catch (_) {
      // Keep the last-known-good pools; a failed re-read must not
      // blank the cache.
    }
  }

  /// Flip one of the two independent switches for the ACTIVE
  /// session. Persists to the session row; the global default is
  /// untouched.
  Future<SubagentToggleResult> setToggle(SubagentRole role, bool value) async {
    final next = switch (role) {
      SubagentRole.worker => SubagentRuntimeToggles(
        workersOn: value,
        expertsOn: expertsOn,
      ),
      SubagentRole.expert => SubagentRuntimeToggles(
        workersOn: workersOn,
        expertsOn: value,
      ),
    };
    switch (role) {
      case SubagentRole.worker:
        _sessionWorkersOn = value;
      case SubagentRole.expert:
        _sessionExpertsOn = value;
    }
    _announcementPending = true;
    notifyListeners();
    if (_activeSessionId != null && persistToggles != null) {
      try {
        await persistToggles!(
          _activeSessionId!,
          workersOn: _sessionWorkersOn,
          expertsOn: _sessionExpertsOn,
        );
        return SubagentToggleResult(toggles: next);
      } catch (error) {
        return SubagentToggleResult(toggles: next, persistenceError: error);
      }
    }
    return SubagentToggleResult(toggles: next);
  }
}

/// The outcome of a [SubagentController.setToggle] call.
class SubagentToggleResult {
  final SubagentRuntimeToggles? toggles;
  final Object? persistenceError;

  const SubagentToggleResult({this.toggles, this.persistenceError});

  bool get changed => toggles != null;
  bool get persisted => changed && persistenceError == null;
}
