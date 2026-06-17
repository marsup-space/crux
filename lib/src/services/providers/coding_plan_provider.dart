import 'dart:async';

import '../../models/coding_plan_usage.dart';
import '../llm_provider.dart';

/// Mixin that adds coding-plan (Token Plan) usage polling to a
/// provider implementation.
///
/// Provider classes opt in by including `with CodingPlanProvider`
/// in their declaration. They must also implement
/// [getCodingPlanUsage], which is a one-shot fetch returning a
/// [CodingPlanUsage] snapshot — the rest of the lifecycle
/// (timer, stream, latest-cache, interval switching) is handled
/// by this mixin.
///
/// ```dart
/// class MyProvider extends AnthropicCompatibleProvider
///     with CodingPlanProvider {
///   @override
///   Future<CodingPlanUsage> getCodingPlanUsage() async {
///     // make the HTTP call, parse the response, return it
///   }
/// }
/// ```
///
/// ## Why a mixin?
///
/// The mixin lives on the [LlmProvider] (not on a separate
/// service) so that:
///   * The provider owns its own URL, auth style, and response
///     shape. The chat panel just calls `isCodingPlan` and
///     subscribes to the stream.
///   * Adding a new coding-plan provider is a single
///     `with CodingPlanProvider` line plus a
///     [getCodingPlanUsage] implementation. No service to
///     plumb, no global state to thread.
///   * Non-coding-plan providers (DeepSeek, Local, custom)
///     don't carry any of this — they just don't `with` the
///     mixin, and `isCodingPlan` defaults to `false` on the
///     base [LlmProvider].
///
/// The mixin is `on LlmProvider` (not `on Object`) so the
/// `LlmProvider.name` getter is available inside mixin
/// methods.
mixin CodingPlanProvider on LlmProvider {
  // ─── Public API for the chat panel / widget ─────────────────

  /// Whether this provider has a coding plan to display. Always
  /// `true` for providers that include this mixin; declared
  /// here so callers can use a single `is CodingPlanProvider`
  /// check without knowing the mixin's specific name.
  @override
  bool get isCodingPlan => true;

  /// Stream of successful usage snapshots. Emits a new
  /// [CodingPlanUsage] each time the polling timer fires
  /// successfully. The stream is broadcast — multiple
  /// listeners are allowed.
  Stream<CodingPlanUsage> get codingPlanUsageStream =>
      _codingPlanController.stream;

  /// The most recent successful snapshot, or null if we
  /// haven't polled yet (or the last fetch failed).
  CodingPlanUsage? get latestCodingPlanUsage => _latestCodingPlanUsage;

  /// The most recent error, or null. Cleared on the next
  /// successful fetch.
  CodingPlanUsageError? get latestCodingPlanError => _latestCodingPlanError;

  /// Whether polling is currently scheduled.
  bool get isCodingPlanPolling => _codingPlanTimer?.isActive ?? false;

  /// Current polling interval.
  Duration get codingPlanInterval => _codingPlanInterval;

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
  void startCodingPlanPolling({
    required String apiKey,
    Duration? interval,
  }) {
    _codingPlanApiKey = apiKey;
    final needsRestart = _codingPlanTimer != null;
    if (interval != null) _codingPlanInterval = interval;

    if (needsRestart) {
      _codingPlanTimer?.cancel();
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
  void stopCodingPlanPolling() {
    _codingPlanTimer?.cancel();
    _codingPlanTimer = null;
  }

  /// Update the polling interval without otherwise touching
  /// the lifecycle. If polling isn't active, the new
  /// interval is stored and used by the next
  /// [startCodingPlanPolling] call.
  void setCodingPlanInterval(Duration interval) {
    if (interval == _codingPlanInterval) return;
    _codingPlanInterval = interval;
    if (_codingPlanTimer != null) {
      _codingPlanTimer?.cancel();
      _startTimer();
    }
  }

  /// Release all resources. Call on app shutdown. After this
  /// the stream is closed and the provider must not be
  /// polled again.
  Future<void> disposeCodingPlanPolling() async {
    stopCodingPlanPolling();
    await _codingPlanController.close();
  }

  // ─── Subclass contract ──────────────────────────────────────

  /// One-shot fetch of the current coding-plan usage. The
  /// mixin calls this on the polling timer.
  ///
  /// Throws [CodingPlanUsageError] for parse / network /
  /// configuration failures (or any other [Exception] which
  /// the mixin will surface as a `network` error).
  Future<CodingPlanUsage> getCodingPlanUsage();

  // ─── Implementation ─────────────────────────────────────────

  Duration _codingPlanInterval = Duration(seconds: 60);
  String? _codingPlanApiKey;
  CodingPlanUsage? _latestCodingPlanUsage;
  CodingPlanUsageError? _latestCodingPlanError;
  Timer? _codingPlanTimer;
  final StreamController<CodingPlanUsage> _codingPlanController =
      StreamController<CodingPlanUsage>.broadcast();

  void _startTimer() {
    _codingPlanTimer?.cancel();
    _codingPlanTimer = Timer.periodic(
      _codingPlanInterval,
      (_) => unawaited(_tick()),
    );
  }

  Future<void> _tick() async {
    final key = _codingPlanApiKey;
    if (key == null || key.isEmpty) {
      _latestCodingPlanError = const CodingPlanUsageError(
        CodingPlanUsageErrorKind.noApiKey,
        'No API key set on the mixin',
      );
      return;
    }
    try {
      final usage = await getCodingPlanUsage();
      _latestCodingPlanUsage = usage;
      _latestCodingPlanError = null;
      // `add` is a no-op if the stream is closed (e.g. the
      // provider was disposed mid-tick). That's fine — the
      // data still lands in `_latestCodingPlanUsage` for any
      // synchronous reader.
      if (!_codingPlanController.isClosed) {
        _codingPlanController.add(usage);
      }
    } on CodingPlanUsageError catch (e) {
      _latestCodingPlanError = e;
    } catch (e) {
      _latestCodingPlanError = CodingPlanUsageError(
        CodingPlanUsageErrorKind.network,
        e.toString(),
      );
    }
  }
}
