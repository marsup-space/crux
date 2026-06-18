import 'dart:async';

import '../../models/credit_balance.dart';
import '../llm_provider.dart';

/// Mixin that adds credit-balance polling to a provider
/// implementation.
///
/// Provider classes opt in by including `with CreditBalanceProvider`
/// in their declaration. They must also implement
/// [getCreditBalance], which is a one-shot fetch returning a
/// [CreditBalance] snapshot — the rest of the lifecycle
/// (timer, stream, latest-cache, interval switching) is handled
/// by this mixin.
///
/// ```dart
/// class DeepSeekProvider extends OpenAICompatibleProvider
///     with CreditBalanceProvider {
///   @override
///   Future<CreditBalance> getCreditBalance() async { ... }
/// }
/// ```
///
/// This mixin is separate from [CodingPlanProvider] because
/// DeepSeek uses a credit-based balance model
/// (`/user/balance`), not a token-plan usage model. The two
/// mixins are mutually exclusive: a provider should mix in
/// one or the other, not both.
///
/// The mixin is `on LlmProvider` (not `on Object`) so the
/// `LlmProvider.name` getter is available inside mixin
/// methods.
mixin CreditBalanceProvider on LlmProvider {
  // ─── Public API for the chat panel / widget ─────────────────

  /// Whether this provider has a credit balance to display.
  /// Always `true` for providers that include this mixin;
  /// declared here so callers can use a single
  /// `is CreditBalanceProvider` check without knowing the
  /// mixin's specific name.
  @override
  bool get isCreditBalance => true;

  /// Stream of successful balance snapshots. Emits a new
  /// [CreditBalance] each time the polling timer fires
  /// successfully. The stream is broadcast — multiple
  /// listeners are allowed.
  Stream<CreditBalance> get creditBalanceStream =>
      _creditBalanceController.stream;

  /// The most recent successful snapshot, or null if we
  /// haven't polled yet (or the last fetch failed).
  CreditBalance? get latestCreditBalance => _latestCreditBalance;

  /// The most recent error, or null. Cleared on the next
  /// successful fetch.
  CreditBalanceError? get latestCreditBalanceError =>
      _latestCreditBalanceError;

  /// Whether polling is currently scheduled.
  bool get isCreditBalancePolling =>
      _creditBalanceTimer?.isActive ?? false;

  /// Current polling interval.
  Duration get creditBalanceInterval => _creditBalanceInterval;

  // ─── Lifecycle ──────────────────────────────────────────────

  /// Begin (or update) polling.
  ///
  /// The mixin doesn't own the API key — providers get it
  /// per-call from the chat panel. The chat panel calls
  /// this when the user switches to a model under this
  /// provider, passing the key it pulled from
  /// [ProviderService.getApiKey].
  ///
  /// Idempotent: calling repeatedly with the same key and
  /// interval is a no-op. Changing [interval] reschedules
  /// the next tick on the new cadence.
  void startCreditBalancePolling({
    required String apiKey,
    Duration? interval,
  }) {
    _creditBalanceApiKey = apiKey;
    final needsRestart = _creditBalanceTimer != null;
    if (interval != null) _creditBalanceInterval = interval;

    if (needsRestart) {
      _creditBalanceTimer?.cancel();
      _startTimer();
    } else {
      _startTimer();
      // First tick fires immediately so the toolbar doesn't
      // show "—" for `interval` seconds after a switch.
      unawaited(_tick());
    }
  }

  /// Stop polling. The latest snapshot is preserved so the
  /// toolbar can still display the last known value; the
  /// stream stays open for new subscribers.
  void stopCreditBalancePolling() {
    _creditBalanceTimer?.cancel();
    _creditBalanceTimer = null;
  }

  /// Update the polling interval without otherwise touching
  /// the lifecycle. If polling isn't active, the new
  /// interval is stored and used by the next
  /// [startCreditBalancePolling] call.
  void setCreditBalanceInterval(Duration interval) {
    if (interval == _creditBalanceInterval) return;
    _creditBalanceInterval = interval;
    if (_creditBalanceTimer != null) {
      _creditBalanceTimer?.cancel();
      _startTimer();
    }
  }

  /// Release all resources. Call on app shutdown. After this
  /// the stream is closed and the provider must not be
  /// polled again.
  Future<void> disposeCreditBalancePolling() async {
    stopCreditBalancePolling();
    await _creditBalanceController.close();
  }

  // ─── Subclass contract ──────────────────────────────────────

  /// One-shot fetch of the current credit balance. The
  /// mixin calls this on the polling timer.
  ///
  /// Throws [CreditBalanceError] for parse / network /
  /// configuration failures (or any other [Exception] which
  /// the mixin will surface as a `network` error).
  Future<CreditBalance> getCreditBalance();

  // ─── Implementation ─────────────────────────────────────────

  Duration _creditBalanceInterval = Duration(seconds: 60);
  String? _creditBalanceApiKey;
  CreditBalance? _latestCreditBalance;
  CreditBalanceError? _latestCreditBalanceError;
  Timer? _creditBalanceTimer;
  final StreamController<CreditBalance> _creditBalanceController =
      StreamController<CreditBalance>.broadcast();

  void _startTimer() {
    _creditBalanceTimer?.cancel();
    _creditBalanceTimer = Timer.periodic(
      _creditBalanceInterval,
      (_) => unawaited(_tick()),
    );
  }

  Future<void> _tick() async {
    final key = _creditBalanceApiKey;
    if (key == null || key.isEmpty) {
      _latestCreditBalanceError = const CreditBalanceError(
        CreditBalanceErrorKind.noApiKey,
        'No API key set on the mixin',
      );
      return;
    }
    try {
      final balance = await getCreditBalance();
      _latestCreditBalance = balance;
      _latestCreditBalanceError = null;
      if (!_creditBalanceController.isClosed) {
        _creditBalanceController.add(balance);
      }
    } on CreditBalanceError catch (e) {
      _latestCreditBalanceError = e;
    } catch (e) {
      _latestCreditBalanceError = CreditBalanceError(
        CreditBalanceErrorKind.network,
        e.toString(),
      );
    }
  }
}
