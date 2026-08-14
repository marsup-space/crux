import 'dart:collection';
import 'package:nocterm/nocterm.dart';
import '../../commands/registry.dart';
import '../../theme/crux_theme.dart';
import '../../utils/ticker_registry.dart';

/// A tiny FPS readout rendered at the bottom of the side panel.
///
/// Only renders when debug mode is enabled (see [CommandRegistry.debugEnabled],
/// toggled by the `/debug` slash command). The widget itself decides visibility
/// based on the registry's current state, so callers don't need to plumb a
/// `bool isDebug` flag through the widget tree.
///
/// Three numbers are shown, separated by slashes:
///
/// - **Current FPS** — actually observed frame rate, from
///   [TerminalBinding.getPerformanceStats] (rolling frame count per second).
///   This is capped by the target when the UI is actively repainting, and
///   drops well below the target when the UI is idle (nocterm only schedules
///   a frame when something invalidates, so a quiet UI naturally shows a
///   low number — that's normal).
/// - **Target FPS** — the rate the scheduler is aiming for, from
///   [SchedulerBinding.targetFps]. Reflects the `targetFrameDuration`
///   configured at startup. The trailing `t` keeps the line from being
///   read as a ratio. Shown so the "is current low because we're idle or
///   because we're saturated?" question has a visible answer.
/// - **Max FPS** — theoretical ceiling given how long each frame actually
///   takes to process. Computed as `1000 / avg_total_ms`, where
///   `avg_total_ms` is the mean of recent [FrameTiming.totalDuration]
///   values. A frame that does 10ms of work can in principle hit 100 fps,
///   so the third number tells you "if we removed the rate limit, how
///   high could we go" rather than "are we smooth right now".
///
/// All three segments use the same color — this is a debug HUD, not a
/// primary surface, and a single [onSurfaceVariant] tint keeps it
/// readable on any theme without a multi-tier contrast dance that some
/// themes (e.g. Dracula) cannot satisfy.
///
/// Because this component is hosted by the side panel ([ExtraInfoPanel]),
/// which itself is only instantiated when the terminal is wide enough to
/// show the panel, the FPS readout is automatically hidden along with the
/// rest of the panel. There is no separate "show even without side panel"
/// code path — by design.
class FpsCounter extends StatefulComponent {
  const FpsCounter({super.key});

  @override
  State<FpsCounter> createState() => _FpsCounterState();
}

class _FpsCounterState extends State<FpsCounter> {
  /// Sampling window. ~500ms keeps the number readable (so it doesn't flicker
  /// between two adjacent integers on every frame) while staying responsive
  /// enough that the user sees changes quickly when something heavy starts.
  static const Duration _sampleInterval = Duration(milliseconds: 500);

  /// How many recent [FrameTiming] samples to average over for the max-FPS
  /// estimate. With a 60fps target that's ~1 second of history — enough to
  /// absorb one off-frame (e.g. a stray toast animation) without making
  /// the number lag noticeably behind what's actually being rendered.
  static const int _maxFrameSamples = 60;

  TickerToken? _sampleTicker;
  double _fps = 0.0;
  double _targetFps = 0.0;
  double _maxFps = 0.0;

  /// Rolling window of recent frame total-durations (wall-clock per frame,
  /// not throttled-gaps). Used to compute the average frame time, which
  /// gives us the theoretical "if we removed the rate limit" ceiling.
  final Queue<Duration> _recentFrames = Queue<Duration>();

  /// Stored as a field so we can remove the exact reference in [dispose].
  FrameTimingCallback? _frameCallback;

