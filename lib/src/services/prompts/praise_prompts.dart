/// In-context reinforcement prompts injected into the LLM's next turn to
/// encourage batching of independent tool calls.
///
/// Two complementary signals live here, both gated on the
/// `hint_parallel_calls` toggle:
///
///   1. **Praise hint** — positive reinforcement when the model emits
///      ≥2 successful tool calls in a single round. Cement the
///      behaviour so it carries forward into long sessions where the
///      model tends to forget system-prompt instructions.
///
///   2. **Single-call hint** — corrective nudge when the model has
///      serialized for too long (default: 10 consecutive
///      single-tool-call rounds). Mitigates the context-length decay
///      where the agent regresses to one call per turn.
///
/// The wire-format quirks and template rationale are documented in
/// `hint_parallel_tool_calls.md` (alongside this file). Keep the two
/// in sync if you edit either.
///
/// `{count}`, `{savings}`, and `{trip_word}` are placeholders rather
/// than Dart string interpolation so the templates can be reviewed /
/// edited as plain-text artefacts. `{trip_word}` is `round trip` or
/// `round trips` — the singular form is the dominant case (saving
/// exactly 1 round trip is the typical 2-call parallelization) and
/// `1 round trip(s)` reads awkwardly. Substitution happens in
/// [renderParallelToolCallHint] below.
library;

/// Praise template: positive reinforcement for batching.
///
/// Variant of the original `parallelToolCallPraiseTemplate`. Kept the
/// templating surface the same so the rendering helpers compose
/// cleanly; only the body text and marker label changed (praise →
/// hint) to unify the feature under one name.
const parallelToolCallHintTemplate =
    'You emitted {count} tool calls in a single turn, saving '
    '{savings} {trip_word} with the model. Nice parallelization — '
    'keep batching independent calls like this in future turns.';

/// Render the praise-hint body with the round's actual counts.
///
/// [count] is the number of *successful* tool calls the model
/// emitted in the round (parse errors and tool-level errors are
/// excluded at the call site so the hint fires on intentional
/// batching, not on confused bursts). Callers are expected to check
/// `count >= 2` before calling this.
String renderParallelToolCallHint(int count) {
  final savings = count - 1;
  return parallelToolCallHintTemplate
      .replaceAll('{count}', count.toString())
      .replaceAll('{savings}', savings.toString())
      .replaceAll('{trip_word}', savings == 1 ? 'round trip' : 'round trips');
}

// =============================================================================
// Praise-hint wire-format helpers (renamed from "Praise" to "Hint")
// =============================================================================

/// Marker tag that frames the praise as Crux system feedback rather
/// than the tool's actual output. Exposed as a constant so tests and
/// the `chat_service` injection site use the same tag — any rename
/// has to be made in exactly one place.
///
/// Renamed from `parallelPraiseEmbeddedMarker`. The literal text also
/// changed from `…parallel-tool-call praise` to `…parallel-tool-call
/// hint` to match the unified feature name.
const parallelHintEmbeddedMarker = '[Crux system note — parallel-tool-call hint]';

/// Render the praise-hint wrapped in the embedded marker, ready to
/// be appended to a tool's `content` field.
///
/// We deliberately inject the hint into the *last* tool's output
/// rather than as a separate `user` message or a sibling `text`
/// block. Both alternatives mislead the LLM into thinking the
/// human just spoke (or, in Anthropic's case, that the user turn
/// contains more than tool results). Appending to a tool's content
/// keeps the message stream unambiguous: every `tool` /
/// `tool_result` still says "this came from a tool", and the hint
/// is clearly a trailing system note inside one of them.
///
/// The marker is a visible tag the LLM can pattern-match; the
/// leading/trailing blank lines give the model a clean boundary to
/// split the tool's real output from the injected note.
String renderParallelToolCallHintEmbedded(int count) {
  final body = renderParallelToolCallHint(count);
  return '\n\n$parallelHintEmbeddedMarker\n$body\n';
}

/// Append the embedded praise-hint to the *last* tool result in the
/// accumulated wire-format message list.
///
/// This is the wire-format "injection" — pure and side-effect-only
/// on the passed-in list, so the chat_service can call it without
/// ceremony and so tests can drive it directly without standing up
/// a full session.
///
/// [apiMessages] is the running wire-format list (OpenAI: each
/// tool result is its own `{role: 'tool', ...}` map; Anthropic:
/// the last `user` message's `content` is a list of tool_result
/// blocks). The function mutates the last tool result's `content`
/// field in place.
///
/// Crucially, this function does *not* push a new message onto the
/// list, and does *not* add a sibling block. Tests pin this
/// contract so any regression to "insert a user message" or "add a
/// text block" trips the suite immediately.
void injectParallelToolCallHintIntoLastTool(
  List<dynamic> apiMessages, {
  required bool isAnthropic,
  required int count,
}) {
  if (apiMessages.isEmpty) return;
  final hintAppend = renderParallelToolCallHintEmbedded(count);

  if (isAnthropic) {
    // The last message is the post-tool-round `user` message; its
    // `content` is a list of `tool_result` blocks. We mutate the
    // last block's `content` field in place.
    final lastMessage = apiMessages.last as Map<String, dynamic>;
    final blocks = lastMessage['content'] as List<dynamic>;
    if (blocks.isEmpty) return;
    final lastBlock = blocks.last as Map<String, dynamic>;
    final existing = lastBlock['content'];
    lastBlock['content'] = existing is String
        ? '$existing$hintAppend'
        : hintAppend;
  } else {
    // OpenAI: the last entry of `apiMessages` is the most recent
    // `role: 'tool'` message. We append the hint to its `content`
    // string in place.
    final lastToolMessage = apiMessages.last as Map<String, dynamic>;
    final existing = lastToolMessage['content'];
    lastToolMessage['content'] = existing is String
        ? '$existing$hintAppend'
        : hintAppend;
  }
}

