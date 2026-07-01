/// One-shot nudge to use `semantic_search` instead of `grep`/`glob`.
///
/// Appended to the FIRST `grep` or `glob` tool result in each
/// session. The hint teaches the LLM that `semantic_search` is the
/// preferred surface for "how does X work" / "find code that does
/// X" questions — it finds code by CONCEPT, not exact regex
/// match, and returns ranked snippets in one call instead of the
/// grep+read dance.
///
/// Only fires once per session (in-memory, never resets within a
/// chat; effectively resets when the user starts a new chat).
/// State lives on [SessionRuntimeState.hasShownSemanticSearchHint] —
/// set to `true` by the chat service after the first grep/glob
/// tool call succeeds.
///
/// Companion to the [ShellGuardKind.semanticSearch] verdict in
/// `lib/src/tools/shell_guard.dart`:
///   * **semantic_search hint (this file)** — fires when the LLM uses
///     `grep` or `glob` directly as a tool, regardless of bash
///     usage. Teaches the LLM that `semantic_search` exists and is
///     preferred for conceptual questions.
///   * **shell-tool fallback semantic_search verdict** — fires when
///     the LLM uses `rg … | head` style bash pipelines instead of
///     `semantic_search`. Catches the bash+cat/sed/rg fallback
///     pattern specifically.
///
/// Both nudges reinforce the same lesson from different angles.
library;

// =============================================================================
// Marker + wire-format helpers
// =============================================================================

/// Marker tag that frames the reminder as Crux system feedback
/// rather than the tool's actual output. The bracket prefix
/// (`[Crux system note — …]`) matches the parallel-tool-call
/// hint, single-tool-call hint, and shell-tool fallback marker
/// styles — the LLM pattern-matches the intent from the tag
/// alone, with no separate body inspection needed.
const semanticSearchHintMarker =
    '[Crux system note — prefer semantic_search]';

/// Render the semantic_search preference hint wrapped in the
/// embedded marker, ready to be appended to a grep/glob tool's
/// `output`.
///
/// Shape mirrors the other embedded hints in
/// `praise_prompts.dart` and `shell_guard.dart`: leading `\n\n`
/// for a clean boundary, marker line, body, trailing `\n`.
///
/// [SessionRuntimeState.hasShownSemanticSearchHint] gates whether
/// the chat service actually calls this — this function is pure
/// and always returns the same string when called.
String renderSemanticSearchHintEmbedded() {
  return '\n\n$semanticSearchHintMarker\n'
      'For "how does X work" / "find code that does X" questions, '
      'prefer `semantic_search` (semantic search) over `grep` + `read` '
      'loops.\n'
      '\n'
      '`semantic_search` finds code by CONCEPT, not exact regex match — '
      'a single call returns ranked snippets in ~600ms instead of '
      'the bash+rg+read dance.\n'
      '\n'
      'Reserve `grep` for exact symbol lookups ("where is '
      '`OAuthHandler` defined") and `glob` for known file '
      'patterns ("find all `*_test.dart`").\n';
}

// =============================================================================
// Context-size threshold re-fires
// =============================================================================

/// Context-size thresholds (in tokens) at which the
/// `semantic_search` preference hint re-fires in long sessions.
///
/// After the initial one-shot (fired on the very first grep/glob
/// in the session), the hint re-fires on the FIRST grep/glob
/// after the LLM's context crosses each threshold. The re-fire
/// refreshes the LLM's memory of the preference in long sessions
/// where the original nudge might have fallen out of the recent
/// context window.
///
/// Values match common Anthropic/OpenAI context windows (200k
/// for Claude 3+, 400k for Claude Sonnet 4.5+, 600k for
/// near-future models). The list is ordered ascending; the
/// threshold-firing helper auto-discovers the next unsatisfied
/// threshold per round.
const semanticSearchHintContextThresholds = <int>[200000, 400000, 600000];

/// Find the next context-size threshold to fire at, given the
/// current context size (in tokens) and the last threshold that
/// already fired.
///
/// Iterates [semanticSearchHintContextThresholds] in ascending
/// order and returns the smallest threshold `T` such that
/// `currentContext >= T` AND `T > lastFiredThreshold`. Returns
/// `null` if no threshold has been crossed since the last fire
/// (the helper is the signal that the chat service should append
/// the hint to the next grep/glob tool result).
///
/// Multi-threshold crossings in one round (e.g. context jumps
/// 100k → 600k because the user pasted a long message): only
/// the lowest unsatisfied threshold fires per round. Subsequent
/// rounds cover the higher ones as long as the threshold still
/// satisfies `T > lastFiredThreshold`.
///
/// Examples (thresholds = 200k, 400k, 600k):
///
///   * `currentContext=100k, lastFired=0`     → `null` (no fire —
///     initial one-shot handles this — or the hint already fired
///     and we're below the first threshold)
///   * `currentContext=250k, lastFired=0`     → `200k` (first
///     threshold crossed, never fired)
///   * `currentContext=600k, lastFired=0`     → `200k` (the
///     lowest unsatisfied threshold; subsequent rounds handle
///     400k and 600k)
///   * `currentContext=450k, lastFired=200k`  → `400k`
///   * `currentContext=900k, lastFired=600k`  → `null` (no more
///     thresholds configured above 600k)
int? nextSemanticSearchHintThreshold(
  int currentContext,
  int lastFiredThreshold,
) {
  for (final t in semanticSearchHintContextThresholds) {
    if (currentContext >= t && t > lastFiredThreshold) {
      return t;
    }
  }
  return null;
}
