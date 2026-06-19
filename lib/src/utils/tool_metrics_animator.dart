import 'package:nocterm/nocterm.dart';

import 'partial_json_field_extractor.dart';

/// A `+M -K lines` line-delta extracted from a tool call's input
/// payload. Both fields are nullable because the source may not
/// carry a line count for the relevant argument (e.g. `read`,
/// `bash` or `grep` results don't have a meaningful add/remove
/// diff). A null value means "don't render a part" rather than
/// "the part is zero" — the formatter distinguishes the two.
class ToolMetricsLineDelta {
  final int? addedLines;
  final int? removedLines;

  const ToolMetricsLineDelta({this.addedLines, this.removedLines});
}

/// Extract a [ToolMetricsLineDelta] from a possibly-partial JSON
/// payload, the way the LLM streams it during a round. This is
/// what powers the `+M lines` / `-K lines` preview in the live
/// streaming bubble: the close braces of the input haven't
/// arrived yet, so we can't `jsonDecode` the buffer.
///
/// Only `write` and `edit` have a meaningful add/remove diff in
/// their streamed arguments. Every other tool returns the
/// all-null default, which the formatter renders as just
/// `~N t`.
ToolMetricsLineDelta toolMetricsLineDeltaFromPartialJson({
  required String toolName,
  required String partialJson,
}) {
  // `lenient: true` so the streaming preview shows an
  // under-counted `+5 lines` while the LLM is still emitting
  // the field, instead of waiting for the closing quote. The
  // underlying field extractor is the same one
  // `chat_service.dart` uses for the streaming guard (with
  // `lenient: false` there) — see `partial_json_field_extractor.dart`.
  if (toolName == 'write') {
    final content = PartialJsonFieldExtractor.extractStringField(
      partialJson,
      'content',
      lenient: true,
    );
    return ToolMetricsLineDelta(addedLines: _lineCount(content));
  }
  if (toolName == 'edit') {
    final oldString = PartialJsonFieldExtractor.extractStringField(
      partialJson,
      'oldString',
      lenient: true,
    );
    final newString = PartialJsonFieldExtractor.extractStringField(
      partialJson,
      'newString',
      lenient: true,
    );
    return ToolMetricsLineDelta(
      addedLines: _lineCount(newString),
      removedLines: _lineCount(oldString),
    );
  }
  return const ToolMetricsLineDelta();
}

int? _lineCount(String? value) {
  if (value == null) return null;
  if (value.isEmpty) return 0;
  return '\n'.allMatches(value).length + 1;
}

/// Per-call animated display state. Owns a "current" and
/// "target" value for tokens + added lines + removed lines and
/// advances the current values toward the target at a constant
/// exponential rate (`current += (target - current) * t` where
/// `t = elapsedSeconds * lerpPerSecond`, clamped to 1.0).
///
/// The target is set via [setTarget] (call this when the
/// underlying value changes — e.g. the LLM streamed more input
/// JSON, or the tool result landed). The display is advanced via
/// [advance] on each per-frame tick. The widget that owns the
/// [ToolMetricsAnimator] calls [advance] then [format] (or
/// [displayTokens] / [displayAddedLines] / [displayRemovedLines])
/// to read the current frame's values.
///
/// Once the displayed values match the targets within a small
/// epsilon, the animator stops calling [advance] (see
/// [isSettled]) so the per-frame scheduler can be torn down
/// until the next target change.
class AnimatedToolMetrics {
  double displayTokens = 0;
  double targetTokens = 0;
  double displayAddedLines = 0;
  double? targetAddedLines;
  double displayRemovedLines = 0;
  double? targetRemovedLines;

  /// Update the target values. Returns `true` if any of the
  /// targets changed (the caller uses this to decide whether
  /// to restart the per-frame scheduler).
  bool setTarget({
    required int tokens,
    required int? addedLines,
    required int? removedLines,
  }) {
    var changed = false;
    if (targetTokens != tokens) {
      targetTokens = tokens.toDouble();
      changed = true;
    }
    final added = addedLines?.toDouble();
    if (targetAddedLines != added) {
      targetAddedLines = added;
      changed = true;
    }
    final removed = removedLines?.toDouble();
    if (targetRemovedLines != removed) {
      targetRemovedLines = removed;
      changed = true;
    }
    return changed;
  }

