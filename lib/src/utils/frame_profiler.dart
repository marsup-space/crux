// frame_profiler reads per-widget layout timings from nocterm's internal
// NoctermLayoutProfiler, which is toggled on by the chat panel's `/d-profiler`
// command. Not part of nocterm's public API; importing here is intentional.
// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nocterm/nocterm.dart';
import 'package:nocterm/src/foundation/layout_profiler.dart';
import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';

import 'user_data_directory.dart';

/// Per-frame timing entry captured by [FrameProfiler].
///
/// One of these is appended to the report for every frame the
/// nocterm scheduler reports while recording is active. Designed
/// to be lightweight — building one doesn't allocate much more
/// than the captured feature snapshot, which is supplied by the
/// caller.
class _FrameRecord {
  _FrameRecord({
    required this.frameNumber,
    required this.timestampMs,
    required this.buildUs,
    required this.layoutUs,
    required this.paintUs,
    required this.compositingUs,
    required this.totalUs,
    required this.activeFeatures,
    required this.scheduledByReason,
    required this.timerTickCounts,
  });

  final int frameNumber;
  final int timestampMs;
  final int buildUs;
  final int layoutUs;
  final int paintUs;
  final int compositingUs;
  final int totalUs;
  final Map<String, dynamic> activeFeatures;
  final String scheduledByReason;

  /// Per-timer tick counts accumulated between the previous
  /// frame and this one. Lets the report show "metricsTimer
  /// fired 10 times during this frame" rather than just "yes/no
  /// it was active".
  final Map<String, int> timerTickCounts;

  Map<String, dynamic> toJson() => {
    'frame': frameNumber,
    'tMs': timestampMs,
    'buildUs': buildUs,
    'layoutUs': layoutUs,
    'paintUs': paintUs,
    'compositingUs': compositingUs,
    'totalUs': totalUs,
    'features': activeFeatures,
    'reason': scheduledByReason,
    'ticks': timerTickCounts,
  };
}

/// In-process frame profiler that records per-frame nocterm
/// scheduler timings and correlates them with chat-panel state
/// snapshots, so a slow frame can be attributed to a specific
/// trigger (a periodic timer firing, a setState, etc.).
///
/// Designed for opt-in, short-lived recordings triggered by
/// `/d-profiler <secs>`. Not enabled by default — its snapshot
/// provider is the chat panel itself, which calls
/// [registerSnapshotProvider] once it has wired up the state
/// it wants to expose.
///
/// Threading: all access is on the main UI isolate. The
/// scheduler callbacks fire on the UI isolate too (nocterm
/// runs single-threaded), so no synchronisation is needed.
class FrameProfiler {
  FrameProfiler._();
  static final FrameProfiler instance = FrameProfiler._();

  /// Snapshot provider registered by the chat panel. Returns a
  /// map describing what timers / state are active at the
  /// moment the profiler asks (post-frame, before the next
  /// frame is recorded). Single-slot — only the most recent
  /// registration is used.
  Map<String, dynamic> Function()? _snapshotProvider;

  /// Markers that should be attached to the *next* captured
  /// frame. The chat panel pushes "setState" whenever its
  /// `_refresh()` runs; timer code pushes the timer's tag
  /// (e.g. `metricsTimer`). Both are coalesced — multiple marks
  /// of the same name before the next frame result in a single
  /// entry. Reset every frame inside [attachSnapshot].
  final List<String> _pendingReasons = [];

  /// Per-timer tick counts accumulated since the previous
  /// frame. Reset to empty at the start of every frame inside
  /// [attachSnapshot] so the values attached to frame N
  /// represent "ticks that happened between frame N-1 and N".
  final Map<String, int> _timerTickCounts = {};

  bool _recording = false;
  FrameTimingCallback? _frameCallback;
  int _lastFrameNumber = -1;
  final List<_FrameRecord> _frames = [];

  DateTime? _startTime;
  Duration _requestedDuration = Duration.zero;

  /// True while a recording is in progress. Read by the
  /// `/d-profiler` command to report status.
  bool get isRecording => _recording;

  /// When the current recording started (null if not
  /// recording).
  DateTime? get startedAt => _startTime;

  /// Total duration the current recording was requested to
  /// run for. Useful for the `/d-profiler` status display.
  Duration get requestedDuration => _requestedDuration;

