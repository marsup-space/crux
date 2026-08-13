import '../services/provider_service.dart';
import '../services/providers/coding_plan_provider.dart';
import '../services/providers/credit_balance_provider.dart';
import 'session_controller.dart';

/// Polling cadence for the coding-plan quota API.
const Duration kCodingPlanActiveInterval = Duration(seconds: 30);
const Duration kCodingPlanIdleInterval = Duration(seconds: 180);

/// A connected provider that exposes a live usage surface — either a
/// coding plan ([CodingPlanProvider]) or a credit balance
/// ([CreditBalanceProvider]). The home `coding-plan` box renders one
/// entry per connected provider, keyed by [name].
class ConnectedProviderUsage {
  final String name;
  final CodingPlanProvider? codingPlan;
  final CreditBalanceProvider? creditBalance;

  const ConnectedProviderUsage({
    required this.name,
    this.codingPlan,
    this.creditBalance,
  });
}

/// Manages coding-plan and credit-balance polling for the chat panel.
///
/// Extracted from `_ChatPanelState` so the polling state machine
/// (provider detection, activity tracking, start/stop lifecycle)
/// lives in its own class with explicit dependencies.
class PollingCoordinator {
  final ProviderService providerService;
  final SessionController sessionController;

  /// Live read of the chat panel's `providerServiceReady` flag.
  /// Implemented as a callback rather than a captured `bool`
  /// because the chat panel flips the flag *after* this
  /// coordinator is constructed (during async provider init),
  /// and the coordinator must see the up-to-date value on
  /// every `sync*` call from `build`.
  final bool Function() _isProviderServiceReady;

  CodingPlanProvider? activeCodingPlanProvider;
  CreditBalanceProvider? activeCreditBalanceProvider;

  // All-connected-providers polling state (feeds the home `coding-plan`
  // box, which shows every connected provider, not just the active one).
  final Map<String, CodingPlanProvider> _allCodingPlan = {};
  final Map<String, CreditBalanceProvider> _allCredit = {};
  final List<ConnectedProviderUsage> _connected = [];
  String? _lastConnectedSignature;

  // Coding-plan sync state
  String? lastSyncedCpProviderName;
  bool? lastSyncedCpHasActiveSession;

  // Credit-balance sync state
  String? lastSyncedCbProviderName;
  bool? lastSyncedCbHasActiveSession;

  PollingCoordinator({
    required this.providerService,
    required this.sessionController,
    required this._isProviderServiceReady,
  });

  /// True if any session is currently marked running.
  bool hasActiveSession() => sessionController.hasAnyRunningSession;

  /// Re-align the coding-plan polling timer with the current model.
  void syncCodingPlanPolling() {
    if (!_isProviderServiceReady()) return;

    final modelKey = sessionController.currentSession.model;
    final slashIdx = modelKey.indexOf('/');
    final providerName = slashIdx > 0 ? modelKey.substring(0, slashIdx) : null;

    CodingPlanProvider? provider;
    String? apiKey;
    if (providerName != null) {
      final llm = providerService.llmProviderByName(providerName);
      if (llm is CodingPlanProvider) {
        provider = llm;
        apiKey = providerService.getApiKey(providerName);
        if (apiKey == null || apiKey.isEmpty) {
          provider = null;
          apiKey = null;
        }
      }
    }

    final hasActive = hasActiveSession();

    if (providerName == lastSyncedCpProviderName &&
        hasActive == lastSyncedCpHasActiveSession) {
      return;
    }

    final providerChanged = providerName != lastSyncedCpProviderName;

    if (providerChanged && activeCodingPlanProvider != null) {
      activeCodingPlanProvider!.stopCodingPlanPolling();
      activeCodingPlanProvider = null;
    }

    if (provider != null && apiKey != null && providerName != null) {
      activeCodingPlanProvider = provider;
      // Pass the provider's `endpoint_url` as `baseUrl` so
      // providers whose quota endpoint is derived from a
      // per-provider TOML field (Kimi) can resolve the URL at
      // fetch time. Providers with a hardcoded quota URL
      // (MiniMax) ignore the parameter.
      final providerConfig = providerService.providerByName(providerName);
      provider.startCodingPlanPolling(
        apiKey: apiKey,
        interval: hasActive
            ? kCodingPlanActiveInterval
            : kCodingPlanIdleInterval,
        baseUrl: providerConfig?.endpointUrl,
      );
    }

    lastSyncedCpProviderName = providerName;
    lastSyncedCpHasActiveSession = hasActive;
  }

