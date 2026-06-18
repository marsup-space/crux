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
//
// The hint fires at multiples of `hint_parallel_calls_single_threshold`
// (default 10, 20, 30, …). Each fire escalates in two ways:
//
//   1. **Wording** — three severity tiers (mild / firm / urgent) so
//      the message stays informative at round 10, direct at round 20,
//      and unambiguous at round 30+.
//
//   2. **Wire format** — mild and firm tiers append the hint inside
//      the last tool's `content` field (the same place as the praise
//      hint), framed with a tier-specific marker so the LLM can
//      pattern-match the severity. The urgent tier (round 30+) breaks
//      out of the tool-result and injects a fresh `user`-role message
//      instead, so the hint is impossible to miss — the prior two
//      tiers must not have landed, hence the escalation.
//
// The split reflects the design principle that milder hints are
// meta-information about the round ("by the way, you serialised")
// while urgent hints are a corrective interruption ("stop, fix your
// behaviour"). The LLM treats a `user` message after a tool-result
// block as a clear pivot point in the conversation.
// =============================================================================

/// Severity tier for the single-call reminder. Escalates with each
/// multiple of the configured threshold; rounds 10/20/30 by default.
///
/// Picking a tier drives three things:
///   * the body template (mild/firm/urgent wording),
///   * the wire format (tool-result append vs. user-role message),
///   * the marker tag the LLM pattern-matches.
enum SingleCallHintSeverity { mild, firm, urgent }

/// Map a consecutive single-call round count to its severity tier.
///
/// Tier boundaries (with the default threshold of 10):
///   * `count == threshold`         → [SingleCallHintSeverity.mild]
///   * `count == 2 * threshold`     → [SingleCallHintSeverity.firm]
///   * `count >= 3 * threshold`     → [SingleCallHintSeverity.urgent]
///
/// A threshold of 0 (TOML explicit `hint_parallel_calls_single_threshold
/// = 0`) is treated defensively as mild — the modulo gate itself
/// collapses to "always fire" but the tier formula would otherwise
/// divide by zero.
SingleCallHintSeverity singleCallHintSeverityFor(
  int consecutiveCount, {
  int threshold = 10,
}) {
  if (threshold <= 0) return SingleCallHintSeverity.mild;
  final tier = consecutiveCount ~/ threshold;
  if (tier <= 1) return SingleCallHintSeverity.mild;
  if (tier == 2) return SingleCallHintSeverity.firm;
  return SingleCallHintSeverity.urgent;
}

/// Marker tag for the corrective single-call nudge. Tier-specific
/// so the LLM can pattern-match both the *kind* of reminder and
/// its severity from the bracket tag alone.
///
///   * mild   → "[Crux system note — single-tool-call hint]"
///   * firm   → "[Crux system note — single-tool-call hint — firm]"
///   * urgent → "[Crux system note — single-tool-call hint — urgent]"
///
/// Distinct from the praise marker so the model can tell which
/// signal it's seeing in the first place; the tier suffix lets it
/// tell escalation apart at a glance.
String parallelSingleCallHintMarker(SingleCallHintSeverity severity) {
  switch (severity) {
    case SingleCallHintSeverity.mild:
      return '[Crux system note — single-tool-call hint]';
    case SingleCallHintSeverity.firm:
      return '[Crux system note — single-tool-call hint — firm]';
    case SingleCallHintSeverity.urgent:
      return '[Crux system note — single-tool-call hint — urgent]';
  }
}

// ---- Tiered body templates ----------------------------------------------
//
// Three templates, one per severity. `{count}` is substituted at
// render time. All three use "parallel tool calls" terminology
// (matching the parallel-praise hint) so the LLM sees one consistent
// vocabulary across both signals.
//
//   * **mild** is an observation + soft suggestion. Asks the model
//     to consider whether its recent calls were independent —
//     doesn't accuse it of being wrong because some tool calls
//     genuinely have ordering dependencies.
//
//   * **firm** drops the conditional framing ("if those calls were
//     independent") — by round 20 it's overwhelmingly likely they
//     were. Names the pattern ("serialisation drift") and tells the
//     model to batch the independent ones going forward.
//
//   * **urgent** is an imperative. The two prior tiers evidently
//     didn't land, so this one spells out the cost (round trips
//     wasted) and the corrective action ("MUST be issued as parallel
//     tool calls") without hedging. Paired with the user-role wire
//     format (see [injectParallelSingleCallHintAsUserMessage]) so
//     the LLM cannot miss it.

