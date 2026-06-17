import 'package:nocterm/nocterm.dart';

import 'frame_profiler.dart';

/// Compatibility adapter for Crux animation subscribers.
///
/// This keeps the existing small [TickerToken] API used by the UI components,
/// but delegates timing to Nocterm's frame scheduler instead of maintaining a
/// separate process-wide [Timer.periodic]. Components still register their own
/// cadence; Nocterm batches the callbacks into the frame pipeline.
class TickerRegistry {
  TickerRegistry._();
  static final TickerRegistry instance = TickerRegistry._();

  final Set<TickerToken> _tokens = <TickerToken>{};

  /// Register a tick callback.
  ///
  /// [interval] is the desired wall-clock cadence. Delivery is naturally
  /// clamped by Nocterm's target frame rate because callbacks run from the
  /// scheduler's frame phase.
  TickerToken subscribe({
    required String name,
    required Duration interval,
    required void Function() onTick,
  }) {
    late final TickerToken token;
    final handle = NoctermScheduler.instance.every(
      interval,
      (_) {
        if (!token.isActive) return;
        FrameProfiler.instance.markTimer(name);
        onTick();
      },
      owner: this,
      name: name,
      priority: SchedulePriority.animation,
    );

    token = TickerToken._(handle, this);
    _tokens.add(token);
    return token;
  }

  /// Test-only: cancel all active subscriptions.
  void resetForTest() {
    for (final token in List<TickerToken>.of(_tokens)) {
      token.cancel();
    }
    _tokens.clear();
  }

  void _unsubscribe(TickerToken token) {
    _tokens.remove(token);
  }

  /// Number of currently registered subscribers. Exposed for tests and
  /// `/d-profiler`-style diagnostics.
  int get subscriberCount => _tokens.where((token) => token.isActive).length;
}

/// Opaque handle returned by [TickerRegistry.subscribe]. Use it to cancel the
/// subscription, or to temporarily pause tick delivery.
class TickerToken {
  final TickerRegistry _registry;
  SchedulerHandle? _handle;

  TickerToken._(this._handle, this._registry);

  bool get isActive => _handle?.isActive ?? false;

  void pause() {
    _handle?.pause();
  }

  void resume() {
    _handle?.resume();
  }

  void cancel() {
    final handle = _handle;
    if (handle == null) return;
    _handle = null;
    handle.cancel();
    _registry._unsubscribe(this);
  }
}
