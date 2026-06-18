# Hint: parallel tool call detection

This is the **in-context reinforcement prompt** that Crux injects into the
LLM's next turn to encourage batching of independent tool calls. The
feature ships two complementary signals (both gated on a single
`hint_parallel_calls` toggle), and an accompanying user-facing bubble
for the positive signal only.

## Two signals

### 1. Praise hint (positive)

Fires when the model emits two or more successful tool calls in a
single round. Reinforces the batching behaviour so it carries into
long sessions where the model otherwise tends to forget
system-prompt instructions.

* Injected into the LLM's next turn via the wire format (not shown
  to the user).
* A separate user-facing `parallel_praise` bubble is rendered in
  the TUI ("N tool calls parallelized · saving M round trips").

### 2. Single-call hint (corrective)

Fires when the model has emitted `hint_parallel_calls_single_threshold`
(default 10) consecutive single-tool-call rounds in a row. Mitigates
the opposite drift: the agent regressed to one tool call per turn
in a long session. The modulo gate (`counter % threshold == 0`)
makes the reminder rhythmic — it fires at round 10, 20, 30, … until
the streak breaks.

* Injected into the LLM's next turn via the wire format.
* **Not** shown to the user — the user doesn't need to see "your
  agent got a nudge after 10 single calls."

## Why a separate file

This prompt is one of several "system-shaped" instructions Crux
injects into the model conversation (alongside the title-generation
prompt and the TLDR prompts in `auxiliary_prompts.dart`). Keeping it
in a `.md` file rather than a string constant makes the intent
discoverable and editable without wading through Dart, and it
documents the wire-format quirks below that the Dart constant has to
respect.

## Templates

### Praise hint

```text
You emitted {count} tool calls in a single turn, saving {savings}
{trip_word} with the model. Nice parallelization — keep batching
independent calls like this in future turns.
```

Where:

- `{count}` — the number of *successful* tool calls the model
  emitted in the round. Parse errors and tool-level errors are
  excluded so the praise fires on intentional batching, not on
  confused bursts.
- `{savings}` — `count - 1` (one round trip per call beyond the
  first).
- `{trip_word}` — `round trip` (singular, when `savings == 1`) or
  `round trips` (plural otherwise). The singular form dominates
  (saving 1 is the typical 2-call parallelization) and `1 round
  trip(s)` reads awkwardly.

### Single-call hint

```text
You have emitted {count} consecutive single-tool-call rounds in a
row. If those calls were independent, batching them into a single
turn would have saved round trips with the model. Consider bundling
independent reads, searches, and other queries going forward.
```

Where `{count}` is the consecutive-single-call round count (the
reminder fires at multiples of `hint_parallel_calls_single_threshold`,
so the count seen by the LLM will be 10, 20, 30, … by default).

## Wire format

Both hints are **appended to the `content` field of the last tool
call's result** on both protocols. Not delivered as a separate
`user` message, not added as a sibling `text` block — both
alternatives mislead the LLM into thinking the human just spoke
(the Anthropic variant muddies "this turn is tool results" with
"the user is also saying X"). Keeping the hint inside a tool's
content keeps the message stream unambiguous.

Each hint is framed with a clear system-note marker so the model
can pattern-match it as injected feedback rather than the tool's
actual output. The two markers differ so the model can tell which
signal it's seeing:

Praise:
```text

[Crux system note — parallel-tool-call hint]
You emitted 3 tool calls in a single turn, saving 2 round trips
with the model. Nice parallelization — keep batching independent
calls like this in future turns.

```

Single-call:
```text

[Crux system note — single-tool-call hint]
You have emitted 10 consecutive single-tool-call rounds in a row.
If those calls were independent, batching them into a single turn
would have saved round trips with the model. Consider bundling
independent reads, searches, and other queries going forward.

```

So the last tool's `content` becomes:

```text
<actual tool output>


[Crux system note — parallel-tool-call hint]
You emitted 3 tool calls in a single turn, saving 2 round trips
with the model. Nice parallelization — keep batching independent
calls like this in future turns.

```

The leading blank lines and the bracketed marker are the LLM's
cue that the trailing block is meta-information about the round,
not a continuation of the tool's normal output. Both the marker
tag and the trailing blank line are part of the contract — tests
pin them down.

## Counter lifecycle

The single-call hint uses a per-session, in-memory counter
(`SessionRuntimeState.consecutiveSingleToolCallRounds`) maintained
by `chat_service`. Transitions:

| Round outcome              | Counter action           |
|----------------------------|--------------------------|
| 0 tool calls (text reply)  | reset to 0               |
| 1 successful tool call     | increment by 1           |
| ≥2 successful tool calls   | reset to 0               |

The counter resets to 0 on app restart (intentional — a fresh
launch is effectively a fresh session, and the drift signal is
per-session). It is also reset when the chat service sees a
non-tool round; the in-memory state is not persisted to the DB.

The reminder fires when the counter is a positive multiple of the
threshold (`counter > 0 && counter % threshold == 0`). A 0 threshold
(TOML explicit `hint_parallel_calls_single_threshold = 0`) makes
the modulo collapse to "always" — useful for testing, never useful
in production.

## Persistence

In-context hints are **never** persisted to the message store —
they shape this session's behaviour and are gone on resumption.
The user-facing `parallel_praise` bubble (positive signal only) is
a different artefact and *is* persisted (so the user can scroll
back and see which turns had parallel calls).

## Toggle

Both hints and the user-facing bubble are gated on
`hint_parallel_calls`, which is:

- `true` by default on every `LlmProvider`
  (`LlmProvider.defaultHintParallelCalls`),
- overridable per provider class (e.g. a future provider could
  default to `false` if its models tend to over-batch junk calls),
- overridable per provider in TOML via top-level
  `hint_parallel_calls`,
- overridable per model in TOML via `[[models]]`
  `hint_parallel_calls`.

The threshold for the single-call reminder follows the same
resolution order with its own field:

- `LlmProvider.defaultHintParallelCallsSingleThreshold` (10),
- per provider TOML: `hint_parallel_calls_single_threshold`,
- per model TOML: `[[models]] hint_parallel_calls_single_threshold`.

### Backward compatibility

The previous name `praise_parallel_calls` is still accepted on both
provider-level and model-level TOML (the field was renamed when
the second signal was added). When both the new and the old name
are present the new name wins, so users can migrate by editing one
line and re-saving. The loader surfaces a clear error if the old
name is present with the wrong type and the new name is also
present, so a malformed legacy value never silently co-exists with
a valid new value.