const parallelSingleCallHintMildTemplate =
    'You have emitted {count} consecutive single-tool-call rounds. '
    'If those tool calls were independent, issuing them as parallel tool '
    'calls in a single turn would have saved round trips with the model. '
    'Going forward, consolidate independent reads, searches, and other '
    'read-only queries into parallel tool calls per turn.';

const parallelSingleCallHintFirmTemplate =
    'You have emitted {count} consecutive single-tool-call rounds — '
    'a clear serialisation drift pattern. Independent reads and searches '
    'should be issued as parallel tool calls in a single turn. Going '
    'forward, batch the independent ones into parallel tool calls and '
    'only serialise when an explicit ordering dependency exists.';

const parallelSingleCallHintUrgentTemplate =
    'You have emitted {count} consecutive single-tool-call rounds — '
    'severe serialisation drift. The previous, milder reminders '
    '(appended to tool results) evidently did not adjust your behaviour. '
    'Independent reads and searches MUST be issued as parallel tool calls '
    'in a single turn; do not serialise them unless an explicit ordering '
    'dependency exists. Every additional single-tool-call round wastes '
    'a round trip with the model. Switch to parallel tool calls now.';

/// Render the single-call hint body for the tier matching
/// [consecutiveCount]. Pure string substitution — no wire-format
/// concerns live here. The two helpers
/// [renderParallelSingleCallHintEmbedded] and
/// [renderParallelSingleCallHintUserMessage] wrap the body with the
/// tier-specific marker and choose the wire format.
String renderParallelSingleCallHint(
  int consecutiveCount, {
  int threshold = 10,
}) {
  final severity = singleCallHintSeverityFor(
    consecutiveCount,
    threshold: threshold,
  );
  final template = switch (severity) {
    SingleCallHintSeverity.mild => parallelSingleCallHintMildTemplate,
    SingleCallHintSeverity.firm => parallelSingleCallHintFirmTemplate,
    SingleCallHintSeverity.urgent => parallelSingleCallHintUrgentTemplate,
  };
  return template.replaceAll('{count}', consecutiveCount.toString());
}

/// Render the single-call hint wrapped in the embedded marker, ready
/// to be appended to a tool's `content` field.
///
/// Used by the mild and firm tiers. The urgent tier does NOT use
/// this — see [renderParallelSingleCallHintUserMessage] for the
/// user-role wire format that breaks out of the tool-result.
String renderParallelSingleCallHintEmbedded(
  int consecutiveCount, {
  int threshold = 10,
}) {
  final severity = singleCallHintSeverityFor(
    consecutiveCount,
    threshold: threshold,
  );
  if (severity == SingleCallHintSeverity.urgent) {
    throw StateError(
      'renderParallelSingleCallHintEmbedded called for urgent tier '
      '(count=$consecutiveCount, threshold=$threshold). Urgent tier '
      'must use renderParallelSingleCallHintUserMessage + '
      'injectParallelSingleCallHintAsUserMessage — the chat service '
      'picks the right injection based on severity.',
    );
  }
  final body = renderParallelSingleCallHint(
    consecutiveCount,
    threshold: threshold,
  );
  final marker = parallelSingleCallHintMarker(severity);
  return '\n\n$marker\n$body\n';
}

/// Render the single-call hint as a standalone user-role message
/// body, ready to be added as a new `user` message in the wire format.
///
/// Used by the urgent tier only. The output is the bare hint body
/// — **no `[Crux system note — …]` marker tag**, no leading
/// `system`/`assistant` framing. The whole point of escalating to a
/// `user`-role message is for the LLM to read it as the human
/// speaking, not as Crux's own meta-commentary. A bracketed
/// `[Crux system note — …]` prefix would re-introduce the
/// "ignoreable system tag" pattern the urgent tier is designed to
/// escape — the model would be free to mentally file the message
/// alongside the other tool-result-appended hints and continue
/// serialising.
///
/// The mild and firm tiers, by contrast, ARE wrapped in a
/// `[Crux system note — single-tool-call hint]` (or `— firm`)
/// marker — because they get *appended* to a tool's `content`
/// field, the marker gives the LLM a clean boundary between the
/// tool's real output and the injected note. The urgent tier has
/// no such boundary to mark (it's its own message), so it skips
/// the framing entirely.
String renderParallelSingleCallHintUserMessage(
  int consecutiveCount, {
  int threshold = 10,
}) {
  return renderParallelSingleCallHint(
    consecutiveCount,
    threshold: threshold,
  );
}