  /// Number of frames captured so far in the current
  /// recording.
  int get capturedFrameCount => _frames.length;

  /// Register a function that the profiler should call at the
  /// end of every frame to capture a snapshot of "what's
  /// running right now" (metrics timer? tldr generation?
  /// glossy button animating? current session id? current
  /// message count?).
  ///
  /// The returned map is JSON-serialised verbatim into the
  /// report, so callers should stick to primitives (bool, int,
  /// double, String, List, Map). Called from the post-frame
  /// phase so the snapshot reflects state immediately after
  /// the frame's build/layout/paint completes.
  void registerSnapshotProvider(Map<String, dynamic> Function() provider) {
    _snapshotProvider = provider;
  }

  /// Clear any registered snapshot provider. The chat panel
  /// calls this from its dispose to avoid dangling closures.
  void clearSnapshotProvider() {
    _snapshotProvider = null;
  }

  /// Mark that the chat panel issued a `setState()` (i.e. the
  /// `_refresh()` helper ran). The next captured frame will
  /// attribute itself to "setState". Multiple marks before the
  /// next frame are coalesced — only one "setState" appears.
  void markSetState() {
    if (!_recording) return;
    if (!_pendingReasons.contains('setState')) {
      _pendingReasons.add('setState');
    }
  }

  /// Mark that a named timer fired. Use a short, stable tag
  /// (e.g. `metricsTimer`, `contextAnim`, `glossyButton`,
  /// `fpsCounter`, `toastTick`, `extraInfoAnim`). Coalesced
  /// like [markSetState] for the `reason` field, but the
  /// actual fire count is also recorded in the per-frame
  /// `ticks` map so a single timer firing 30 times between two
  /// frames is visible as `ticks.metricsTimer = 30`.
  void markTimer(String name) {
    if (!_recording) return;
    if (!_pendingReasons.contains(name)) {
      _pendingReasons.add(name);
    }
    _timerTickCounts[name] = (_timerTickCounts[name] ?? 0) + 1;
  }

  /// Time a synchronous block of code under the section
  /// name [section]. The result is recorded into
  /// [NoctermTimeline], which the profiler auto-collects
  /// into the report on [stop] under `bySection`.
  ///
  /// Use this to instrument the build / layout / paint
  /// methods of heavy widgets so a slow frame can be
  /// attributed to a specific code region. The block can
  /// return a value; the return is forwarded unchanged.
  ///
  /// Cheap when not recording: it just calls [body].
  /// When recording, it calls [NoctermTimeline.startSync]
  /// / [NoctermTimeline.finishSync], which under the hood
  /// are also a no-op unless [NoctermTimeline.metricsEnabled]
  /// is on (the profiler flips that during [start]).
  T timed<T>(String section, T Function() body) {
    if (!_recording) return body();
    _timelineHadAnyBlocks = true;
    return NoctermTimeline.timeSync(section, body);
  }

  /// Time a void synchronous block (no return value).
  /// Equivalent to `timed<void>(section, body)`.
  void timedVoid(String section, void Function() body) {
    timed<void>(section, body);
  }

  /// Begin recording. Captures the [FrameTiming] for every
  /// frame the scheduler reports from this point on, plus a
  /// post-frame snapshot of active features. Idempotent: a
  /// second call while already recording is a no-op (so
  /// `/d-profiler 10` followed quickly by another `/d-profiler
  /// 10` doesn't restart and lose data).
  ///
  /// Also enables [NoctermTimeline.metricsEnabled] for the
  /// duration of the recording so any
  /// [FrameProfiler.timed] calls (or framework-internal
  /// timeline usage) get aggregated into the report. Both
  /// flags are restored on [stop].
  void start({Duration requestedDuration = Duration.zero}) {
    if (_recording) return;
    _recording = true;
    _frames.clear();
    _pendingReasons.clear();
    _timerTickCounts.clear();
    _lastFrameNumber = -1;
    _startTime = DateTime.now();
    _requestedDuration = requestedDuration;

    _frameCallback = _onFrameTiming;
    SchedulerBinding.instance.addFrameTimingCallback(_frameCallback!);

    // Enable timeline metric collection so any timed
    // sections (chat panel build, chat history build, etc.)
    // land in the next collectMetrics() call. Saved so
    // [stop] can restore the prior value.
    _prevMetricsEnabled = NoctermTimeline.metricsEnabled;
    NoctermTimeline.metricsEnabled = true;
    NoctermTimeline.resetMetrics();
    _timelineHadAnyBlocks = false;

    // Enable the per-render-object layout profiler so
    // [RenderObject.layout] starts recording per-type
    // timing. The framework checks [isActive] on every
    // layout call (single bool check when inactive), so
    // there's no steady-state cost. Reset the per-type
    // accumulators so this recording starts clean.
    NoctermLayoutProfiler.instance.setActive();
    NoctermLayoutProfiler.instance.reset();

    // Post-frame callbacks in nocterm are one-shot (the
    // binding clears its list after each frame's draw phase),
    // so we re-register a fresh one at the end of every
    // frame. The callback no-ops when not recording, so the
    // leftover registration from the last frame before
    // [stop] is harmless — it fires once more then falls
    // silent.
    _schedulePostFrameHook();
  }

