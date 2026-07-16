# Changelog

All notable changes to Crux are documented in this file.

Changes are grouped under each version, with the commit SHA on the line
below the version header. Each version has at most two categories:
**Features** and **Fixes**.

## [Unreleased]

## [0.14.0] - 2026-07-16

b090a48

### Features

- **Loaded skill chips surface in the chat toolbar**
  (`lib/src/components/loaded_skill_chips.dart` + `chat_toolbar.dart`
  + `chat_turn_orchestrator.dart` + `skill_tool.dart` +
  `session_runtime_state.dart`) — the chat toolbar now
  renders a row of `$<skill-name>` chips inline, between
  the thinking readout and the context bar, so the user
  can see at a glance which skills are currently
  contributing to the session's active context. The chips
  read as "what's in my context" leading into the context
  bar's "how full is it". A skill enters the loaded set
  in two ways:
  1. The user submits a `$<skill-name>` chip — the chip
     substitution step in `chat_turn_orchestrator.sendTurn`
     adds every resolved name from the expansion result.
  2. The LLM calls the `skill` tool with a valid name —
     `SkillTool.execute` adds the resolved name on
     success (failure paths deliberately skip).

  The set persists for the session lifetime and survives
  compactions (the LLM still has the skill's content via
  the bottom-of-log `skill-bodies` summary). Each new
  session starts empty; app restart clears the set
  (in-memory only — `Set<String> loadedSkillNames = <String>{}`
  on `SessionRuntimeState`).

  `LoadedSkillChips.widthBudget(names)` is the
  pre-mount width check the toolbar uses to decide
  whether the row fits before mounting — returns `0` for
  empty sets so the row silently collapses when no skills
  are loaded. Sort is alphabetical, not insertion order,
  so the row doesn't visually reshuffle when a mid-stream
  skill lands at the bottom of an unsorted set. The `$`
  trigger is rendered with the chip-background color so it
  visually disappears (still takes up a cell so the chip
  width matches the input form). `softWrap: false` +
  `TextOverflow.visible` together refuse to wrap or
  ellipsize, which would break the visual contract that
  each chip is one contiguous colored block.

  Backed by `test/loaded_skill_chips_test.dart` (116
  lines covering empty-set, single-name, multi-name,
  alphabetical-sort, hidden-state, width-budget math) and
  `test/chat_toolbar_loaded_skills_test.dart` (183 lines
  covering the toolbar integration: chips appear when the
  runtime has skills, hidden when it doesn't, width-budget
  reservation, idle + transient-detached-runtimes cases).

- **Doom-loop detection breaks LLM response loops**
  (`daa727d`) — when the model repeats the same sentences
  over and over ("doom loop"), the detector:
  1. Tracks sentence hashes across rounds.
  2. Triggers after a 9-sentence cycle repeats 3 times
     consecutively.
  3. Cancels the stream and saves the partial AI message.
  4. Injects a user-nudge message telling the LLM to
     change approach.
  5. Continues the agentic loop so the LLM can retry.

  Without this guard, a model stuck in a doom loop
  would burn tokens on the same content until the
  upstream max-duration or idle watchdog fired. The
  cycle-threshold tuning (9 sentences × 3 repeats) keeps
  the detector conservative — a legitimate repeated
  phrasing in a single answer doesn't trigger.

### Fixes

- **`ReadTool` tolerates non-UTF-8 bytes** (`read_tool.dart`)
  — Unity's `Library/*.asset` files routinely contain
  bytes that strict UTF-8 decoding rejects, which would
  otherwise terminate the read tool with a
  `FileSystemException` and stop the agent mid-task.
  New `_readLinesTolerant` strips a UTF-8 BOM if present,
  decodes as UTF-8 with `allowMalformed: true`
  (substitutes the Unicode replacement character instead
  of throwing on malformed sequences), and falls back to
  latin1 if even malformed-tolerant UTF-8 fails (rare —
  usually only when the bytes aren't UTF-8 at all, e.g.
  UTF-16 without BOM). Latin1 maps every byte 1:1 and is
  guaranteed not to throw. Replaces both call sites of
  `file.readAsLines()` in the read loop.

- **Vibe think-box effort uses the provider's
  internal→display mapping** (`vibe_segment_bubble.dart`)
  — `ThinkBoxData.effort` is documented as "stored as a
  raw string because many models override the display
  value". Without the mapping, the consolidated segment
  bubble would show the raw internal value (e.g.
  `normal`) while the streaming bubble next to it shows
  the mapped label (e.g. `adaptive` for MiniMax) — the
  same effort rendering two ways in the same view. New
  `reasoningPresets` parameter on `VibeSegmentBubble`
  (mirroring the same parameter on `VibeStreamingBubble`
  and `MessageBubble`) feeds a `_displayEffort` helper
  that returns the matched preset's `displayLabel` when
  found, the raw internal value otherwise (identity
  fallback, matching the streaming bubble).

- **Vibe user line uses `Row(Text, Expanded(Text))`
  layout for proper alignment + soft-wrap**
  (`vibe_segment_bubble.dart`) — earlier the user line
  was a single flat `Text(' you: $userText')` with a
  manual `userIndent = '       '` (7 spaces) hack to
  align continuation lines. Replaced with the verbose
  `MessageBubble` layout: `Padding(horizontal: 1) →
  Row(Text(' You: ', bold), Expanded(Text(userText)))`.
  The `Expanded` gives the user text a real width budget
  so terminal-driven soft-wrap aligns continuation lines
  at the same column as the first line — without it, a
  long message wrapped flush-left under the bubble's
  column 1, breaking the visual anchor the prefix
  establishes. Explicit user newlines keep their natural
  indentation inside `Expanded`. Prefix label is bolded
  (matching the verbose bubble) and 'You:' is
  title-cased (also matching verbose). The
  `b090a48 fix(vibe): preserve user-message line breaks`
  commit's 7-space pre-indent hack is now obsolete;
  the new layout supersedes it.

- **Vibe persists segment bubble forwards `ses://` and
  markdown link callbacks in the prose row**
  (`d4d60f9`) — when the consolidated `VibeSegmentBubble`
  rendered the agent's prose as a flat `Text`, clickable
  session links (`ses://<id>`) and markdown links
  (`[label](url)`) were inert. Forward the parent
  component's `onSessionLinkTap` and `onLinkTap` through
  the prose widget so the click affordances work in the
  consolidated view, matching verbose mode.

- **Vibe freezes the think time and activates tools
  while writing tools** (`7fa0322`) — the live
  `VibeStreamingBubble`'s think-box time row would keep
  ticking during a `write` tool execution (the round
  hasn't emitted the first delta for the next round's
  reasoning yet, but the previous round's think time
  counter was still updating). Freeze the think time on
  tool execution and activate the tools box until the
  next round's first delta. Matches the user's mental
  model: while a tool is being named / parsed /
  executed, the model's "thinking" phase is paused, not
  in progress.

- **Vibe persists segment bubble gains dedicated test
  suite** (`test/vibe_segment_bubble_test.dart`, 340
  lines) — first dedicated widget test for the
  consolidated `VibeSegmentBubble` covering: user line
  layout (Row vs flat Text, prefix alignment), think
  box with / without effort, tools box, files box,
  prose row with markdown link callbacks, prose row
  with quick replies enabled, multi-segment turn, empty
  user turn. Existing `vibe_segment_test.dart` only
  covered the walker; this covers the rendering.

- **Context bar refresh indent** (`context_bar.dart`) —
  drive-by whitespace fix in the post-compact target
  update path (the if-block was missing one level of
  indent from a prior refactor; the logic was correct
  but the code was visually misleading).

## [0.13.0] - 2026-07-15

d93b665

### Features

- **Vibe mode — aggregated chat display is the new default**
  (`51ea77e` + `3622efb` + `8ce1911`) — Crux gains a second
  chat render mode. Vibe collapses each agent turn into
  three metadata boxes stacked under the user line:
  **think** (duration, tokens, effort), **tools** (per-name
  call count + tokens), and **files** (per-path +N -M line
  deltas via `ToolDef.modSummary`). A separate
  `VibeStreamingBubble` renders the in-flight turn with the
  active box (think / tools / files) highlighted at ~33 ms
  poll cadence, mirroring what `StreamingController` knows
  about which phase the round is in. Use `/view verbose` /
  `/view vibe` to flip (or click the position-top-right
  toggle in the chat panel). The setting is in-memory
  only — resets to vibe on app restart, matching the
  design doc's "pure viewer-mode setting" framing. 14 files
  modified, 7 new files (~283 lines added). Backed by
  `test/vibe_segment_test.dart` (snapshot-style assertions
  on `walkSegments` against hand-built message lists:
  single-round, multi-round, mixed `tool_call + content`,
  auto-emit-pending, system-role filtering) and
  `test/vibe_box_test.dart` (VibeBox rendering shape +
  active styling). The design doc is `docs/design-vibe-mode.md`.

