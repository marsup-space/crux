import 'package:nocterm/nocterm.dart';
import '../theme/crux_theme.dart';

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
class ParallelPraiseBubble extends StatelessComponent {
  /// Number of *successful* tool calls the model emitted in the
  /// round. Parse errors and tool-level errors are excluded at the
  /// persist site so this number reflects intentional batching.
  final int successfulCount;

  /// Optional intent field (currently unused but reserved so the
  /// message-store row can carry richer metadata later — e.g. which
  /// tool names were involved).
  const ParallelPraiseBubble({super.key, required this.successfulCount});

  @override
  Component build(BuildContext context) {
    // Defensive: a bubble with <2 calls is a misconfiguration at
    // the call site, but rendering nothing is the safest fallback
    // rather than throwing inside a build pass.
    if (successfulCount < 2) return const SizedBox.shrink();

    final theme = CruxTheme.of(context);
    final savings = successfulCount - 1;
    final body =
        'parallelized $successfulCount tool calls in a single turn · '
        'saved $savings round trip${savings == 1 ? '' : 's'}';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ' ⚡ ',
            style: TextStyle(
              color: theme.successColor,
              fontWeight: FontWeight.bold,
            ),
          ),
          Expanded(
            child: Text(
              body,
              style: TextStyle(color: theme.successColor),
            ),
          ),
        ],
      ),
    );
  }
}