  /// Advance the displayed values toward the targets by [elapsed]
  /// of wall-clock time. Returns `true` if any displayed value
  /// changed (the caller uses this to decide whether to rebuild
  /// the widget). See [isSettled] for the "done" check.
  bool advance(Duration elapsed, double lerpPerSecond) {
    final seconds = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    final t = (seconds * lerpPerSecond).clamp(0.0, 1.0);
    var changed = false;
    (double, bool) step(double current, double target) {
      final next = current + (target - current) * t;
      if ((next - target).abs() < 0.05) {
        return (target, current != target);
      }
      return (next, (next - current).abs() >= 0.01);
    }

    final tokenStep = step(displayTokens, targetTokens);
    displayTokens = tokenStep.$1;
    changed = tokenStep.$2 || changed;

    final addedTarget = targetAddedLines;
    if (addedTarget != null) {
      final addedStep = step(displayAddedLines, addedTarget);
      displayAddedLines = addedStep.$1;
      changed = addedStep.$2 || changed;
    } else if (displayAddedLines != 0) {
      displayAddedLines = 0;
      changed = true;
    }

    final removedTarget = targetRemovedLines;
    if (removedTarget != null) {
      final removedStep = step(displayRemovedLines, removedTarget);
      displayRemovedLines = removedStep.$1;
      changed = removedStep.$2 || changed;
    } else if (displayRemovedLines != 0) {
      displayRemovedLines = 0;
      changed = true;
    }

    return changed;
  }

  /// Whether every tracked value has reached its target. The
  /// per-frame scheduler can stop calling [advance] once this
  /// is true on every entry in the animator's map.
  bool get isSettled {
    if ((displayTokens - targetTokens).abs() >= 0.05) return false;
    final addedTarget = targetAddedLines;
    if (addedTarget != null &&
        (displayAddedLines - addedTarget).abs() >= 0.05) {
      return false;
    } else if (addedTarget == null && displayAddedLines != 0) {
      return false;
    }
    final removedTarget = targetRemovedLines;
    if (removedTarget != null &&
        (displayRemovedLines - removedTarget).abs() >= 0.05) {
      return false;
    } else if (removedTarget == null && displayRemovedLines != 0) {
      return false;
    }
    return true;
  }
}

/// Format the current displayed metrics as a leading-dot
/// segment suitable for appending after a tool name + label,
/// e.g. ` · ~350 t · +12 lines · -3 lines`. Returns ` · ~0 t`
/// when [metrics] is null, so the first frame after a target
/// change still reads sensibly.
///
/// `· ` (middot + space) matches the separator the streaming
/// bubble has used since the first version; preserving it here
/// means swapping the post-call row to the same animation
/// doesn't visibly change the surrounding prefix.
String formatToolMetrics(AnimatedToolMetrics? metrics) {
  if (metrics == null) return ' · ~0 t';
  final parts = <String>['~${metrics.displayTokens.round()} t'];
  if (metrics.targetAddedLines != null) {
    parts.add('+${metrics.displayAddedLines.round()} lines');
  }
  if (metrics.targetRemovedLines != null && metrics.displayRemovedLines > 0.4) {
    parts.add('-${metrics.displayRemovedLines.round()} lines');
  }
  return ' · ${parts.join(' ')}';
}

/// Just the `~N t` half of [formatToolMetrics], with no leading
/// dot and no line-delta parts. The collapsed post-call row
/// already gets the `+M -N lines` half from the tool's
/// `collapsedSummary.text` (e.g. `"+12 -3 lines, 420B"`), so
/// the animated value the row wants to surface is just the
/// token count. Pairing this with the static summary text
/// keeps the post-call row's visual format identical to the
/// pre-refactor version while making the `N` lerp from 0 →
/// final when the result lands.
String formatToolMetricsToken(AnimatedToolMetrics? metrics) {
  if (metrics == null) return '~0 t';
  return '~${metrics.displayTokens.round()} t';
}

/// Strip the trailing `(~Nt)` token suffix that
/// [ToolDef.streamingLabel] emits, so a streaming preview label
/// can be re-suffixed with the live-animated [formatToolMetrics]
/// string without showing two token counts.
String stripToolTokenSuffix(String label) {
  return label.replaceFirst(RegExp(r'\s*\(~\d+\s*t\)\s*$'), '').trimRight();
}