- **Cross-session file write attribution in read +
  edit/write guard** (`1da2322`) — when the read-before-write
  guard fires because a file was modified since the local
  session last read it, the guard now names the session that
  produced the current content and quotes the `intent` that
  session passed to its edit / write. The `read` tool
  surfaces the same provenance proactively — before the
  agent commits to any edits — as a one-line `[NOTE: …]`
  banner prepended above the file content. Multi-session
  workflows were producing wasted rounds where one session
  would overwrite another's intent without realizing it;
  the guard could already detect the drift but couldn't
  tell the agent *whose* version it was about to overwrite.
  New `file_last_writer` table (PK `path`, columns
  `writer_session_id` FK → `sessions` ON DELETE CASCADE,
  `intent`, `mtime_ms`). Schema 26 → 27, single migration
  calling `createTable(fileLastWriter)` for existing
  installs. Attribution shown only when (a) a row exists,
  (b) its `mtime_ms` matches the current on-disk mtime
  (otherwise something external touched the file after the
  recorded write and the intent no longer reflects the
  file's actual state), and (c) the writer is a different
  session (self-attribution is noise). The session title is
  looked up live from `sessions.title` at guard time so
  `/rename` reflects immediately; not snapshotted.
  Failure modes are silent: `onRecordWrite` and
  `onLookupAttribution` exceptions are swallowed and the
  feature degrades to the existing generic drift message
  or no banner. Persistence failure is non-fatal in both
  directions (matches the existing `onRecordRead`
  behavior). Backed by 10 new tests in `test/tool_test.dart`
  covering `recordWrite` cache + callback wiring,
  drift-branch attribution under all three filter
  conditions, `readAttributionBanner` formatting under
  success / no-row / self-write / empty-fields /
  no-callback / throw, and the read-tool end-to-end with a
  real `FileReadTracker`. All 165 tool + edit + write + LSP
  integration tests pass.

- **Mid-stream early abort for unknown tool calls**
  (`6ceaafc`) — extends the streaming-time early-abort
  mechanism (already used for the edit/write
  read-before-write and oldString-no-match guards) to catch
  the LLM emitting a tool name that is not registered.
  Cuts off the stream before the LLM spends tokens
  generating arguments for a tool that can never run.
  Three trigger categories:
  1. *Hallucinated tool names* (`ask`, `question`,
     `terminal_run`) — would otherwise generate the full
     input JSON for a tool the registry cannot resolve.
  2. *Stale registrations* — a tool that was in the LLM
     tools list when the request went out but was
     unregistered mid-session (e.g. `/web-provider`
     flipping `websearch` off between turns).
  3. *Provider / upstream drift* — tool schemas that
     changed across Crux versions.

  `_PendingStreamingGuardAbort` now carries nullable
  guard / filePath, an explicit `reason` field
  (`read-before-write` | `oldString-no-match` |
  `unknown-tool`), the registered tool names, and an
  `isUnknownTool` helper. The chunk-loop event and the
  `LlmClient` cancel reason both consume `reason`
  directly, so all abort kinds share one surface.
  `_StreamingGuardAccumulator.accumulateAndCheck` adds an
  early branch triggered on the very first chunk that
  names a tool the registry cannot resolve. Gated on
  `chunk.index == _maxSeenIndex` to mirror the
  parallel-tool guard behavior so earlier siblings still
  get persisted normally. `_buildGuardAbortedToolResult`
  produces two synthetic bodies from one helper. Both
  share the `[Crux system note - tool-call early abort]`
  marker so the existing display banners and compaction
  filter pick them up unchanged. The unknown-tool body
  lists the registered tools so the LLM can retry on the
  next turn without guessing. Tool-call stub carries
  `_aborted_by_unknown_tool` / `requestedName` /
  `availableTools` instead of `_aborted_by_guard` /
  `filePath` so the persisted round is self-describing.
  `ToolExecutor.allToolNames()` exposes registry names to
  the accumulator; the post-stream "Unknown tool: <name>"
  error path remains as defense-in-depth. Display:
  collapsed row label and detail-pane banner specialize on
  the new body prefix (`[UNKNOWN TOOL]`) and pull the
  requested name out of the body so users see
  `unknown tool 'ask'` rather than the generic guard copy.

  Backed by a new `ToolExecutor` group in
  `test/tool_test.dart` (covering `allToolNames`
  declaration order, case-insensitive lookup so mixed-case
  hallucinated names still hit the abort, and the
  post-stream "Unknown tool" defense-in-depth fallback)
  plus a new compaction-filter test in
  `test/chat_log_builder_test.dart` verifying the
  `[UNKNOWN TOOL]` body is dropped from the compacted
  log the same way the existing early-abort filter drops
  file-guard bodies. `docs/design-streaming-guards.md`
  reason-taxonomy table gains the unknown-tool row;
  Non-Goals clarifies that file-guard checks stay
  edit/write-only while the unknown-tool check is a
  separate concern that applies broadly.

- **Project-committed skills via `.claude/skills/` and
  `.agents/skills/`** (`da4530e`) — extends the 0.12.0
  skill system so a repo can commit portable cross-agent
  skills alongside its code. Project-level discovery now
  scans `.claude/skills/` and `.agents/skills/` at each
  level of the cwd → git-root walk, in addition to the
  existing `.crux/skills/` and `.crux/skill/`. Project
  copies shadow same-named `~/.claude` and `~/.agents`
  skills so teams can pin a project-specific version of
  any skill and override the user's global copy.

### Fixes

- **Vibe mode segmentation model — settled on
  prose-boundary closes with `tool_call_with_content` also
  closing** (`d18b3c0` → `a2a3eba` → `1b8b221` → `fe16725`
  → `c87c4da` → `ae4fdff`) — the vibe walker went through
  several iterations to settle on the correct boundary
  semantics. The final model (`ae4fdff`):

  > A segment = the think + tools accumulated between two
  > response bodies. Response bodies are `role: 'ai'` rows
  > AND `role: 'tool_call'` rows with non-empty content
  > (per spec rule 2.3). Each prose boundary emits its
  > own `VibeSegment`; multiple consecutive closes within
  > one user turn produce multiple segments. The walker
  > resets the box accumulators right after every close.
  > `currentUser` is NOT cleared on close (the fix for
  > the "two consecutive `role: 'ai'` rows silently drop
  > the second one" symptom). `showUserMessage` is true on
  > the first emit of a user turn, false on siblings, so
  > the `you:` line appears exactly once per turn
  > regardless of how many segments land.

  Earlier attempts:
  - `d18b3c0` — initial collapse to one segment per user
    turn (mistook the spec's "between two responses" as
    "one segment per turn"). Restored in `a2a3eba`.
  - `1b8b221` — second attempt at per-turn. Reverted in
    `fe16725` after user-reported "boxes split across
    segments" symptom.
  - `c87c4da` — third attempt at role:'ai'-only close
    (which produced a single trailing segment for any
    turn ending on a tool_call — exactly the
    "all merged into agent turn" symptom the user
    flagged). Restored to spec model in `ae4fdff`.

- **Turn divider with time-since-last-agent-turn**
  (`1839d2d`) — user messages in vibe mode now sit under
  a centered-dash divider that labels the gap from the
  previous agent turn's end. The label uses minute
  precision and breaks down to days / hours / minutes
  when the gap is large enough (`just now` | `X minutes
  ago` | `X hours [Y minutes] ago` | `X days [and Y hours
  Z minutes] ago`). New util `formatAgentTurnGap(Duration)`
  in `duration_format.dart` owns the bucket boundaries
  and grammar. New widget `VibeTurnDivider` mirrors
  `CompactionDivider`'s centered-dash visual so the
  chat history's structural markers all look the same.
  Single-row, no `onTap` (turn gap is purely
  informational). Inserted only above the FIRST segment
  of a user turn so multi-segment turns don't get
  duplicate dividers. The first user message of a session
  has no prior agent activity, so no entry is recorded and
  no divider renders. Backed by 6 unit tests on
  `formatAgentTurnGap` covering all four buckets plus the
  multi-day cumulative wrap and the whole-day / whole-hour
  drop-zero sub-units edge cases. 70 / 70 pass.

- **Divider math fixes** (`be8a2f5` + `9ef9472` +
  `9d4b428`) — three coordinated fixes for the turn
  divider rendering:
  1. *ASCII `-` instead of U+2500 `─`.* Many terminal
     fonts render `─` as 2 cells in practice, even though
     wcwidth says 1. Symptom: the vibe divider wrapped to
     two stacked horizontal lines. Switching to ASCII `-`
     (universally 1 cell in any font) fixes it.
  2. *`UnicodeWidth.stringWidth` for the math.* The
     previous build used `String.length` to size the
     dash + label line; that counts Dart code units, only
     equal to display cells for ASCII. Any wide Unicode
     character (CJK, full-width punctuation, emoji) would
     be under-counted. Imports nocterm's own
     `UnicodeWidth.stringWidth` (with `// ignore_for_file:
     implementation_imports`) so the math stays in sync
     with what `Text` actually paints.
  3. *Padding OUTSIDE the LayoutBuilder.* The previous
     structure had `LayoutBuilder` outside `Padding`, so
     the builder saw the parent's un-padded `maxWidth`
     and computed a line of N cells, then `Padding`
     shrunk the available width by 2 and the `Text` widget
     overflowed. Restructured to match the
     `[CompactionDivider]` pattern: `Padding` outside the
     builder, math and `Text` constraints line up, line
     fits in one row.

- **Vibe files box in live bubble for streaming /
  executing edit / write** (`4c20d68`) — the persisted
  `VibeSegmentBubble` already renders a files box once a
  turn closes, with the full path +N -M line delta. The
  live `VibeStreamingBubble` previously showed no file
  info at all — only the think box (while reasoning
  streamed) and the tools box (while a tool was being
  named or executed). For an edit / write, the user
  couldn't tell *which file* was about to be touched
  until the tool returned and `walkSegments` ran again,
  which can be many seconds later for slow tools or
  large edits. Add a third live box — files — that
  surfaces the path the moment the edit/write tool is
  recognised. For streaming tools, `jsonDecode` on the
  accumulated input (with a regex fallback for
  `"filePath":"..."`); `filePath` is the first key in
  both edit and write arg shapes so it lands in the first
  one or two chunks. For executing tools, use
  `ToolCall.filePath` (priority list starts with
  `filePath`). Row text is `p.basename` only — full paths
  overflow and push everything else off-screen. The box
  is "active" (highlighted via warning color + tint)
  while any edit/write tool is in the executing list.

- **`you:` label aligns with `crux:` label in vibe
  segment bubble** (`de51764`) — the user line was a
  plain `Text` widget with no padding, so `you:` rendered
  at column 0. The boxes wrapped in `Padding(left: 2)`
  and the prose line wrapped in `Padding(horizontal: 1)`
  with a leading space inside the text (` Crux: `) — both
  landing at column 2. Wrap the user line in the same
  `Padding(horizontal: 1)` + leading space as the prose
  row. `you:` now lands at column 2, matching where the
  boxes start and where `crux:` starts.

- **Live think box time row uses active generation time**
  (`22c67cc`) — previously the live think box's time row
  used the streaming controller's waiting-time counter
  (time waiting for the model to start). That counter
  ticks before the first delta but freezes as soon as
  reasoning actually streams — so the time row visually
  stopped moving while the token row kept growing, and
  the two rows never ticked together during a thinking
  phase. Switch the source to
  `SessionRuntimeState.roundFirstTokenTime` and compute
  `now - roundFirstTokenTime` on each build. The bubble
  rebuilds every 33 ms while active, so the value updates
  in lockstep with the live token estimate. Fall back to
  the waiting-time counter during the pre-first-delta
  (TTFT) phase so the think box still shows a meaningful
  time row before reasoning lands.

- **Vibe persists + live open-segment boxes merge**
  (`a85def8`) — when the live streaming bubble emits an
  open segment and the persisted walk concurrently emits
  a different segment for the same user turn (during the
  round's persistence path), the two were rendered as
  separate segment blocks. Merge them into one bubble
  that tracks the union of box states so the user sees
  one continuous segment during the brief overlap.

- **Metrics cubit mirrors compacted target**
  (`b6c586c`) — `MetricsCubit` mirrors live metrics
  fields at the end of the 50 ms tick. When `/compact`
  finishes and updates `rt.contextTargetTokens` to the
  new compacted target, the cubit mirror path was
  dropping the field on the post-compact update. The
  context bar's `_lastSeenTarget` comparison then froze
  until the next user-driven change. Mirror re-includes
  the field on the compact-write path.

- **Test fixes** (`a1e5804` + `db1b9bc` + `1ff07c5` +
  `3cb9579` + `d93b665`) — `run_metrics_test.dart`'s
  Dracula color assertion fixed to 24-bit truecolor
  `(38;2;189;147;249)` (nocterm's `TextStyle.toAnsi()`
  emits truecolor, not 8-bit indexed); `IsolateChannel`'s
  "two channels run independently" test timeout bumped
  from 2 s to 10 s to absorb cross-isolate event delivery
  delays under full-suite load; `/project` test now
  filters whitespace-bearing HOME children (macOS
  `~/Unity user templates` was breaking the path
  splitter); two `CruxThemeData()` test constructors
  missing the new `chipBackground` parameter were
  blocking the suite from compiling; `vibe` headless
  test no longer mutates `process.cwd` (was leaking
  state to subsequent tests).

## [0.12.0] - 2026-07-10

b6364d5

### Features

- **Skill system with dollar-chip UX** (`9b3ad98` +
  `7671f69`) — Crux now speaks the open-standard Agent Skills
  format. A skill is a folder containing a `SKILL.md` with
  YAML frontmatter (name, description, body). The user
  activates one by typing `$<skill-name>` in the chat input
  — the trigger parses as a chip (rendered with chip
  styling; the `$` is invisible), and on submit the chip
  expands to `Skill: <name>\n<body>` before being sent to
  the LLM. Discovery is priority-ordered across
  `.crux/skills/`, `.crux/skill/`, `~/.claude/skills/`,
  `~/.agents/skills/`, `~/.local/share/crux/skills/`. The
  LLM sees skill names + descriptions via a new
  system-prompt layer 3.5 (compact listing, no bodies) AND
  can call a dedicated `skill` tool to load a body on its
  own. The picker overlay (opens when the user types `$`)
  supports arrow / tab / enter to insert the selected skill
  at the cursor. Chip-aware backspace removes the whole
  chip on one keypress. Frontmatter parser is strict (name
  must match the folder and match `[a-z0-9][a-z0-9-]*`,
  description required and ≤ 1024 chars, unknown fields
  silently ignored).

  Backed by `test/services/skills/skill_frontmatter_test.dart`
  (274 lines for the frontmatter parser), `test/services/skills/skill_discovery_test.dart`
  (299 lines for discovery priority / folder matching), `test/utils/skill_chip_parser_test.dart`
  (188 lines for chip tokenization), `test/utils/skill_chip_substitution_test.dart`
  (175 lines for submit-time expansion), `test/tools/skill_tool_test.dart`
  (9 cases covering parameter schema, missing-name error,
  not-found message, `<skill_content>` rendering, sibling
  sampling, prune rendering, prune extraction), and the
  registry default-set count test bumped to include the new
  tool. 70+ new tests in total.

- **Skill + @-mention + image chips render inline in chat
  input** (`6bc5fd1` + `ff6356b`) — `$skill-name`,
  `@path/to/file`, and `[ image N ]` tokens now render as
  chip-styled text (background color matching the theme;
  the `$` / `@` trigger chars are kept in the text but
  styled invisible so submit-time parsing still works).
  Skill picker overlay rows also show the chip background.
  TextField gains a `styleSegments` prop in the nocterm
  submodule to support per-segment styling without
  splitting the field.

- **Skill + @-mention + image chips render inline in chat
  history** (`3c47b7b`) — user messages in the chat log
  now render their embedded `$skill`, `@path`, and
  `[ image N ]` tokens as chip-styled text via RichText,
  matching the input box behavior. Same invisible-trigger
  convention.

- **Skill picker uses fuzzy subsequence matching**
  (`c8a0aaf`) — typing "gce" matches "gitnexus-exploring"
  (case-insensitive subsequence), consistent with the
  existing file @-mention search. Prefix-only matching was
  too restrictive for skills whose names are descriptive
  compound words.

### Fixes

- **Chat bubble shows the chip, not the skill body**
  (`bd8d196`) — `sendTurn` previously mutated `text` to the
  expanded form BEFORE storing the `Message`, so the chat
  log saw the body. Split into two: `Message` stores the
  raw input (with the chip); the LLM API call uses the
  expanded `llmText` form. Title generation also uses the
  raw text — the chip name itself is descriptive enough
  ("gitnexus-exploring" rather than the 200-line body).

- **Skill bodies stripped from chat history on reload**
  (`96feedf`) — the chat turn executor persists the
  LLM-bound message (which includes appended
  `Skill: <name><body>` blocks) to the message store. When
  reloading from disk, user bubbles were showing those
  bodies. Strip them before rendering — the chat log should
  only show what the user actually typed.

- **Backspace deletes one char, not the whole chip, when
  the picker is open** (`b6364d5`) — when the skill picker
  is visible, backspace now deletes a single character
  instead of the whole chip. The user is still refining
  their query and likely wants to edit it, not start over.

- **Visual-chip Stack overlay reverted; chat input goes
  back to plain TextField** (`369e317` → `bd8d196` →
  `02e3e62` → `25005df`) — the first attempt at a
  visual chip (`369e317`) built it as a `Stack` overlay
  painted on top of nocterm's `TextField`, so the
  `TextField` would keep ownership of editing semantics
  (IME, cursor blink, paste, click-drag selection). Two
  regressions appeared:
  1. The chat bubble showed the full skill body (the
     expansion was applied to `text` before storing the
     `Message` — fixed in `bd8d196`).
  2. The chat input was narrower than before — the
     `TextField` was a non-positioned child of the `Stack`,
     so nocterm sized it to its intrinsic content width
     instead of the available chat-input width. The paste
     button no longer visually separated the input from
     the chat output. The fix in `bd8d196` was to wrap the
     `TextField` in `Positioned.fill`, matching the
     pre-Stack behavior.

  The user then decided the Stack overlay changed the
  chat input's layout in subtle ways that broke multi-line
  paste and made the input look indented. `02e3e62` reverts
  the Stack overlay entirely — the chat input goes back to
  nocterm's `TextField` directly inside the `Expanded`. The
  colored background band on the chip in the input is
  deferred to a v2 that doesn't change the chat input's
  layout (e.g. a post-render pass that reads the
  `TextField`'s `RenderObject` and paints chip cells on top
  of the actual rendered text, the way opencode / openclaude
  rendering hooks work). `25005df` cleans up the orphaned
  `skill_chip_backdrop.dart` (252 lines) and its test file
  (227 lines).

  What stays from the Stack arc: `$` chip detection in the
  input (the parser runs on `textController.text`); picker
  overlay when the user types `$`; chip-aware backspace;
  submit substitution (LLM gets the body, chat bubble shows
  the chip); the LLM-facing `skill` tool; the system-prompt
  layer 3.5.

## [0.11.7] - 2026-07-07

a04290e

### Fixes

- **Quick reply label duplication when labels contain inline code
  spans** — `applyQuickReplyTokens` (`lib/src/utils/quick_reply_parser.dart`)
  used to emit a token's label once per flat entry the token's source
  range straddled. When a label contained `` `…` `` code spans, the
  markdown parser split it into multiple inline spans, so the same
  label rendered N times in a row (e.g. 7× for a label with three
  backtick pairs, 3× for one pair, 1× for none). Tracked down via
  ses://2579 / message 135160. Fix tracks which replies have been
  emitted (`emittedReplies` keyed on `sourceStart`), restricts the
  per-entry overlap check to replies whose `sourceStart` lies inside
  the current entry, and skips entries that fall entirely inside an
  already-emitted reply's range. A follow-up edge fix: when a
  straddling reply's `sourceEnd` lands in the MIDDLE of a later flat
  entry (e.g. the closing `}` shares its text span with trailing
  prose), the renderer now emits only the tail past `sourceEnd`
  instead of dropping the whole entry — so text after the token
  survives. Four regression tests added under
  `applyQuickReplyTokens — code spans inside the LABEL` in
  `test/utils/quick_reply_parser_test.dart`. See
  `docs/quick-reply-label-rendering-bug.md` for the full postmortem.

## [0.11.6] - 2026-07-07

a04290e

### Features

- **Auto-repair orphan tool history and retry once on first hit**
  (`5788996` + `4fd2fc3` + `a04290e`) — the 0.11.5
  orphan-`tool_use` repair only cleaned the wire payload
  per-request; the underlying DB still held the broken
  history, so every session that hit a MiniMax 2013 (or
  an Anthropic invalid_request_error referencing
  `tool_result` / `tool_use_id`) had to eat the
  per-request repair cost forever. 0.11.6 closes the
  loop with a three-part feature: when a request fails
  with an orphan-tool-use error, Crux now (a) detects
  the error class, (b) cleans the underlying `tool_call`
  and `tool` rows in one transaction, and (c) rebuilds
  the request and retries once. The repair is
  per-round, automatic, and self-limiting: a second
  2013 in the same round falls through to the existing
  non-retriable surface (the user gets the standard
  "▶ retry (/continue)" bubble), and `/retry` re-arms
  the hook for the next round.

  - `5788996` — `LlmError.isOrphanToolUseError` recognizes
    MiniMax `base_resp.status_code == 2013` plus
    Anthropic / other `invalid_request_error` shapes
    whose message contains `tool_result`, `tool_use_id`,
    or prose forms like "tool result for tool use".
    Intentionally narrow so unrelated
    `invalid_request_error` shapes (malformed JSON,
    schema failures, bad parameter names) don't
    accidentally trigger a session-wide repair. The
    `LlmProvider.supportsOrphanToolRepair` capability
    flag defaults to `false`; only
    `AnthropicCompatibleProvider` overrides it to
    `true`. MiniMax inherits the override via the
    existing extends chain — no MiniMax-specific code
    ("target Anthropic not MiniMax" property holds).
  - `4fd2fc3` — `MessageStore.repairOrphanToolRows`
    walks a session's `tool_call` and `tool` rows,
    finds orphans, and prunes them in a single
    transaction. `tool_call` rows drop entries whose
    `callId` no subsequent `tool` row references; a
    `tool_call` whose `toolCalls` becomes empty after
    pruning is deleted entirely (an empty `tool_call`
    is meaningless and would re-trigger the same
    orphan error on the next request). `tool` rows
    whose `toolCallId` doesn't appear in any preceding
    `tool_call`, or whose preceding flow has been
    terminated by an intervening ai / user / system
    row, are deleted. Returns the number of rows
    modified; well-formed histories return 0 so the
    executor's per-round flag and status toast stay
    quiet on a healthy session.
  - `a04290e` — `ChatTurnExecutor` wires the hook:
    the per-attempt `chunk.error` handler checks
    `isOrphanToolUseError` BEFORE the existing
    non-retriable fallthrough, calls
    `repairOrphanToolRows(sessionId)`, emits a status
    toast ("Detected orphan tool rows from a previous
    round — repairing and retrying…"), sets
    `orphanToolRepairAttempted = true`, and resets
    `attempt` to `-1` so the post-increment lands
    back at attempt 0 with no backoff (the repair was
    the action; upstream had nothing to wait for). An
    `orphanToolRepairJustFired` one-shot sentinel
    clears `streamError` at the TOP of the next
    iteration so a successful rebuilt request exits
    the loop normally without re-firing the
    bottom-of-loop success check on the failed
    iteration.

  Backed by `test/llm_error_test.dart` (140 lines
  covering the MiniMax 2013 positive, MiniMax 1042
  negative, three Anthropic message variants, schema
  negative, OpenAI negative, and a sweep of all
  non-invalidRequest kinds), `test/llm_provider_test.dart`
  (+26 cases for the capability flag), and
  `test/repair_orphan_tool_rows_test.dart` (303 lines
  covering empty history, well-formed round, mid-round
  partial persist, total mid-round interrupt, orphan
  tool rows, intervening ai row terminating pending,
  idempotence, multi-round sessions, and end-of-input
  terminating). Executor behavior covered by 4 cases
  (first 2013 fires + succeeds, second 2013 surfaces
  to onError with no second repair, non-Anthropic
  2013 falls through, non-tool invalidRequest doesn't
  trigger).

### Fixes

- **Live TTFT keeps ticking between model rounds**
  (`d078c1a`) — `MetricsCubit.updateLiveMetrics`'s
  50ms tick had the TTFT mirror AFTER the second
  early-return. That early-return fires between
  model rounds (before the first delta, during local
  tool execution, between LLM requests) to skip the
  tok/s computation when no tokens are being
  generated, but the live TTFT timer should keep
  ticking through those gaps — the turn is still
  responding, the user is still waiting for the
  first token, and the displayed TTFT should count
  up monotonically. The fix splits the cubit mirror
  into two stages: BEFORE the second early-return,
  mirror the basic fields (`ttftMs`, `ttftReceived`,
  `contextTargetTokens`) so TTFT flows through the
  gaps; AT the end, mirror the full set including
  `tokPerSec` (which only updates during a streaming
  round, which is correct). After this slice, the
  metrics display's TTFT starts at 0 when the turn
  begins, ticks up smoothly through the round and
  through any gaps between model rounds inside the
  same turn, freezes at the first-delta value when
  the first token arrives (`rt.ttftReceived = true`),
  and continues to display the frozen value after
  the turn ends.

- **Bloc-refactor follow-up fixes** (`c9adb95`) —
  five small fixes landed together to close out the
  cubit migration:
  - `SessionRuntimeState` now implements
    `SessionRuntimeSink` (Phase 1 requirement from
    `docs/refactor/bloc-migration.md`); added
    `beginResponse`, `finishModelRound`,
    `finishResponse`, `recordFirstToken`,
    `updateContext`, `recordCacheHitPct`, etc.
  - `/undo` now restores the undone user message to
    the input box — the slash command was a no-op
    because `setInputText` was never passed into
    `CommandContext`. The callback is now wired so
    undoing a sent user message pops it back into
    the input field for editing.
  - `/temperature` toast/persist order reverted
    back to the original (await `persistTemperature`
    THEN `showToast`); the refactored order (toast
    then unawaited/await persist) caused the toast
    to be lost because pending `setState` from
    `textController.clear()` overwrote the toast's
    dirty flag before the frame rendered.
  - `test/btw_bubble_test.dart` rewritten to use
    `BlocBuilder` + `BtwBubble.ai` instead of the
    non-existent `BtwStreamingBubble`.
  - `test/run_metrics_test.dart` color assertion
    fixed to 8-bit indexed (`38;5;141`) instead of
    truecolor (`38;2;189;147;249`) — the metrics
    display falls back to indexed color when the
    terminal doesn't advertise truecolor, and the
    test was hardcoded to truecolor.

## [0.11.5] - 2026-07-06

93c4c02

### Features

- **Bloc cubits land as passive read-side mirrors**
  (`457ee81` + `5ff78f8` + `6a723f2` → `93c4c02`) — seven
  cubits (SessionCubit, StreamingCubit, MetricsCubit,
  ChatTurnCubit, BtwCubit, CompactionCubit, OverlayCubit)
  now sit alongside the existing `SessionController` /
  `SessionBloc` and mirror every controller write. The
  controller remains the write-side single source of
  truth; the cubits are the read-side SoT for any UI
  subscriber. This is the same pattern nocterm_bloc
  encourages: keep business logic in the controller /
  bloc, expose pure state to widgets through fine-grained
  cubits so a 50ms metrics tick doesn't force a full
  ChatPanel rebuild. The refactor was rolled out in five
  focused slices — `SessionCubit` as the first mirror
  (`6a723f2`), `BtwCubit` alongside it (`1bd6817`),
  `MetricsCubit` as the third (`4738efd`), `ChatTurnCubit`
  as the fourth (`a877e5e`), then `StreamingCubit` last
  (`d93fdfc` → `2428cce` → `3bda2e4` → `768daad`) — with
  the read-side migrations of `chat_history`, `chat_input`,
  `chat_panel`, `chat_toolbar`, `context_bar`,
  `metrics_display`, and the per-tick `updateLiveMetrics`
  loop landing in lockstep. Backed by
  `docs/refactor/bloc-architecture.md` (the architectural
  record added in `f358ff9`) and `test/bloc/*` (90+ new
  cases across `session_controller_cubit_mirror_test`,
  `streaming_cubit_test`, `chat_panel_boot_state_test`,
  `btw_cubit_test`, `btw_session_controller_test`,
  `chat_toolbar_bloc_selector_test`, `turn_registry_test`).

- **`/temperature` slash command for session-scoped override**
  (`a612514`) — adds a `/temperature <value>` slash command
  that sets the sampling temperature for the current
  session only, persisted on the session row and mirrored
  to the runtime on every request. Overrides the model's
  TOML-configured default without touching any other
  session. Goes through the existing CommandRegistry +
  `_executeCommand` path so it picks up the slash-command
  suggestions + alias matching for free (typo-tolerant:
  `/temp`, `/temperature 0.4`, etc. all resolve). Backed
  by the temperature command unit tests; the storage
  layer's `temperature_override` column is added by the
  v26 migration (see Fixes below).

- **`top_p` is paired with `temperature` on every stream request**
  (`93c4c02`) — `LlmProvider.buildRequestBody` gains a
  `topP` parameter and `chat_turn_executor` derives it
  from the active temperature at request-build time so
  the two sampling knobs always move together:

  ```
  top_p = 1.0 - 0.15 * clamp(temperature, 0.0, 1.0)
  ```

  Endpoints: `temperature=0.0` → `top_p=1.0` (full
  nucleus), `temperature=1.0` → `top_p=0.85` (narrowed).
  Both endpoints are clamped so a TOML-configured
  OpenAI-default `temperature` (which may legally be 1.5
  in the `[0.0, 2.0]` range) still produces an API-valid
  `top_p` inside `[0.0, 1.0]`. Rationale: as the
  temperature distribution widens, a narrower nucleus
  prevents the model from selecting truly low-probability
  tokens. The two are inseparable — `top_p` is not
  user-tunable independently. Per-provider wire support
  verified for OpenAI (Chat Completions), Anthropic
  (Messages), and MiniMax (Anthropic-compatible). Backed
  by 7 new mapping cases (endpoints, in-range interp,
  clamp above/below, monotonicity, always-valid range)
  plus 4 cases verifying `top_p` lands in each provider's
  body.

- **Compaction "not worth it" UX** (`8b478d2`, second
  half) — when `/compact` is rejected because the
  projected post-compaction size clears the 95% bar
  (i.e. compaction wouldn't meaningfully shrink the
  context), the panel now shows a toast explaining the
  rejection with the projected savings percentage and
  token count instead of silently no-op'ing. Uses a
  small `_fmtNum` helper on `_ChatPanelState` for
  thousands-separator formatting so the toast reads
  naturally.

- **Context-bar target lerp animates during streaming**
  (`8b478d2`, first half) — the context-window widget's
  right edge now animates smoothly as the model streams
  deltas instead of staying frozen until the round
  ends. The orchestrator already updates
  `rt.contextTargetTokens` on every chunk; the
  `MetricsCubit` mirror at the end of the 50ms tick
  keeps the cubit in lockstep, so the bar's
  `_lastSeenTarget` comparison picks up the change on
  the next build and the lerp animation starts.

### Fixes

- **Anthropic-compatible providers repair orphan `tool_use`
  blocks before sending** (`866369a`) —
  `AnthropicCompatibleProvider.sanitizeMessages` now walks
  the wire-format message list and drops orphan
  `tool_use` blocks from assistant messages and orphan
  `tool_result` blocks from user messages, mirroring the
  `OpenAICompatibleProvider.sanitizeMessages` repair that
  has been in place for DeepSeek / OpenAI-compatible
  providers since the wire-format sanitization hooks
  landed. Crux's storage layer generally maintains the
  pairing invariant (`addToolRound` wraps the tool_call
  row and all matching tool result rows in one
  transaction), but it can still break in two real
  situations:

  1. **Mid-round interruption.** A `tool_call` row is
     persisted but the round aborts before its tool
     results are written — the next request sees a
     dangling `tool_use` block nothing answers.
  2. **Wire-family switch.** Switching the session model
     from an OpenAI-wire provider to an Anthropic-wire
     provider (MiniMax etc.) re-serializes the history
     with the new shape; half-persisted rounds or empty
     `tool_calls` arrays after orphan pruning can become
     malformed payloads the new endpoint rejects.

  Without the repair, the MiniMax API rejects the request
  with a 400 `tool result's tool id ... not found (2013)`
  and the session is stuck — every subsequent retry
  re-sends the same broken history. With the repair, the
  next request from a stuck session goes out clean
  without any database surgery: orphan `tool_use` blocks
  get pruned from the assistant content list (with
  `thinking` and `text` blocks preserved — the API needs
  the thinking signature on extended-thinking turns),
  orphan `tool_result` blocks get pruned from the user
  content list, and assistant messages whose content was
  only `tool_use` get dropped entirely. The
  well-formed-history fast path returns the same list
  reference unchanged, so providers and sessions that
  don't hit this path pay zero per-request allocation
  cost. Unblocks the "bloc refactor" session that hit
  this loop on MiniMax-M3.

  Backed by `test/llm_provider_test.dart` (10 new cases
  covering the well-formed fast path, mid-round
  interrupt, partial-pair preservation, single-tool-use
  assistant dropping, orphan `tool_result` dropping,
  malformed `tool_result` blocks, thinking block
  preservation under orphan pruning, system-message
  interleavings, mixed text + `tool_result` user
  messages, and no-mutation invariants).

- **v26 migration is idempotent** (`0b2cf48`) — the
  `temperature_override` column added by the v26 migration
  is now created with `IF NOT EXISTS`, so re-running the
  migration on an existing database is a no-op instead of
  erroring out. Required because the bloc-cubit migration
  repeatedly loads sessions whose schema was upgraded in
  a prior process, and any startup-time migration re-run
  was hitting the duplicate-column error and aborting
  the cubit wiring before the mirrors could register.

- **`updateLiveMetrics` reads metrics fields from the
  runtime, not the cubit** (`69d4a3d`) — slice 26 jumped
  the gun on the read-side migration: it moved the
  per-tick `updateLiveMetrics` reads of `responseStartTime`,
  `ttftReceived`, `roundStreaming`, `roundFirstTokenTime`,
  `cumulativeCompletionTokens`, and `cumulativeGenMs` to
  the `MetricsCubit`, but none of those fields have a
  controller→cubit mirror path yet (only `tokPerSec` and
  `ttftMs` do, from the slice-21 hotfix). Result: the
  early-return guard `if (!turn.isResponding ||
  metrics.responseStartTime == null)` fired on every tick,
  the metrics display's tok/s and TTFT went stale, and
  the context-bar projection stopped updating. The
  hotfix reverts those six fields to read from the
  runtime (the write-side SoT) while keeping the
  streaming content / reasoning reads on the cubit (those
  mirrors landed in slices 23 + 24 and are stable).
  Follow-up slice to add the missing mirrors is tracked
  separately; until then the controller is the
  write-side SoT for the metrics fields and the cubit is
  the passive read-side mirror holding only the fields
  explicitly mirrored (`tokPerSec`, `ttftMs`,
  `contextTargetTokens`, `cacheHitPct`, streaming
  content / reasoning / tool-calls / timers).

- **`MetricsCubit` preserves `contextTargetTokens` across
  live-metric mirrors** (`09479d9`) — earlier slice
  dropped the field from the `updateLiveMetrics` mirror
  payload, so the context bar's `_lastSeenTarget`
  comparison froze after the first tick. The mirror
  re-includes the field and the bar's lerp animation
  now picks up subsequent changes correctly.

- **`chat_history.isResponding` resets on normal turn
  completion** (`234f676`) — the lifecycle flag was
  stuck `true` after a clean round end if the final
  delta's `onComplete` fired before the controller's
  `isResponding` flip propagated to the cubit. The
  cubit mirror in `SessionController.completeTurn` now
  fires synchronously with the controller write, so
  the history's "typing…" indicator clears at the same
  moment the runtime does.

- **TLDR updates + `/new` route through cubit mirrors**
  (`de5f953`) — both paths previously wrote to the
  controller but skipped the `ChatTurnCubit` mirror,
  so the history pane kept showing the pre-TLDR text
  and pre-`/new` session state until the next manual
  cubit refresh. Now both go through the mirror
  helpers so every controller write has a matching
  cubit write.

- **`SessionCubit` mirrors all controller writes**
  (`e7543f7`) — earlier slice missed several
  controller writes (queued messages, pending image
  stash, title-generation state) so the cubit drifted
  out of sync after any of those paths fired. The
  mirror now covers every controller write site, with
  a `session_controller_cubit_mirror_test` case for
  each (22 cases).

- **Stale `/image` command references removed** (`cbfbfdb`)
  — the docs + autocomplete entries referenced an
  `/image` slash command that was never landed.
  Cleaned up so the suggestion popover only shows
  commands that actually exist.

## [0.11.3] - 2026-07-03

c98915d

### Features

- **Version comes from a single source** (`c98915d`) — `pubspec.yaml`
  is now the only place the Crux version lives. The previous setup
  required `pubspec.yaml` and `bin/crux.dart` to stay in lock-step,
  and `tool/prepare_release.dart` had to keep both updated. The two
  could drift if anyone bumped one by hand and forgot the other —
  after a bad bump, `crux --version` could disagree with `pub` by
  a patch version.

  The release script now reads the version it just wrote into
  `pubspec.yaml` and regenerates a small `lib/src/version.dart`
  from it (`const String kCruxVersion = '0.11.2';`). `bin/crux.dart`
  imports the generated constant and adds the `v` prefix only at
  the two print sites (`--version` output and the splash-art
  corner). The prefix is a presentation concern, not part of the
  version itself, so it lives at the print site — the generated
  constant stays plain semver and matches what `pubspec.yaml`
  declares.

  `release.sh --commit` now stages `pubspec.yaml
  lib/src/version.dart README.md` (was: `pubspec.yaml
  bin/crux.dart README.md`). The README's narrative `当前版本` /
  `Current version` lines are intentionally not auto-bumped: they're
  prose for human readers, not code that gets compiled.

## [0.11.2] - 2026-07-03

0a8487a

### Features

- **Shared fuzzy-match library** (`21b5cce`) — a new
  `lib/src/utils/fuzzy_match.dart` module with a six-tier
  ranked matcher (exact, prefix, substring, initials prefix,
  initials subsequence, subsequence) plus the supporting
  `fuzzyRank` / `fuzzyRankMulti` / `isSubsequence` /
  `computeInitials` / `tokenizeForInitials` primitives. The
  slash-command autocomplete, the file browser's @-mention
  popover, and the read tool's "similar files" suggestion
  all now rank with the same algorithm, so the user gets
  consistent behavior across every suggestion popover in the
  TUI. Backed by `test/fuzzy_match_test.dart` (312 lines)
  that exercises every tier and the alias / CJK paths.

- **Slash-command suggestions survive typos** (`9d8f153`) —
  `CommandRegistry.filterCommands` and `filterSuggestions`
  now fuzzy-match the query instead of requiring a prefix,
  so `/cnt` still finds `/continue`, `/cmt` still finds
  `/compact`, and CJK aliases like `/继续` keep working via
  the alias path. The strongest match wins (exact → prefix
  → substring → initials → subsequence), so `/con` still
  ranks `/continue` first.

- **Read tool renders in the detail pane's Pretty tab**
  (`54ad403`) — `ReadTool.buildPrettyTab` mirrors the
  pane's built-in write/edit/read look: file path header,
  dim `(empty)` placeholder, or a syntax-highlighted
  scrollable code block for the content. Previously the
  pane fell through to the generic Raw view for the read
  tool, which dumped the entire output verbatim. The
  new pretty view gives the user a clean glance at the
  file the agent just read.

- **Read tool offers similar files on a missing path**
  (`54ad403`) — when the read tool can't find a path (typo,
  wrong directory), it now offers up to 5 entries in the
  same directory ranked by the shared fuzzy matcher.
  Replaces the old prefix-of-the-first-3-chars heuristic
  that missed most real-world typos. Directory entries
  are marked with a trailing separator so the suggestion
  list tells the user "hey, you can drill in here".

- **Reusable tool-detail building blocks**
  (`54ad403`) — extracted `fileHeader`, `dimText`,
  `scrollableCodeBlock`, and `languageFromPath` from
  `tool_detail_pane.dart`'s private state into a new
  `lib/src/components/tool_detail_utils.dart` module, so
  the read tool's new pretty tab (and any future per-tool
  pretty tabs) can reuse the same look the pane uses for
  its built-in write/edit/read views. The pane's private
  methods are now thin delegations; behavior and visual
  output are unchanged.

## [0.10.2] - 2026-07-02

76cf456

### Fixes

- **Cache hit percentage precision** — the cache hit rate in the
  metrics display now shows 3 decimal places (e.g. `cache 98.500%`)
  and the calculation was corrected (was producing values 10x too
  small due to a rounding coefficient error).

## [0.10.1] - 2026-06-26

1747489

### Fixes

- **Bundled `libcrux_grammars` dylib in the release** — the
  tree-sitter FFI library for semantic search was missing from
  the binary release bundle; `tool/build_release.dart` now
  copies it from the `semble-dart` submodule into
  `third_party/bin/<target>/` before assembly. The prior
  release silently skipped the symlink, so `semantic_search`
  would start but fail on first use.

- **Bundled `model.safetensors` + `tokenizer.json` in the
  release** — the Potion-code-16M embedding model (61 MB) and
  its WordPiece tokenizer are now copied from the local
  HuggingFace cache into `third_party/semblemodel/` during the
  build, matching `SembleClient._resolveModelPair`'s first
  local fallback path. The release is now self-contained —
  no dependency on `~/.cache/huggingface/` at runtime.

- **Restored pre-bloc chat-services split** — the `feature/dart-
  semble-integration` merge had committed the branch's monolithic
  `chat_service.dart` over the pre-existing refactor (facade +
  `wire_format.dart`, `chat_turn_executor.dart`, etc.). Restored
  the split so the orchestration layer compiles against the
  correct APIs.

### Removed

- **Bloc refactor** — the 76-commit `codex/nocterm-bloc-refactor`
  branch was fully reverted from master. The bridge commit that
  coupled the semble merge to the bloc cubit layer (`ChatTurnCubit`,
  `CompactionCubit`, etc.) is gone; master now continues from the
  clean v0.9.0 base with Semble + LongCat layered on top.

## [0.10.0] - 2026-06-26

e0e541d

### Features

- **In-process Dart Semble search** — `semantic_search` and
  `find_similar_code` now run through the Dart `semble_dart`
  package via `SembleClient`, eliminating the Python subprocess
  round-trip. The first search warmup loads the model and indexes
  the repo (~450 ms); subsequent searches average ~1 ms warm.
  Cross-platform: ships as a single self-contained Dart binary
  with the grammars dylib bundled in `third_party/bin/`. The
  python `semble` shim is no longer required.

- **LongCat provider** — add `longcat` as a built-in provider
  (`providers/longcat.toml`) backed by Meituan's LongCat API at
  `https://api.longcat.chat/openai/v1`. Uses the generic
  `type = "openai_compatible"` (Bearer auth) — no custom type
  registration needed in `llm_provider.dart`. Ships with the
  `LongCat-2.0` model (1M context, 128K max output, text-only,
  binary on/off thinking).

- **Per-provider stream watchdog overrides** — adds
  `stream_idle_timeout_ms` and `stream_max_duration_ms` to the
  provider TOML so models with very long thinking passes (e.g.
  LongCat) can opt into longer timeouts without affecting other
  providers. `null`/absent keeps the hardcoded defaults (120 s
  idle / 10 min max). The LongCat built-in ships with 20 min
  idle / 60 min max. `LlmClient.streamChat` reads the values
  off the `ProviderConfig`; the max-duration error message now
  uses a `_formatMaxDuration` helper so overridden values (e.g.
  25 min, 30 s) render readably. See
  `docs/llm-error-mapping.md` for the field reference.

### Fixes

- **Chunker byte→char offsets** — tree-sitter returns UTF-8 byte
  positions; the chunker now converts them to UTF-16 char indices
  before slicing `source`. Without this, chunks in files with
  non-ASCII characters (e.g. docstrings with `→` or CJK identifiers)
  shifted by 2–3 characters per non-ASCII codepoint. Fixed the
  end-line off-by-one (Python uses `end_index - 1` to skip a
  trailing newline) and dropped `.trimRight()` to match upstream's
  exact byte-for-byte chunk content.

- **BM25 enrichment + relative chunk paths** — the Dart BM25 index
  now appends the file stem (×2) and the last three directory
  components to each chunk's content (the upstream
  `semble.index.sparse.enrich_for_bm25`), so path-based queries
  ("how does chunking work?", "the tokens module") actually hit.
  Chunks are also stored with repo-relative paths now — previously
  the absolute `/tmp/.../bench-repo` prefix leaked into the BM25
  index, producing garbage tokens like `tmp` and `bench1`.

- **model2vec SIF weighting** — the embedding encode pipeline
  reads `weights` and `mapping` from the model artifact and applies
  Smooth Inverse Frequency weighting (`a / (a + p)` by token
  frequency), down-weighting common tokens (`def`, `class`,
  `import`) and up-weighting rare identifiers. This alone moved
  top-5 search overlap from 77.8% to 86.7% versus upstream Python.

- **Chunker 2000-byte hard cap + cache versioning** — the chunker
  now caps any single chunk at 2000 bytes (prevents pathological
  cases like a 90 KB regex from producing one unsearchable chunk)
  and the on-disk cache is versioned so a model or chunker change
  invalidates the cache automatically.

## [0.9.0] - 2026-06-26

72208b3

### Features

- **One-tap answers to the agent's questions** (`570dd76`, parser
  rewrite in `554914a`) — when the agent asks a discrete question
  ("Should I run the tests?", "Which approach?"), Crux renders each
  `ask://` option as a clickable button right in the reply. Click
  submits — or appends to your draft if you're already typing — so
  you never have to type out an answer the agent already wrote for
  you. The parser was rewritten so buttons whose labels contain
  inline code (e.g. `ask://run-test{run `npm test`}`) render
  correctly. See `docs/design-quick-reply.md` for the full spec.