  @override
  void initState() {
    super.initState();
    // Re-render whenever the user toggles `/debug`, so the counter appears
    // or disappears in lockstep with the rest of the debug UI.
    CommandRegistry.instance.addListener(_onRegistryChanged);
    // Register the frame-timing callback only while mounted. Every frame
    // feeds us its wall-clock duration so we can average them for the
    // max-FPS estimate.
    _frameCallback = _onFrameTiming;
    SchedulerBinding.instance.addFrameTimingCallback(_frameCallback!);
    // Always start the sampler; it costs essentially nothing (a single
    // counter read every 500ms) and avoids a tiny flicker on the very first
    // build after toggling debug on. Shares the scheduler-backed ticker so
    // it lands in the same frame pipeline as other animation work.
    _sampleTicker ??= TickerRegistry.instance.subscribe(
      name: 'fpsCounter',
      interval: _sampleInterval,
      onTick: (_) => _sampleFps(),
    );
  }

  @override
  void dispose() {
    CommandRegistry.instance.removeListener(_onRegistryChanged);
    if (_frameCallback != null) {
      SchedulerBinding.instance.removeFrameTimingCallback(_frameCallback!);
      _frameCallback = null;
    }
    _sampleTicker?.cancel();
    _sampleTicker = null;
    super.dispose();
  }

  void _onRegistryChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _onFrameTiming(FrameTiming timing) {
    // Drop the oldest sample if we'd exceed the window. A plain queue
    // bounds the memory cost regardless of how long we live.
    _recentFrames.addLast(timing.totalDuration);
    while (_recentFrames.length > _maxFrameSamples) {
      _recentFrames.removeFirst();
    }
  }

  void _sampleFps() {
    // getPerformanceStats resets its own counters on read, so this is safe
    // to call on a timer — each call returns a self-contained window.
    final stats = TerminalBinding.instance.getPerformanceStats();
    final currentFps = stats['fps'] ?? 0.0;
    // Pull the target from the scheduler at sample time. We don't cache it
    // because nothing in this app currently mutates it after startup, but
    // reading live means a future hot-swap (e.g. a `/fps <n>` command)
    // would be reflected automatically.
    final targetFps = SchedulerBinding.instance.targetFps;

    // Max FPS = 1000 / avg_frame_ms. Guard the divide: a degenerate zero
    // frame time (shouldn't happen, but the binding can hand us a 0-dur
    // FrameTiming on the very first tick before build/layout/paint end
    // are populated) would otherwise blow up to infinity.
    double maxFps = 0.0;
    if (_recentFrames.isNotEmpty) {
      final totalMicros = _recentFrames.fold<int>(
        0,
        (sum, d) => sum + d.inMicroseconds,
      );
      final avgMicros = totalMicros / _recentFrames.length;
      if (avgMicros > 0) {
        maxFps = 1000000.0 / avgMicros;
      }
    }

    if (!mounted) return;
    setState(() {
      _fps = currentFps;
      _targetFps = targetFps;
      _maxFps = maxFps;
    });
  }

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final showFps = CommandRegistry.instance.debugEnabled;
    if (!showFps) {
      // Debug off: collapse entirely. We're no longer a Stack child, so
      // returning a plain [SizedBox.shrink] is safe — there is no
      // [Positioned] parentData to lose, hence no StackFit.expand flash.
      return const SizedBox.shrink();
    }

    // Trim trailing ".0" so whole numbers don't show as "60.0".
    final fpsStr = _fps.toStringAsFixed(0);
    final targetFpsStr = _targetFps.toStringAsFixed(0);
    final maxFpsStr = _maxFps.toStringAsFixed(0);

    // Full-width bordered box, same chrome as the git / project / aux
    // widgets above, so the debug readout sits at the very bottom as a
    // matching widget instead of floating over the project box.
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : null;
        return Container(
          width: width,
          decoration: BoxDecoration(
            color: theme.surface,
            border: BoxBorder.all(
              color: theme.outline,
              style: BoxBorderStyle.rounded,
            ),
            title: BorderTitle(
              text: 'fps',
              style: TextStyle(
                color: theme.onSurfaceVariant,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 1),
          child: Text(
            'FPS: $fpsStr / $targetFpsStr t / $maxFpsStr max',
            style: TextStyle(color: theme.onSurfaceVariant),
          ),
        );
      },
    );
  }
}