  /// Re-align the credit-balance polling timer with the current model.
  void syncCreditBalancePolling() {
    if (!_isProviderServiceReady()) return;

    final modelKey = sessionController.currentSession.model;
    final slashIdx = modelKey.indexOf('/');
    final providerName = slashIdx > 0 ? modelKey.substring(0, slashIdx) : null;

    CreditBalanceProvider? provider;
    String? apiKey;
    if (providerName != null) {
      final llm = providerService.llmProviderByName(providerName);
      if (llm is CreditBalanceProvider) {
        provider = llm;
        apiKey = providerService.getApiKey(providerName);
        if (apiKey == null || apiKey.isEmpty) {
          provider = null;
          apiKey = null;
        }
      }
    }

    final hasActive = hasActiveSession();

    if (providerName == lastSyncedCbProviderName &&
        hasActive == lastSyncedCbHasActiveSession) {
      return;
    }

    final providerChanged = providerName != lastSyncedCbProviderName;

    if (providerChanged && activeCreditBalanceProvider != null) {
      activeCreditBalanceProvider!.stopCreditBalancePolling();
      activeCreditBalanceProvider = null;
    }

    if (provider != null && apiKey != null) {
      activeCreditBalanceProvider = provider;
      provider.startCreditBalancePolling(
        apiKey: apiKey,
        interval: hasActive
            ? kCodingPlanActiveInterval
            : kCodingPlanIdleInterval,
      );
    }

    lastSyncedCbProviderName = providerName;
    lastSyncedCbHasActiveSession = hasActive;
  }

  /// Connected providers that expose a live usage surface, in provider
  /// load order. Each entry carries exactly one of [ConnectedProviderUsage
  /// .codingPlan] / [ConnectedProviderUsage.creditBalance]. The home
  /// `coding-plan` box renders one row per entry.
  List<ConnectedProviderUsage> get connectedUsage =>
      List.unmodifiable(_connected);

  /// Re-align the all-connected-providers polling with the current set of
  /// providers that have an API key and a coding-plan / credit-balance
  /// surface. Independent of the active-provider polling above: the home
  /// box shows every connected provider, not just the one the current
  /// session is using.
  void syncAllProvidersUsage() {
    if (!_isProviderServiceReady()) return;

    // Desired set: provider name -> kind, discovered from the loaded
    // configs plus the presence of an API key.
    final desired = <String, String>{};
    for (final name in providerService.providerNames()) {
      final key = providerService.getApiKey(name);
      if (key == null || key.isEmpty) continue;
      final llm = providerService.llmProviderByName(name);
      if (llm is CodingPlanProvider) {
        desired[name] = 'codingPlan';
      } else if (llm is CreditBalanceProvider) {
        desired[name] = 'creditBalance';
      }
    }

    // A stable signature lets us no-op every build and only touch the
    // polling lifecycle when provider membership actually changes.
    final signature = (desired.keys.toList()..sort())
        .map((k) => '$k:${desired[k]}')
        .join('|');
    if (signature == _lastConnectedSignature) return;
    _lastConnectedSignature = signature;

    // Stop polling for providers that dropped out (key removed, or the
    // provider type changed).
    for (final name in _allCodingPlan.keys.toList()) {
      if (desired[name] != 'codingPlan') {
        _allCodingPlan[name]!.stopCodingPlanPolling();
        _allCodingPlan.remove(name);
      }
    }
    for (final name in _allCredit.keys.toList()) {
      if (desired[name] != 'creditBalance') {
        _allCredit[name]!.stopCreditBalancePolling();
        _allCredit.remove(name);
      }
    }

    // (Re)build the ordered list, starting polling for new providers.
    final ordered = <ConnectedProviderUsage>[];
    for (final name in providerService.providerNames()) {
      final kind = desired[name];
      if (kind == null) continue;
      if (kind == 'codingPlan') {
        var cp = _allCodingPlan[name];
        if (cp == null) {
          cp = providerService.llmProviderByName(name)! as CodingPlanProvider;
          _allCodingPlan[name] = cp;
          // Pass the provider's `endpoint_url` as `baseUrl` so Kimi /
          // Zhipu can derive their quota endpoint from the per-provider
          // TOML field. Providers with a hardcoded URL (MiniMax) ignore it.
          cp.startCodingPlanPolling(
            apiKey: providerService.getApiKey(name)!,
            interval: kCodingPlanIdleInterval,
            baseUrl: providerService.providerByName(name)?.endpointUrl,
          );
        }
        ordered.add(ConnectedProviderUsage(name: name, codingPlan: cp));
      } else {
        var cb = _allCredit[name];
        if (cb == null) {
          cb =
              providerService.llmProviderByName(name)! as CreditBalanceProvider;
          _allCredit[name] = cb;
          cb.startCreditBalancePolling(
            apiKey: providerService.getApiKey(name)!,
            interval: kCodingPlanIdleInterval,
          );
        }
        ordered.add(ConnectedProviderUsage(name: name, creditBalance: cb));
      }
    }

    _connected
      ..clear()
      ..addAll(ordered);
  }

  /// Stop all polling timers.
  void dispose() {
    activeCodingPlanProvider?.stopCodingPlanPolling();
    activeCodingPlanProvider = null;
    activeCreditBalanceProvider?.stopCreditBalancePolling();
    activeCreditBalanceProvider = null;
    for (final cp in _allCodingPlan.values) {
      cp.stopCodingPlanPolling();
    }
    _allCodingPlan.clear();
    for (final cb in _allCredit.values) {
      cb.stopCreditBalancePolling();
    }
    _allCredit.clear();
    _connected.clear();
  }
}