- **Compaction that pays off the longer you use Crux** (`554914a`) —
  long sessions no longer get worse over time. Crux now rebuilds
  the chat summary from scratch on every compact (instead of
  stacking summaries on top of summaries), so a session has at
  most one summary at any time and the context bar reliably returns
  to a healthy size after each compact. The hover label tells you
  before you click: "X → Y" if a compact would meaningfully reduce
  tokens, "X . skip" if it wouldn't — and clicking "skip" is a
  no-op, so you stop paying for compacts that wouldn't help. The
  summary itself is slimmer too — just the files you read and
  wrote, not every search query — so the saved context is more
  useful per token.

- **Errors you can read, plus one-click retry** (`eeb1f3f`) — when
  a turn fails, you'll know exactly what went wrong and what to
  do next. The chat ends with a one-line bubble and a vendor-aware
  hint: "context too long — try /compact", "check your MiniMax API
  key" for a 401, "upstream overloaded — retry" for a 529, and so
  on. For recoverable failures, there's a clickable "▶ retry" that
  re-runs the same turn. The bubble stays visible until your next
  message — you don't lose the context of what failed. The previous
  opaque toasts are gone.

- **No more "stuck waiting for streams"** (`eeb1f3f`) — if the
  upstream goes silent for 120 seconds (long reasoning pass + socket
  keep-alive expiry, or the upstream dropping the connection
  without sending a final event), Crux now ends the stream with
  a typed timeout and surfaces the retry bubble above. Total
  stream duration is also capped at 10 minutes. A flaky network
  or upstream hiccup no longer leaves you staring at an
  unresponsive chat.