  bool? _prevMetricsEnabled;

  void _schedulePostFrameHook() {
    if (!_recording) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      attachSnapshot();
      _schedulePostFrameHook();
    });
  }

  /// Stop recording. Unhooks the frame-timing callback so
  /// the profiler has no further cost (the post-frame hook
  /// is one-shot and self-disables via the recording flag).
  /// Restores the prior [NoctermTimeline.metricsEnabled]
  /// value and collects the timeline metrics accumulated
  /// during the recording into the report.
  /// Returns a serialisable report map; pair with
  /// [FrameProfiler.writeJson] to persist to disk. Safe to
  /// call when not recording (returns a small "not
  /// recording" report).
  Map<String, dynamic> stop() {
    if (!_recording) {
      return {'error': 'not recording'};
    }
    if (_frameCallback != null) {
      SchedulerBinding.instance.removeFrameTimingCallback(_frameCallback!);
      _frameCallback = null;
    }
    _recording = false;

    // Collect any timeline metrics that landed during the
    // recording and embed them in the report. The buffer is
    // reset afterwards so the next recording starts fresh.
    final sectionMetrics = _collectSectionMetrics();
    final layoutMetrics = NoctermLayoutProfiler.instance.collect();
    NoctermTimeline.metricsEnabled = _prevMetricsEnabled ?? false;
    NoctermTimeline.resetMetrics();
    // Disable the layout profiler so production builds
    // pay no cost (the [RenderObject.layout] hot path
    // short-circuits on [NoctermLayoutProfiler.isActive]).
    NoctermLayoutProfiler.instance.setInactive();

    final report = _buildReport();
    if (sectionMetrics != null) {
      report['bySection'] = sectionMetrics;
    }
    report['byLayout'] = layoutMetrics;
    return report;
  }

  /// Pull the aggregated timeline metrics out of
  /// [NoctermTimeline] and turn them into a JSON-friendly
  /// map. Returns null if no timed sections ran during the
  /// recording (so the report stays uncluttered for the
  /// common case where no code is instrumented).
  Map<String, dynamic>? _collectSectionMetrics() {
    if (!_timelineHadAnyBlocks) return null;
    final metrics = NoctermTimeline.collectMetrics();
    final out = <String, dynamic>{};
    for (final entry in metrics.aggregated.entries) {
      final b = entry.value;
      out[b.name] = {
        'count': b.count,
        'totalUs': b.totalDuration,
        'avgUs': b.averageDuration.round(),
      };
    }
    return out;
  }

  /// Tracks whether any [time]/[NoctermTimeline.startSync]
  /// call has actually fired during the current recording.
  /// Lets [stop] avoid the noisy "0 timed sections" entry
  /// when no one instrumented anything.
  bool _timelineHadAnyBlocks = false;

  /// Convenience: record for [duration], then stop and
  /// write the report to [outputPath] (or a default
  /// timestamped path under the user data dir). Returns the
  /// report and the path it was written to.
  Future<({Map<String, dynamic> report, String path})> recordFor(
    Duration duration, {
    String? outputPath,
  }) async {
    start(requestedDuration: duration);
    await Future<void>.delayed(duration);
    final report = stop();
    final path = outputPath ?? _defaultReportPath();
    await writeReport(path, report);
    return (report: report, path: path);
  }

  /// Persist a report map to [path] as TOML. Creates
  /// parent directories as needed.
  static Future<void> writeReport(
    String path,
    Map<String, dynamic> report,
  ) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    try {
      final doc = TomlAstBuilder().buildDocument(report);
      final printer = TomlPrettyPrinter();
      doc.acceptVisitor(printer);
      await file.writeAsString('${printer.toString()}\n');
    } catch (_) {
      // Fallback: write as JSON if TOML encoding fails
      // (e.g. integer keys in the profiler report).
      const encoder = JsonEncoder.withIndent('  ');
      await file.writeAsString(encoder.convert(report));
    }
  }

  /// Legacy: persist as JSON. Kept for backward compat with
  /// callers that explicitly want JSON output.
  @Deprecated('Use writeReport instead')
  static Future<void> writeJson(
    String path,
    Map<String, dynamic> report,
  ) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(encoder.convert(report));
  }

  // ─── Internals ────────────────────────────────────────────────

  void _onFrameTiming(FrameTiming timing) {
    if (!_recording) return;
    // Defensive: only record monotonically-increasing frames
    // so a clock hiccup or re-entry doesn't double-count.
    if (timing.frameNumber <= _lastFrameNumber) return;
    _lastFrameNumber = timing.frameNumber;

    _frames.add(
      _FrameRecord(
        frameNumber: timing.frameNumber,
        timestampMs: timing.timestamp.millisecondsSinceEpoch,
        buildUs: timing.buildDuration.inMicroseconds,
        layoutUs: timing.layoutDuration.inMicroseconds,
        paintUs: timing.paintDuration.inMicroseconds,
        compositingUs: timing.compositingDuration.inMicroseconds,
        totalUs: timing.totalDuration.inMicroseconds,
        activeFeatures: <String, dynamic>{},
        scheduledByReason: 'init',
        timerTickCounts: <String, int>{},
      ),
    );
  }

  /// Called from the post-frame callback. Fills in the
  /// `features`, `reason`, and `ticks` fields of the most
  /// recent frame record. If the post-frame fires before any
  /// frame-timing has been recorded (very first frame), the
  /// snapshot is dropped — it'll attach to the next frame.
  void attachSnapshot() {
    if (_frames.isEmpty) return;
    final last = _frames.last;

    final snapshot = _snapshotProvider?.call();
    if (snapshot != null) {
      last.activeFeatures.addAll(snapshot);
    }

    final reason = _pendingReasons.isEmpty
        ? 'idle'
        : _pendingReasons.join('+');

    // The timerTickCounts and pendingReasons maps are mutated
    // by mark*() between frames. Copy them onto the frame
    // record (which is otherwise immutable) so the report
    // sees a stable snapshot per frame, then clear for the
    // next frame.
    final ticks = Map<String, int>.from(_timerTickCounts);
    _frames[_frames.length - 1] = _FrameRecord(
      frameNumber: last.frameNumber,
      timestampMs: last.timestampMs,
      buildUs: last.buildUs,
      layoutUs: last.layoutUs,
      paintUs: last.paintUs,
      compositingUs: last.compositingUs,
      totalUs: last.totalUs,
      activeFeatures: last.activeFeatures,
      scheduledByReason: reason,
      timerTickCounts: ticks,
    );

    _pendingReasons.clear();
    _timerTickCounts.clear();
  }

  Map<String, dynamic> _buildReport() {
    final end = DateTime.now();
    final start = _startTime ?? end;
    final totalUs = _frames.fold<int>(0, (s, f) => s + f.totalUs);
    final buildUs = _frames.fold<int>(0, (s, f) => s + f.buildUs);
    final layoutUs = _frames.fold<int>(0, (s, f) => s + f.layoutUs);
    final paintUs = _frames.fold<int>(0, (s, f) => s + f.paintUs);
    final frameCount = _frames.length;
    final elapsed = end.difference(start);
    final observedFps = elapsed.inMicroseconds > 0 && frameCount > 0
        ? frameCount * 1e6 / elapsed.inMicroseconds
        : 0.0;

    final totals = _frames.map((f) => f.totalUs).toList()..sort();
    final builds = _frames.map((f) => f.buildUs).toList()..sort();
    final layouts = _frames.map((f) => f.layoutUs).toList()..sort();
    final paints = _frames.map((f) => f.paintUs).toList()..sort();

    int pct(List<int> sorted, double p) {
      if (sorted.isEmpty) return 0;
      final i = (sorted.length * p)
          .floor()
          .clamp(0, sorted.length - 1);
      return sorted[i];
    }

    // Group frames by the dominant reason and report
    // per-group count + average total time. This is the key
    // signal for answering "what's making frames slow"
    // without writing a huge report and grepping.
    final byReason = <String, List<int>>{};
    for (final f in _frames) {
      byReason.putIfAbsent(f.scheduledByReason, () => []).add(f.totalUs);
    }
    final reasonStats = <String, dynamic>{};
    for (final entry in byReason.entries) {
      final vals = entry.value;
      final avg = vals.isEmpty
          ? 0
          : vals.reduce((a, b) => a + b) ~/ vals.length;
      final max = vals.isEmpty
          ? 0
          : vals.reduce((a, b) => a > b ? a : b);
      reasonStats[entry.key] = {
        'count': vals.length,
        'avgTotalUs': avg,
        'maxTotalUs': max,
      };
    }

    // Per-feature breakdown: for each feature key in any
    // frame's snapshot, compute avg total time when the
    // feature was active vs inactive. Catches the case
    // where, e.g., the metrics timer being on correlates
    // with 500ms frames.
    final featureStats = <String, dynamic>{};
    if (frameCount > 0) {
      final allFeatureKeys = <String>{
        for (final f in _frames) ...f.activeFeatures.keys,
      };
      for (final key in allFeatureKeys) {
        final on = <int>[];
        final off = <int>[];
        for (final f in _frames) {
          final v = f.activeFeatures[key];
          final isOn = v is bool
              ? v
              : v is num
                  ? v != 0
                  : v != null;
          (isOn ? on : off).add(f.totalUs);
        }
        int avg(List<int> xs) =>
            xs.isEmpty ? 0 : xs.reduce((a, b) => a + b) ~/ xs.length;
        featureStats[key] = {
          'onCount': on.length,
          'offCount': off.length,
          'avgUsWhenOn': avg(on),
          'avgUsWhenOff': avg(off),
        };
      }
    }

    // Top slow frames, sorted by totalUs descending. Caps
    // at 20 to keep the report readable; the full list is
    // under `frames`.
    final byTotal = List<_FrameRecord>.from(_frames)
      ..sort((a, b) => b.totalUs.compareTo(a.totalUs));
    final topSlow = byTotal
        .take(20)
        .map(
          (f) => {
            'frame': f.frameNumber,
            'totalUs': f.totalUs,
            'buildUs': f.buildUs,
            'layoutUs': f.layoutUs,
            'paintUs': f.paintUs,
            'reason': f.scheduledByReason,
            'ticks': f.timerTickCounts,
            'features': f.activeFeatures,
          },
        )
        .toList();

    return {
      'startMs': start.millisecondsSinceEpoch,
      'endMs': end.millisecondsSinceEpoch,
      'durationMs': elapsed.inMilliseconds,
      'frameCount': frameCount,
      'observedFps': observedFps.toStringAsFixed(2),
      'totals': {
        'sumTotalUs': totalUs,
        'sumBuildUs': buildUs,
        'sumLayoutUs': layoutUs,
        'sumPaintUs': paintUs,
      },
      'percentilesUs': {
        'total': {
          'p50': pct(totals, 0.50),
          'p90': pct(totals, 0.90),
          'p99': pct(totals, 0.99),
          'max': totals.isEmpty ? 0 : totals.last,
        },
        'build': {
          'p50': pct(builds, 0.50),
          'p90': pct(builds, 0.90),
          'p99': pct(builds, 0.99),
          'max': builds.isEmpty ? 0 : builds.last,
        },
        'layout': {
          'p50': pct(layouts, 0.50),
          'p90': pct(layouts, 0.90),
          'p99': pct(layouts, 0.99),
          'max': layouts.isEmpty ? 0 : layouts.last,
        },
        'paint': {
          'p50': pct(paints, 0.50),
          'p90': pct(paints, 0.90),
          'p99': pct(paints, 0.99),
          'max': paints.isEmpty ? 0 : paints.last,
        },
      },
      'byReason': reasonStats,
      'byFeature': featureStats,
      'topSlowFrames': topSlow,
      'frames': _frames.map((f) => f.toJson()).toList(),
    };
  }

  static String _defaultReportPath() {
    final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
    return p.join(resolveUserDataDirectory(), 'profile-$ts.toml');
  }
}
