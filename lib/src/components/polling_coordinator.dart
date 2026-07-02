import '../services/provider_service.dart';
import '../services/providers/coding_plan_provider.dart';
import '../services/providers/credit_balance_provider.dart';
import 'session_controller.dart';

/// Polling cadence for the coding-plan quota API.
const Duration kCodingPlanActiveInterval = Duration(seconds: 30);
const Duration kCodingPlanIdleInterval = Duration(seconds: 180);

/// Manages coding-plan and credit-balance polling for the chat panel.
///
/// Extracted from `_ChatPanelState` so the polling state machine
/// (provider detection, activity tracking, start/stop lifecycle)
/// lives in its own class with explicit dependencies.
class PollingCoordinator {
  final ProviderService providerService;
  final SessionController sessionController;
  final bool providerServiceReady;

  CodingPlanProvider? activeCodingPlanProvider;
  CreditBalanceProvider? activeCreditBalanceProvider;

  // Coding-plan sync state
  String? lastSyncedCpProviderName;
  bool? lastSyncedCpHasActiveSession;

  // Credit-balance sync state
  String? lastSyncedCbProviderName;
  bool? lastSyncedCbHasActiveSession;

  PollingCoordinator({
    required this.providerService,
    required this.sessionController,
    required this.providerServiceReady,
  });

  /// True if any session is currently marked running.
  bool hasActiveSession() => sessionController.hasAnyRunningSession;

  /// Re-align the coding-plan polling timer with the current model.
  void syncCodingPlanPolling() {
    if (!providerServiceReady) return;

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

    if (provider != null && apiKey != null) {
      activeCodingPlanProvider = provider;
      provider.startCodingPlanPolling(
        apiKey: apiKey,
        interval: hasActive
            ? kCodingPlanActiveInterval
            : kCodingPlanIdleInterval,
      );
    }

    lastSyncedCpProviderName = providerName;
    lastSyncedCpHasActiveSession = hasActive;
  }

  /// Re-align the credit-balance polling timer with the current model.
  void syncCreditBalancePolling() {
    if (!providerServiceReady) return;

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

  /// Stop all polling timers.
  void dispose() {
    activeCodingPlanProvider?.stopCodingPlanPolling();
    activeCodingPlanProvider = null;
    activeCreditBalanceProvider?.stopCreditBalancePolling();
    activeCreditBalanceProvider = null;
  }
}