- **One error vocabulary across every provider** (`554914a`) —
  Anthropic, OpenAI, and MiniMax all now speak the same error
  language (rateLimit, auth, contextLength, overloaded, serverError,
  timeout, network, …), so "rate limited" reads as "rate limited"
  no matter which model you're on — and Crux can act on it
  (e.g., suggest `/compact` for context-length errors). See
  `docs/llm-error-mapping.md` for the cross-vendor reference.

- **Markdown links that look like links** (`77f3667`) — `[label](url)`
  now renders as just the label (no more "(url)" suffix cluttering
  replies), and clicking it opens the URL in your default browser.
  Replies stay scannable; URLs are still one click away when you
  want them. Empty-label links still show the URL so they're not
  invisible.

- **Agents that check before they answer** (`3bb6887`) — for
  project questions, the agent reads the code; for external
  libraries and APIs, it fetches the live docs. Stops agents from
  confidently handing you answers from stale training data when
  the real answer is one `semantic_search` or `webfetch` away.
  Contradicted recollection loses to a verified source, every
  time.

- **The context bar and its hover label now tell the same story**
  (`22473c8`) — the hover label reads "Y ← X" (post on the left,
  arrow pointing left) instead of "X → Y". The arrow points in
  the direction the bar actually moves when it shrinks after a
  compact, so the label and the bar read as one transition.
  `/compact` toasts follow the same convention.