// =============================================================================
// Single-call-hint: corrective nudge after drift
// =============================================================================

/// Marker tag for the corrective single-call nudge. Distinct from
/// the praise marker so the LLM can pattern-match which signal it's
/// seeing. Praise fires on batching (≥2 calls); this fires after the
/// model has serialized for too long (default 10 rounds in a row).
const parallelSingleCallHintEmbeddedMarker =
    '[Crux system note — single-tool-call hint]';

/// Template for the corrective single-call hint.
///
/// Distinct from the praise template in two ways:
///
///   1. The opening sentence is a *factual observation* about the
///      recent behaviour ("you emitted N consecutive single-tool-
///      call rounds"), not a compliment — the goal is to make the
///      drift visible, not to score it.
///   2. The follow-up is a *suggestion* framed conditionally ("if
///      those calls were independent, batching would have saved
///      round trips"). We don't accuse the model of being wrong,
///      because some tool calls genuinely have ordering dependencies
///      — the nudge asks it to consider whether its recent calls did.
///
/// `{count}` is the consecutive single-tool-call round count (e.g.
/// 10 with the default threshold; 20 if the model kept serializing
/// past the first nudge).
const parallelSingleCallHintTemplate =
    'You have emitted {count} consecutive single-tool-call rounds in a row. '
    'If those calls were independent, batching them into a single turn '
    'would have saved round trips with the model. Consider bundling '
    'independent reads, searches, and other queries going forward.';

/// Render the single-call hint body with the consecutive-round count.
String renderParallelSingleCallHint(int consecutiveCount) {
  return parallelSingleCallHintTemplate.replaceAll(
    '{count}',
    consecutiveCount.toString(),
  );
}

/// Render the single-call hint wrapped in the embedded marker, ready
/// to be appended to a tool's `content` field.
///
/// Same wire-format choice as the praise hint: appended to the last
/// tool's `content` (rather than a sibling `text` block or new `user`
/// message) so the message stream stays unambiguous — every `tool`
/// result still says "this came from a tool", and the hint is
/// clearly a trailing system note.
String renderParallelSingleCallHintEmbedded(int consecutiveCount) {
  final body = renderParallelSingleCallHint(consecutiveCount);
  return '\n\n$parallelSingleCallHintEmbeddedMarker\n$body\n';
}

/// Append the embedded single-call hint to the *last* tool result in
/// the accumulated wire-format message list. Mirrors
/// [injectParallelToolCallHintIntoLastTool] exactly, except the body
/// is the corrective nudge and the marker is
/// [parallelSingleCallHintEmbeddedMarker]. The same no-new-message,
/// no-sibling-block contract applies.
void injectParallelSingleCallHintIntoLastTool(
  List<dynamic> apiMessages, {
  required bool isAnthropic,
  required int consecutiveCount,
}) {
  if (apiMessages.isEmpty) return;
  final hintAppend = renderParallelSingleCallHintEmbedded(consecutiveCount);

  if (isAnthropic) {
    final lastMessage = apiMessages.last as Map<String, dynamic>;
    final blocks = lastMessage['content'] as List<dynamic>;
    if (blocks.isEmpty) return;
    final lastBlock = blocks.last as Map<String, dynamic>;
    final existing = lastBlock['content'];
    lastBlock['content'] = existing is String
        ? '$existing$hintAppend'
        : hintAppend;
  } else {
    final lastToolMessage = apiMessages.last as Map<String, dynamic>;
    final existing = lastToolMessage['content'];
    lastToolMessage['content'] = existing is String
        ? '$existing$hintAppend'
        : hintAppend;
  }
}

// =============================================================================
// User-facing bubble label (unchanged surface)
// =============================================================================

/// Short, user-facing label for the `parallel_praise` bubble
/// rendered in the TUI. This is *not* sent to the LLM — it's the
/// one-liner the user sees scrolling past in the chat history,
/// telling them "that round batched N tool calls in one turn".
///
/// Kept here (next to the in-context template) so the two stay
/// conceptually paired: when one changes the other usually should.
///
/// The DB role `parallel_praise` is also unchanged — renaming it
/// would require a migration. The user-visible text is what matters
/// for the rename, and that's already neutral ("N tool calls
/// parallelized").
String renderParallelPraiseBubbleLabel(int successfulCount) {
  final savings = successfulCount - 1;
  final tripWord = savings == 1 ? 'round trip' : 'round trips';
  return '$successfulCount tool calls parallelized · '
      'saving $savings $tripWord';
}

/// Short, user-facing label for the `single_call_reminder` bubble
/// rendered in the TUI. This is *not* sent to the LLM — it's the
/// one-liner the user sees scrolling past in the chat history,
/// telling them the agent has been serialising for a while and the
/// in-context reminder has just been injected into the next turn.
///
/// Counterpart to [renderParallelPraiseBubbleLabel]: same shape,
/// different role, opposite sentiment. The two stay paired visually
/// so users can scan chat history and tell at a glance which rounds
/// batched well (praise, green) and which drifted toward
/// serialisation (reminder, warning yellow).
///
/// [consecutiveCount] is the value of
/// `SessionRuntimeState.consecutiveSingleToolCallRounds` at the
/// moment the modulo gate fired — a positive multiple of the
/// configured threshold (10, 20, 30, … by default).
String renderSingleCallReminderBubbleLabel(int consecutiveCount) {
  return '$consecutiveCount consecutive single-tool-call rounds · '
      'consider batching independent reads/searches';
}