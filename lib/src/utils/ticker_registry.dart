import 'package:nocterm/nocterm.dart';

import 'frame_profiler.dart';

/// Callback signature for per-frame ticks registered through
/// [TickerRegistry]. Receives the wall-clock [Duration] since the
/// last tick (the same value the underlying [NoctermScheduler]
/// computes as `tick.delta`).
///
/// Receiving the elapsed time lets every consumer drive
/// delta-time animations instead of assuming a fixed 16 ms cadence.
/// On the very first tick `elapsed` is [Duration.zero] (the
/// scheduler records no `lastTick` yet).
///
/// Why delta instead of fixed-step:
/// - A frame that took 20 ms leaves a 3.4 ms budget gap. With
///   fixed-step math, that gap is silently dropped — animations
///   stutter on slow frames and overshoot on fast ones.
/// - With delta math, the consumer chooses the math (e.g.
///   `phase += step * dt / 16ms`) so phase advance tracks wall-clock
///   time regardless of the actual frame interval.
/// - The reasoning-block character streamer uses the same value
///   to scale "characters emitted per frame" by the same ratio,
///   keeping emission rate proportional to wall time.
typedef TickerCallback = void Function(Duration elapsed);

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
  ///
  /// The callback receives the wall-clock [Duration] since the previous
  /// tick (`SchedulerTick.delta`) so consumers can drive delta-time
  /// animations instead of assuming a fixed 16 ms step.
  TickerToken subscribe({
    required String name,
    required Duration interval,
    required TickerCallback onTick,
  }) {
    late final TickerToken token;
    final handle = NoctermScheduler.instance.every(
      interval,
      (tick) {
        if (!token.isActive) return;
        FrameProfiler.instance.markTimer(name);
        onTick(tick.delta);
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