- **Countdown that actually counts down** (`da7452f`) — hover the
  context bar for a 5-minute compact preview and watch the
  countdown tick down to 4:59, 4:58, 4:57, …. Previously it froze
  at "5m" forever once the remaining time crossed a threshold; now
  it decrements continuously for the full hover duration.

- **Ship a new version of Crux with one command** (`cec8dfa`) —
  `./release.sh 0.9.0` is the same pipeline `install.sh` uses, but
  running on your machine: bump the version, build the bundle for
  the current platform, install to `~/.crux/bin/`, done. Supports
  `--skip-bump`, `--no-install`, `--commit` (commit + tag the
  version bump), `--semble-bin` (path to a `semble` binary to
  bundle with the install), and `--clean` (delete the build output
  after install). The GitHub release flow is unchanged: tag-push
  still triggers `.github/workflows/release.yml`.

### Fixes

- **CJK input works again** (`1643a8e`, `1625163`) — typing in
  Chinese, Japanese, or Korean no longer hijacks the chat input.
  Confirmed characters used to (1) be treated as a file drop
  (because the IME wraps its output in bracketed-paste markers
  that looked like a drag-and-drop), and (2) silently attach
  whatever image was on your clipboard on top of the candidate
  text. If you've ever wondered why a screenshot you copied 10
  minutes ago kept showing up in your chat — this is why. Both
  paths now distinguish a synthetic IME paste from a real one,
  so IME input flows through as plain text.

