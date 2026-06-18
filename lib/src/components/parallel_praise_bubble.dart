import 'package:nocterm/nocterm.dart';

import 'system_hint_bubble.dart';

/// Small inline bubble rendered when a chat round had ≥2 successful
/// tool calls in a single LLM turn. Shown right after the matching
/// `tool_call` bubble in the chat history so the user can see at a
/// glance which turns were batched.
///
/// Distinct from the *in-context* praise that the chat service injects
/// into the LLM's next turn (see
/// `services/prompts/praise_parallel_tool_calls.md`). That one lives
/// only inside the wire-format request and is never shown to the
/// user; this one is a persisted, rendered UI affordance.
///
/// Inherits the shared glyph + body + colour layout from
/// [SystemHintBubble]; this class only supplies the success-kind
/// colour, the body text formatter, and the data-validity guard.
class ParallelPraiseBubble extends SystemHintBubble {
  /// Number of *successful* tool calls the model emitted in the
  /// round. Parse errors and tool-level errors are excluded at the
  /// persist site so this number reflects intentional batching.
  final int successfulCount;

  const ParallelPraiseBubble({super.key, required this.successfulCount});

  @override
  SystemHintKind get kind => SystemHintKind.success;

  @override
  String get body {
    final savings = successfulCount - 1;
    return 'parallelized $successfulCount tool calls in a single turn · '
        'saved $savings round trip${savings == 1 ? '' : 's'}';
  }

  @override
  Component build(BuildContext context) {
    // Defensive: a bubble with <2 calls is a misconfiguration at
    // the call site (the gate that produces this bubble only fires
    // on ≥2 successful calls). Render nothing rather than throw
    // inside a build pass.
    if (successfulCount < 2) return const SizedBox.shrink();
    return super.build(context);
  }
}