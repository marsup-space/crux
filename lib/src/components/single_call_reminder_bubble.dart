import 'package:nocterm/nocterm.dart';

import 'system_hint_bubble.dart';

/// Small inline bubble rendered when the chat service detected drift
/// toward one-call-per-round serialisation. Fires at multiples of
/// `hint_parallel_calls_single_threshold` (default 10, 20, 30, …) and
/// is shown right after the matching `tool_call` bubble in the chat
/// history so the user can see at a glance which turns were
/// non-batched.
///
/// Distinct from the *in-context* single-call hint that the chat
/// service injects into the LLM's next turn (see
/// `services/prompts/praise_parallel_tool_calls.md`). That one lives
/// only inside the wire-format request and is never shown to the
/// user; this one is a persisted, rendered UI affordance.
///
/// Visual pairing with [ParallelPraiseBubble]: both bubbles inherit
/// the default ✦ glyph and shared layout from [SystemHintBubble],
/// so they read as a pair when scanning chat history. Colour
/// carries the signal — praise is success/green, reminder is
/// warning/yellow — so the user can distinguish them at a glance
/// even when the text is truncated.
class SingleCallReminderBubble extends SystemHintBubble {
  /// Number of *consecutive* single-tool-call rounds that triggered
  /// the reminder. Matches the value of
  /// `SessionRuntimeState.consecutiveSingleToolCallRounds` at the
  /// moment the modulo gate fired (a positive multiple of the
  /// threshold, so ≥ 10 with the default).
  final int consecutiveCount;

  const SingleCallReminderBubble({
    super.key,
    required this.consecutiveCount,
  });

  @override
  SystemHintKind get kind => SystemHintKind.warning;

  @override
  String get body =>
      '$consecutiveCount consecutive single-tool-call rounds · '
      'consider batching independent reads/searches';

  @override
  Component build(BuildContext context) {
    // Defensive: the modulo gate that triggers this bubble only
    // fires when the counter is a positive multiple of the threshold,
    // so consecutiveCount is always ≥ threshold (≥ 10 with default).
    // A lower value is a misconfiguration at the call site; render
    // nothing rather than throw inside a build pass.
    if (consecutiveCount < 1) return const SizedBox.shrink();
    return super.build(context);
  }
}