- **macOS keyboard shortcuts that work the way you expect**
  (`4439b86`, `86a9d74`) — Option+Arrow jumps the cursor by word
  (with Shift+Option+Arrow extending the selection by a word),
  since macOS binds Ctrl+Arrow to Mission Control. Cmd+A, Cmd+C,
  Cmd+V, Cmd+X now do select-all / copy / paste / cut. Previously
  Cmd arrived as Meta under the kitty keyboard protocol and fell
  through to character insertion, so Cmd+A typed a literal "a"
  into your draft instead of selecting everything. Linux and
  Windows users get both Ctrl+Arrow and Alt+Arrow.

- **`websearch` is there on every cold start** (`b7aa0c4`) — save
  your TinyFish API key once in `auth.toml` and the `websearch`
  tool is there the moment you launch Crux. Previously the key
  was loaded into memory but the chat panel's listener never
  re-registered the tools, so `websearch` was permanently missing
  until you ran `/tinyfish` to re-set the key.

- **DeepSeek's reasoning effort picker tells the truth**
  (`5596032`) — DeepSeek only actually supports `high` and `max`
  (the other levels are API aliases that silently downgrade). Crux
  now shows only those two in the UI instead of a misleading
  5-level scale, and `high` stays `high` instead of being silently
  mapped to `max`.

- **Code highlighting no longer crashes startup** (`615f790`) —
  Crux used to ask for ~19 languages whose grammars weren't
  vendored, which crashed startup with "Could not find grammar
  file". It now requests only the three we actually ship (csharp,
  cpp, bash); other languages fall through to plain text. Fewer
  languages, but the ones you ask for work.

