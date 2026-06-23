# Changelog

All notable changes to Crux are documented in this file.

Changes are grouped under each version, with the commit SHA on the line
below the version header. Each version has at most two categories:
**Features** and **Fixes**.

## [Unreleased]

### Features

- **Web tools backed by TinyFish (provider-agnostic)** — `webfetch`
  now routes through TinyFish's extract API when a key is set,
  returning clean structured markdown with title/description/metadata
  instead of raw HTML. New `websearch` tool (also TinyFish-backed)
  with auto-pagination across up to 5 pages, location/language
  hints, and optional thumbnails. Both tools are auto-registered
  only when a key is configured; the `/tinyfish` slash command
  stores the key in `auth.toml` (`TINYFISH_API_KEY`, `0o600`) and
  the registry streams a `changes` event so the chat panel
  rebuilds the tool list on key set/remove. 429/502/503/504 are
  retried with `Retry-After`-aware backoff (1s/2s/4s, max 3
  attempts); no silent fallback to raw on provider failure. The
  provider surface (`WebServiceProvider` + `WebProviderRegistry`)
  is shaped so future providers (Exa, Firecrawl, …) slot in
  without touching tool code.

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