/// Owns the per-frame scheduler + per-callId
/// [AnimatedToolMetrics] map for one tool-call display (e.g. one
/// streaming bubble, one collapsed chat row, or one tool-detail
/// pane header).
///
/// Most consumers can use the default auto-driven mode: call
/// [setTarget] when the underlying value changes, [dispose] from
/// the widget's `State.dispose`. The animator starts a 16ms
/// scheduler on the first target change, fires [onAdvance] on
/// every frame it advances a value, and self-pauses when every
/// tracked metric is settled. The owning widget's State listens
/// to [onAdvance] and calls setState.
///
/// Consumers that already have a 16ms scheduler driving their
/// own work (the streaming bubble polls its
/// [StreamingController] for content too — not just metrics) can
/// pass [driveManually] `true`: `setTarget` still updates the
/// target, but the animator does not start its own scheduler.
/// The consumer calls [advance] from its own tick and the
/// per-callId values advance in lock-step with the rest of the
/// bubble's rebuild logic.
class ToolMetricsAnimator {
  /// Per-callId animated state. We key by the LLM-emitted callId
  /// (or `index:name` for in-flight calls where callId hasn't
  /// landed yet) so two parallel calls in the same round don't
  /// stomp on each other.
  final Map<String, AnimatedToolMetrics> metrics = {};

  final String tickerName;
  final double lerpPerSecond;
  final bool driveManually;
  SchedulerHandle? _handle;
  void Function()? _onAdvance;

  ToolMetricsAnimator({
    this.tickerName = 'toolMetrics',
    this.lerpPerSecond = 12.0,
    this.driveManually = false,
  });

  /// Hook fired every frame the animator advances at least one
  /// tracked value. Wire this to the owning widget's setState
  /// in auto-driven mode. Ignored in manually-driven mode.
  set onAdvance(void Function()? cb) => _onAdvance = cb;

  /// Update the target for [callId]. In auto-driven mode this
  /// also starts the per-frame scheduler if it isn't already
  /// running. In manually-driven mode the caller is expected
  /// to call [advance] from its own scheduler.
  ///
  /// Returns `true` if the target actually changed (callers can
  /// use this to decide whether the widget needs a rebuild —
  /// though most callers setState unconditionally on every
  /// chunk).
  bool setTarget(
    String callId, {
    required int tokens,
    int? addedLines,
    int? removedLines,
  }) {
    final m = metrics.putIfAbsent(callId, AnimatedToolMetrics.new);
    final changed = m.setTarget(
      tokens: tokens,
      addedLines: addedLines,
      removedLines: removedLines,
    );
    if (changed && !driveManually) _ensureRunning();
    return changed;
  }

  /// Remove a callId from the map (e.g. when the bubble's
  /// round ends and the row goes away). If the map is empty
  /// afterwards, the per-frame scheduler is cancelled.
  void forget(String callId) {
    if (metrics.remove(callId) != null && metrics.isEmpty) {
      _stop();
    }
  }

  /// Read the current displayed value for [callId]. Returns
  /// `null` if no target has been set yet — the caller should
  /// fall back to a placeholder in that case.
  AnimatedToolMetrics? read(String callId) => metrics[callId];

  /// `~N t · +M lines · -K lines` formatting for the current
  /// frame of [callId]. See [formatToolMetrics].
  String format(String callId) => formatToolMetrics(metrics[callId]);

  /// Advance every tracked metric by [elapsed]. Called by the
  /// owning widget's own scheduler in manually-driven mode.
  /// Returns `true` if any value changed.
  bool advance(Duration elapsed) {
    var anyChanged = false;
    var anyUnsettled = false;
    for (final m in metrics.values) {
      if (m.advance(elapsed, lerpPerSecond)) anyChanged = true;
      if (!m.isSettled) anyUnsettled = true;
    }
    if (!anyUnsettled) _stop();
    return anyChanged;
  }

  void _ensureRunning() {
    if (_handle != null) return;
    _handle = NoctermScheduler.instance.every(
      const Duration(milliseconds: 16),
      (tick) {
        if (_handle == null) return;
        if (advance(tick.delta)) {
          _onAdvance?.call();
        }
      },
      owner: this,
      name: tickerName,
      priority: SchedulePriority.animation,
    );
  }

  void _stop() {
    _handle?.cancel();
    _handle = null;
  }

  bool get isRunning => _handle?.isActive ?? false;

  void dispose() {
    _stop();
    metrics.clear();
    _onAdvance = null;
  }
}