/// Append the embedded single-call hint to the *last* tool result in
/// the accumulated wire-format message list. Mirrors
/// [injectParallelToolCallHintIntoLastTool] in shape.
///
/// Only valid for the mild and firm tiers — calling this with the
/// urgent tier throws (use
/// [injectParallelSingleCallHintAsUserMessage] instead). The chat
/// service picks the right injection based on severity; this
/// function trusts that contract and enforces it with an exception.
void injectParallelSingleCallHintIntoLastTool(
  List<dynamic> apiMessages, {
  required bool isAnthropic,
  required int consecutiveCount,
  int threshold = 10,
}) {
  if (apiMessages.isEmpty) return;
  final hintAppend = renderParallelSingleCallHintEmbedded(
    consecutiveCount,
    threshold: threshold,
  );

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

/// Inject the single-call hint as a fresh `user`-role message in
/// the accumulated wire-format message list.
///
/// Only valid for the urgent tier. The chat service picks this
/// injection when the modulo gate fires at `count >= 3 * threshold`
/// (round 30+ by default). The result is a brand-new user message
/// after the tool results, not an append to the last tool — the
/// placement is itself the escalation signal, because the prior
/// milder (tool-result-appended) tiers evidently didn't change
/// behaviour.
///
/// Wire format (note: **no `[Crux system note — …]` marker** — the
/// urgent-tier body is sent bare so the LLM reads it as a real user
/// message, not as Crux meta-commentary it can mentally file away):
///
///   * OpenAI:
///       `{'role': 'user', 'content': '{body}'}`
///   * Anthropic:
///       `{'role': 'user', 'content': [
///           {'type': 'text', 'text': '{body}'},
///         ]}`
///
/// Pushing a `user` message here intentionally breaks the
/// "no-new-message, no-sibling-block" contract that the milder
/// tiers honour. The two-tier split (mild/firm vs urgent) is the
/// reason this contract exists in the first place — see the section
/// header above for the design rationale.
void injectParallelSingleCallHintAsUserMessage(
  List<dynamic> apiMessages, {
  required bool isAnthropic,
  required int consecutiveCount,
  int threshold = 10,
}) {
  final text = renderParallelSingleCallHintUserMessage(
    consecutiveCount,
    threshold: threshold,
  );

  if (isAnthropic) {
    apiMessages.add({
      'role': 'user',
      'content': [
        {'type': 'text', 'text': text},
      ],
    });
  } else {
    apiMessages.add({
      'role': 'user',
      'content': text,
    });
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
/// Like the in-context reminder, the bubble label also has three
/// severity tiers (mild / firm / urgent), so the visible message
/// escalates with the same wording trajectory as the in-context one.
/// The bubble label is purely cosmetic for the user; the in-context
/// text is what actually reaches the model.
///
/// [consecutiveCount] is the value of
/// `SessionRuntimeState.consecutiveSingleToolCallRounds` at the
/// moment the modulo gate fired — a positive multiple of the
/// configured threshold (10, 20, 30, … by default).
String renderSingleCallReminderBubbleLabel(
  int consecutiveCount, {
  int threshold = 10,
}) {
  final severity = singleCallHintSeverityFor(
    consecutiveCount,
    threshold: threshold,
  );
  switch (severity) {
    case SingleCallHintSeverity.mild:
      return '$consecutiveCount consecutive single-tool-call rounds · '
          'try parallel tool calls';
    case SingleCallHintSeverity.firm:
      return '$consecutiveCount consecutive single-tool-call rounds · '
          'serialisation drift — use parallel tool calls';
    case SingleCallHintSeverity.urgent:
      return '$consecutiveCount consecutive single-tool-call rounds · '
          'severe drift — switch to parallel tool calls';
  }
}