- **The session list scrolls when it overflows** (`ae4fbf3`) —
  if you have more than a screen's worth of sessions, you can
  actually reach them all now. The list is wrapped in a scroll
  container and auto-scrolls to the active session. Previously
  the list overflowed off-screen with no way to reach older
  sessions.

## [0.7.3] - 2026-06-23

0dbdc27

### Features

- **Web tools backed by TinyFish (provider-agnostic)** (`a964754`) —
  `webfetch` now routes through TinyFish's extract API when a key is
  set, returning clean structured markdown with title/description/
  metadata instead of raw HTML. New `websearch` tool (also
  TinyFish-backed) with auto-pagination across up to 5 pages,
  location/language hints, and optional thumbnails. Both tools are
  auto-registered only when a key is configured; the `/tinyfish`
  slash command stores the key in `auth.toml` (`TINYFISH_API_KEY`,
  `0o600`) and the registry streams a `changes` event so the chat
  panel rebuilds the tool list on key set/remove. 429/502/503/504
  are retried with `Retry-After`-aware backoff (1s/2s/4s, max 3
  attempts); no silent fallback to raw on provider failure. The
  provider surface (`WebServiceProvider` + `WebProviderRegistry`)
  is shaped so future providers (Exa, Firecrawl, …) slot in without
  touching tool code.

- **Code-search tier split: `semantic_search` + `find_similar_code`**
  (`c273791`) — splits the single Tier-1 `code_search` tool into two
  focused wrappers around the upstream `semble` binary:
  `semantic_search` (natural-language query → ranked snippets,
  ~600 ms across the whole codebase) and `find_similar_code`
  (file:line anchor → code semantically similar to that spot). Tool
  tiering formalized: Tier 1 = semantic/web/file-system search,
  Tier 2 = direct file ops, Tier 3 = general shell. Tool descriptions
  now teach the tier concept so the LLM picks the right tool for the
  question.

- **Hard-rule codebase exploration + Tier 1 tool reorder** (`a4bdbde`)
  — adds a `Codebase exploration` hard rule to the universal system
  prompt, placed right after the `Language (hard rule)` so the two
  behavior-anchoring rules sit together. The previous tier section
  (now further down) was a passive catalog of which tool lives in
  which tier — this rule makes the behavior explicit: Tier 1 is the
  default for any coding task where the user hasn't already pointed
  at a specific file. Also reorders `registerDefaults()` so the API
  tool list (which the LLM scans top-down) leads with Tier 1:
  `semantic_search`, `find_similar_code`, `webfetch`.

- **`code_search` preference hint — one-shot + 200k/400k/600k
  threshold re-fires** (`4cac87d`) — teaches the LLM that
  `code_search` (semantic search) is the preferred surface for
  "how does X work" / "find code that does X" questions. The hint is
  appended to the first `grep` or `glob` tool result in two
  situations: (1) an initial one-shot for the first successful
  `grep` or `glob` in the session; (2) re-fires each time the LLM's
  context crosses 200k, 400k, or 600k tokens (useful in long
  sessions where the original nudge might have fallen out of the
  recent context window). State persists in `SessionRuntimeState`.
  Multi-threshold context jumps handle sequentially across
  subsequent rounds, lowest-first. Companion to the existing
  shell-tool fallback guard's `codeSearch` verdict — this new hint
  catches direct `grep`/`glob` overuse, the shell verdict catches
  `bash | rg | head` fallbacks. 38 new tests.

- **Clickable session links (`ses://<id>`)** (`bbe4e84`) — let the
  agent reference other Crux sessions in its replies via the
  `ses://<id>` scheme and have the TUI turn those references into
  clickable buttons that jump straight to the target session. A new
  `session_refs.dart` utility walks the inline-span tree of a
  markdown rendering and finds every `ses://<digits>` reference
  OUTSIDE of code spans (heuristic: any span with non-null
  `backgroundColor` is treated as code, catching both inline code and
  fenced code blocks). `HighlightedMarkdownText` grows three optional
  props (`onSessionLinkTap`, `sessionLinkStyle`,
  `sessionLinkHoverStyle`); when the callback is null the parser is
  skipped entirely, so existing call sites pay zero cost. Session
  tool output now uses `ses://<id>` instead of bare `#<id>` so the
  agent sees the convention in context. `kCruxSystemPrompt` gains a
  `## Session references` section that teaches the format. 21 new
  tests.

