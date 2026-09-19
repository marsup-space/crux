import 'dart:async';

import 'package:nocterm/nocterm.dart';

import '../../models/subagent.dart';
import 'subagent_config_store.dart';
import 'subagent_manager.dart' show SubagentControllerLike;

/// The live subagent-mode toggles + model-pool configuration.
///
/// Mirrors `LocaleController`: holds the two independent switches
/// (`workersOn` / `expertsOn`) and the role model pools, persists via
/// [SubagentConfigStore] to `config.toml`, and notifies listeners on
/// change so mounted UI (the subagent bar, the toolbar chips) re-renders.
///
/// The controller is deliberately presentation-free: it knows nothing
/// about runs or the roster. M2's runner/tool wiring reads [toggles] and
/// [pools] from here; this class stays the single source of truth for
/// "is subagent mode on, and which models may agents run on".
class SubagentController extends ChangeNotifier
    implements SubagentControllerLike {
  final SubagentConfigStore configStore;
  final String? startupWarning;

  SubagentRuntimeToggles _toggles;
  final SubagentConfig _pools;

  // Private factory-shape constructor: `create` is the only public
  // entry (it does the async config read + fallback handling).
  // Positional formals — named parameters cannot start with `_`.
  SubagentController._(
    this.configStore,
    this._toggles,
    this._pools, {
    this.startupWarning,
  });
  static Future<SubagentController> create({
    required SubagentConfigStore configStore,
  }) async {
    SubagentRuntimeToggles toggles;
    SubagentConfig pools;
    String? warning;
    try {
      toggles = await configStore.readToggles();
    } catch (error) {
      toggles = const SubagentRuntimeToggles();
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
      toggles,
      pools,
      startupWarning: warning,
    );
  }

  SubagentRuntimeToggles get toggles => _toggles;
  SubagentConfig get pools => _pools;
  @override
  bool get workersOn => _toggles.workersOn;
  @override
  bool get expertsOn => _toggles.expertsOn;
  @override
  bool get anyOn => _toggles.anyOn;

  @override
  SubagentModelConfig poolFor(SubagentRole role) => _pools.forRole(role);

  /// Flip one of the two independent switches. Returns a result with a
  /// null `toggles` when [role] is not a valid switch target.
  Future<SubagentToggleResult> setToggle(SubagentRole role, bool value) async {
    final next = switch (role) {
      SubagentRole.worker => _toggles.copyWith(workersOn: value),
      SubagentRole.expert => _toggles.copyWith(expertsOn: value),
    };
    _toggles = next;
    notifyListeners();
    try {
      await configStore.writeToggles(next);
      return SubagentToggleResult(toggles: next);
    } catch (error) {
      return SubagentToggleResult(toggles: next, persistenceError: error);
    }
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