- **Compacted-session back-link with source session's title**
  (`143b6c9`, `ae65106`) — replaces the bottom-of-compaction-bubble
  `Open previous session #N` button with a header that sits at the
  very top of the new session. The link uses the new `ses://<id>`
  clickable format and reads like a breadcrumb ("← Compacted from
  Home 界面开发计划") — the source session's actual title, falling
  back to `ses://<id>` when the title is empty or the source session
  was deleted. `ChatHistory._findCompactionSource` returns
  `({int id, String? title})` and resolves the title via
  `SessionController.findSession(id)`.

- **Streaming perf: delta-time animations, markdown isolate,
  reasoning block split** (`6a4a3f8`) — Phase 1 of the chat-panel
  perf roadmap. Three changes that together bring the chat panel
  back to ~60 fps during long LLM reasoning (was 25-40 fps on
  15+ kB preambles).

  1. *Delta-time animations.* `TickerCallback` is now
     `void Function(Duration elapsed)` so animation sites advance on
     the wall-clock tick delta instead of a fixed 16 ms step.
     Updated: streaming_bubble animator, context_bar,
     credit_balance_display, coding_plan_usage_display,
     glossy_model_button (sweep rate fixed to 25 cells/sec — was 4),
     extra_info_panel, toast, metrics_display, fps_counter,
     file_browser_overlay. Chat-service lerp timer now accumulates
     any frame budget over 16 ms and emits an extra char once that
     accumulated budget hits 16 ms, preserving the original
     alpha-flood behavior under varying frame rates.
  2. *Markdown isolate parsing.* `markdown_isolate.dart` ships a
     handshaken worker isolate. `HighlightedMarkdownText` opts in
     via `useIsolate: true` (default false for sync). Main thread
     just renders the latest parse result — no plain-text fallback,
     no incremental merging.
  3. *Reasoning block split.* Reasoning text is now split at `\n\n`
     paragraph boundaries into blocks of ≤4 kB each (see
     `reasoning_block_splitter.dart`, 14 new tests). Earlier blocks
     become frozen widgets — Flutter's element diffing reuses their
     layout elements, so per-frame layout cost is bounded by the
     size of the active (last) block rather than the full reasoning
     preamble. Streaming bubble renders the first block inline with
     the "Think:" label (preserving the original Row layout visual)
     and any subsequent blocks below, indented by the "Think:"
     width for left-margin continuity.

### Fixes

- **`ls | head` / `find | head` is `glob`, not `code_search`**
  (`5f12a1e`) — the `_isCodeSearchPipe` detector was treating
  list-verb + truncator patterns as code-search anti-patterns,
  conflating two distinct intents. `rg "auth" lib/ | head -10`
  wants matching snippets (use `code_search`); `ls -la build/ |
  head -5` wants a few directory entries (use `glob`); `find . -name
  "*.dart" | head -30` wants a few matching files (use `glob`). Fix:
  remove `listVerbs` from the code-search pipe check. Only search
  verbs (rg/grep/ack/ag) qualify. `ls | head` and `find | head` now
  fall through to the verb classifier and surface as `glob`. New
  regression test asserts the exact command from the user's
  screenshot classifies as `glob`.

- **Drop `code_search` verdict from shell-guard detector** (`c819ffb`)
  — too clever, false-positived on common patterns like `perl -pe
  's|x|y|' file.txt | grep "missing" | head -5`. New rule: classify
  by checking ONLY the first non-empty, non-shell-script-prefix
  segment. First verb is `grep`/`rg`/`ack`/`ag` → grep verdict;
  `cat`/`head`/`less`/`sed` → read; `ls`/`find`/`tree`/`du` → glob;
  `cd`/`echo`/`export` → skip, check the next segment; anything
  else (perl, dart, flutter, ps, env, git, curl, …) → no flag. No
  code_search detection, no path-arg heuristics, no pipe-pattern
  matching. `ShellGuardKind.codeSearch` enum value is kept for API
  stability but no longer returned. +71 net tests from the
  simplification.

- **Annotated scrollbar mouse capture release** (`d7e0af7`) — mouse
  now properly releases from the scrollbar annotation instead of
  staying captured.

- **`bash` / `code_search` description hardening** (`4784c8f`,
  `063f91c`, `c649e6e`, `57675d9`) — `bash` description now leads
  with a 🚨 CRITICAL marker and frames the DO-NOT-USE block as a
  hard rule. `code_search` description adds a 🚨 CRITICAL banner
  urging tool-first use, broadens the banner to an abstract rule
  (avoids overfitting on literal trigger phrasings), then trims the
  description to three core points: (1) way faster than grep/glob
  (~600 ms one call vs. grep+read loop); (2) semantic by concept,
  not literal substring; (3) reach for it BEFORE grep or glob.

- **Web tools: cold start with persisted key now registers `websearch`**
  (`b7aa0c4`) — `WebProviderRegistry._loadFromAuthToml` updated
  the in-memory key from `auth.toml` but did not fire the
  `changes` stream. The chat panel's listener therefore never
  re-ran `registerWebTools`, and a cold start with a persisted
  `TINYFISH_API_KEY` would have `websearch` permanently missing
  from the LLM's tool list. The fix fires the event when at least
  one key is loaded, matching `setApiKey` / `removeApiKey` semantics.

## [0.7.2] - 2026-06-22

d8f1e68

### Features

- **Async optimistic session switch + chunked load + virtualization**
  (`f123e98`) — five interlocking changes that have to land together:

  1. Split `switchSession` into `beginSwitchSession` (sync — flips
     `currentSessionId` + placeholder `contextTargetTokens`) and
     `completeSwitchSession` (async — does the DB I/O). The context
     bar's 16 ms ticker can no longer observe a half-flipped state.
  2. Chunked message loader pulls in 50+200 batches, latest first;
     first chunk is parallel with `COUNT(*)`. Most sessions fit in
     one round-trip; huge sessions fill fast after first paint.
  3. Chat panel runs `loadFileReadState(id)` in parallel with
     `completeSwitchSession(id)`.
  4. Chat history items are now `LazyChatItem` closures — off-screen
     bubbles' widget trees (markdown parses, tldr scans, …) are
     never built. `_currentReasoningPresets` is hoisted out of the
     per-message loop.
  5. Boot path loads only the first 50 messages + `COUNT(*)` in
     parallel; if more rows exist, `initState` kicks off the chunked
     loader in the background. Splash clears in ~200 ms instead of
     blocking until the full cold-cache read completes.

  End-to-end: cold-start 'loading messages…' flash drops from
  6–7 s to ~200 ms; `_buildInner` on a 1000-row session drops
  from 1–2 s to tens of ms.

- **Shell-tool fallback guard with 3-tier escalation** (`324d2d4`)
  — catches the LLM using `bash`/`cmd`/`powershell` for ops that
  have a dedicated tool (`read`/`grep`/`glob`/`code_search`) and
  applies `mild → firm → reject` tiers mirroring the existing
  single-call hint pattern. The streak resets the moment a proper
  tool succeeds.

  Detector covers `read` (cat/head/tail/less/sed/wc/file/stat/diff/
  Get-Content/type/more), `glob` (ls/find/tree/du/Get-ChildItem/dir),
  `grep` (grep/rg/ack/ag/Select-String/findstr), and `codeSearch`
  (the `rg "concept" | head` / `find … | head` shape). Smart skips:
  input redirects, no-arg `tail`, `FOO=bar cat f` env prefixes,
  absolute-path verbs. Shell-script leniency: `cd … && grep …`
  chains skip the grep verdict. 50 unit tests in
  `shell_guard_test.dart` cover detector, severity, rendering, and
  end-to-end streak persistence. `CRUX_DISABLE_SHELL_GUARD=1` to
  opt out.

- **Semantic code search via Semble + background warmup** (`f643648`)
  — wires up MinishLab/semble as a first-class tool for concept
  questions ("how does X work") that grep can't answer.
  `SembleSearchTool` returns ranked `file:line-range + content`
  snippets with similarity scores — grep-style output the agent
  already knows how to consume, not raw JSON.

  Lifecycle: `SembleWarmup.start()` fires fire-and-forget from
  `bin/crux.dart` parallel with the splash. The first
  `semble_search` call awaits the warmup so the user doesn't see
  a hang but also doesn't wait at the logo. After every tool round
  that mutated files, `SembleWarmup.refresh()` kicks a background
  cache-validation pass — the next query sees the fresh cache with
  zero user-visible delay.

  Semble is treated as an external CLI (Python, MIT, ~30 MB model).
  Crux ships no embedding model; users install semble separately
  and Crux finds it via `third_party/bin/` or `PATH`.

- **Switch release bundles to `dart build cli`** (`c0e6fde`) —
  native-assets bundling via `dart build cli` replaces the ad-hoc
  release script. `tool/build_release.dart` orchestrates
  `dart build cli` for the CLI binary, then layers `providers/`,
  `themes/`, and `third_party/` on top. Local builds only run on
  the current runtime; the CI matrix still produces all six
  targets.

### Fixes

- **Quote-aware shell segment splitting** (`b12b510`) — the naive
  splitter treated every `|`, `;`, `&&`, `||`, and `\n` as a
  separator even inside quoted strings, flagging
  `git commit -m 'feat: ... rg "x" | head ...'` as a read
  violation because `|` appeared in the prose.

  Replaced with a quote-aware state machine: single-quoted regions
  are fully literal, double-quoted regions honour backslash
  escapes, outside quotes `&&`/`||` take precedence over `&`/`|`.
  Added `_splitOnPipes` for `_isCodeSearchPipe` so the
  `search-verb | truncator` detector stops firing on `rg "x" | head`
  inside quoted strings.

  Not a full parser (heredocs, `$(…)`, `<(…)` are still misread) —
  those patterns are rare in the LLM's bash calls. 7 regression
  tests cover multi-line commit messages, quoted-string operators,
  mixed quoted/unquoted pipes, backslash-escaped pipes, and POSIX
  `&&`/`||` precedence.

- **Session tool returns the tail of the session, not the head**
  (`f293ed2`) — `MessageStore.getMessages` was ordering by
  `createdAt ASC` and slicing the first N, returning the *oldest*
  N messages of a long session — the opposite of what callers
  want. Switched to `id DESC` (monotonic PK, stable for the
  `beforeId` cursor) and reverse in memory.

  The "more messages exist — pass `beforeId=$lastId`" hint was
  pointing at the newest id on the page and computing
  `moreAvailable = total > lastId`, which conflates row count
  with id space. Now points at `filtered.first.id` (oldest) and
  computes `moreAvailable` from `total > filtered.length`
  (or `filtered.length == limit` when paging). Five new
  pagination tests pin the new contract.

- **Two `contextTokens` bugs + self-heal stale sessions**
  (`bf12e8b`) — two related bugs in the auto-compaction projection
  path, plus recovery for sessions that already got into a bad
  state.

  1. **Bug 1 — `session.contextTokens` reset to 0 on empty AI
     turn.** `_store.update` after an AI response wrote
     `contextTokens: promptTokens + completionTokens - reasoningTokens`
     unconditionally. When the LLM never reported usage (network
     error, user ESC, stream interrupted), all three were 0 and
     the persisted value was overwritten with 0 — losing the
     prior turn. Subsequent auto-compact checks routed through the
     buggy fallback (see #2), and the displayed context bar
     inflated by adding tool results on top of an
     effectively-missing last-AI prompt.
     **Fix:** only overwrite when `promptTokens > 0`; otherwise
     keep `session.contextTokens` as-is.
  2. **Bug 2 — fallback projection summed per-message cumulative
     `tokensIn`.** `estimateProjectedContextTokens`'s fallback
     (when `contextTokens` is 0) summed every AI message's
     `tokensIn + tokensOut`. Each AI's `tokensIn` is the full
     prompt size at that turn (already cumulative within the
     session), so summing N AI messages approximates N × final
     prompt. A session genuinely at 150 k would project to ~1 M
     and trigger compaction immediately.
     **Fix:** walk history backwards to find the LAST AI message
     with reported tokens; use that single value as the base.
     Mirrors the same fix in `computeBaseContext`'s fallback.

  **Hysteresis.** `SessionRuntimeState.turnsSinceLastCompact`
  skips the auto-compact check for 3 user turns after any compact
  (success or failure). Without this, a child session near the
  threshold would compact → grandchild in three user turns.
  `/compact` bypasses the gate.

  **Self-heal.** `SessionStore.repairStaleContextTokens()` is a
  one-shot UPDATE that reconstructs `context_tokens` from the
  last AI message's `tokensIn + tokensOut - reasoningTokens` for
  any session currently at 0 with at least one AI turn that
  reported tokens. Called fire-and-forget on app startup and from
  `crux --doctor` (new `[3/3]` step). Idempotent.

  **`/d-context` extended** to dump `contextTokens`, `tokensIn`,
  `tokensOut`, `modelConfig.contextSize`, `modelConfig.maxTokens`,
  `compaction.reserve`, `compaction.threshold`,
  `turnsSinceLastCompact`, and `compactFailures` so future
  context-window bugs are diagnosable from a single toast.

  11 unit tests in `chat_service_compaction_test.dart` pin the
  projection algorithm + the Bug 2 regression (M3 130 k → no
  trigger, 970 k → trigger).

- **`crux --analyze` is now clean** (`c2136db`) — `dart analyze`
  drops from 10 errors + 37 warnings to 0 of each. The errors were
  all `missing_required_argument` on `ToolRegistry.registerDefaults`
  after `sessionStore` became required; 6 test files + 1 tool
  driver were updated to pass it. Warnings swept: unused
  elements/imports/locals (`_writeHorizontalBorder`,
  `_kIsolateThreshold`, `_estimateCost`, `_registryWithWriteTool`,
  `_registryWithBashTool`, `_kMax`, `_send`, `clampedOpposite`,
  `meta`, `target`, and several peer/server bindings); spurious
  `@override` on `_FakeSink.isClosed` / `writeCharCodes` in 4
  `test/lsp/*` files; unnecessary type check on `_pipe.bOutput`;
  `// ignore: experimental_member_use` for `TableMigration` in
  `database.dart`.

- **Context-bar click disabled while the session is running**
  (`f6419ed`) — the context-bar widget was wired to manual
  compaction, but the orchestrator rejected the click mid-stream
  with "Cannot compact while AI is responding". Gate at the UX
  level instead: `ContextBar.disabled` suppresses the
  `GestureDetector`, hides the "Compact" hover label, and keeps
  the non-hover palette so the widget doesn't visually advertise
  an action it can't perform. The hint flips to
  "Compaction unavailable while the agent is responding."

## [0.7.1] - 2026-06-21

710a9d3

### Features

- Add macOS and Windows release builds (alongside existing Linux builds)
- Add `install.sh`: a single, platform-aware install script with a
  one-liner entry point (`curl … | bash`)
- Add a release-version helper for cutting new versions
- Add `/undo` command to discard the last round and restore the prompt
- Add the `session` tool for inspecting other Crux chat sessions

### Fixes

- Fix release target filtering so only intended platforms get built
- Fix auto-compaction double-counting and clarify related toasts
- Fix wording of the single-call reminder bubble
- Remove cost tracking (was unreliable and added noise to summaries)
- Restore `read_tool` work-in-progress: stable reads via stat-before / stat-after
- Disguise the urgent-tier single-call hint as user-voice coaching

## [0.7.0] - 2026-06-20

fa489f5

Initial public release of Crux as a terminal-based AI coding agent with
agentic orchestration. Daily-use ready, still iterating quickly.

### Features

- LSP integration with per-server isolate channels; diagnostics surfaced
  inline in chat history and tool result details
- Streaming chat bubble that shows in-flight tool calls with timing
- Parallel-call hint system with a three-tier reminder that escalates
  when the model keeps serializing independent tool calls
- Inline tool-result rendering for LSP diagnostics and write-tool guards
- Image input support (paste / drop an image into the prompt)
- Extra info panel with live git status (branch + ahead/behind label)
- `/quit` command and `Ctrl+C` show a per-run Crux Run Summary
  (duration, turns, tokens, cache hit %)
- `/compact` command plus automatic compaction into a child session
- System proxy fallback for transports that block upstream
- `messages.meta` carries inline UI hints for tool affordances
- Multi-platform release pipeline with Linux release artifacts
- README documents install, image input, release build, and 0.7.0 status