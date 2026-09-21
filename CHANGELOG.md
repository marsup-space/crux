# Changelog

All notable changes to Crux are documented in this file.

Changes are grouped under each version, with the commit SHA on the line
below the version header. Each version has at most two categories:
**Features** and **Fixes**.

## [Unreleased]

### Features

- **Per-agent reasoning effort for subagents** — the agents table gains a
  `reasoning_effort` column (drift v38, nullable). Each roster row in the
  subagent config fullpane grows a `✶<next>` cycle segment (hover reveals
  it next to `delete`), cycling through the bound model's reasoning presets
  — the same preset resolution (provider base + TOML label overrides) as
  the toolbar's `✶` cycle button — plus a wrap-around back to `default`
  (null: no `reasoning_effort` on the wire, the provider's server default;
  `off` maps to thinking disabled). The current override shows as a `✶high`
  suffix in the row label. Read at each dispatch, so a change applies from
  the agent's next run; a live run keeps the value it started with.

- **prepare_commit: note + approval** — optional `note` displays a prominent
  banner at the top of the review pane, because the pane covers the chat and
  the user cannot see the agent message; optional `approval` (`commit`,
  `commit-push`, or `both`, the default) renders only the corresponding final
  approval button or buttons.

### Fixes

- **Home subagent box showed English constellation names under a zh locale**
  — the `subagent-pool` box rendered the persisted constellation id
  (`antlia`) directly, skipping the `WorkerNameLocalizer` every other
  subagent surface (agent bar, chat chips, config fullpane) renders through;
  a zh home now shows `✎ 唧筒座`, and unknown legacy names still pass
  through unchanged.

- **Git review cursor jumping** — opening the fullpane could leave the physical
  cursor visibly jumping across the screen with differential rendering when an
  unfocused dormant TextField (the file search box) remained in the focused
  subtree and IME cursor positioning became a no-op; the cursor is now hidden
  in that state.

## [1.1.4] - 2026-09-21

05c2a5c4

### Features

- **Bundled plugins — seeded to every install** — a new top-level
  `plugins/` directory ships plugin specs with each release
  (`build_release.dart` copies it next to the binary; `install.sh`
  installs it as a sibling asset like `providers/`/`themes/`). On
  launch, `seedBundledPlugins` (`lib/src/services/plugin_seeder.dart`)
  seeds those specs into the user's global `~/.crux/plugins/` so every
  user gets them in every workspace — non-destructively: a
  `.seeded.json` marker records what the seeder last wrote, user edits
  are never overwritten, upgrades replace only unmodified specs, and a
  deleted spec is never resurrected. First bundled spec: `my-notes`
  (moved from the crux repo's `.crux/plugins/`, previously visible only
  when working inside the crux checkout itself).

- **Workspace-scoped subagent roster** — the `agents` table gains a
  `project_path` column (drift v37) and its identity key changes from
  `UNIQUE(name)` to the composite `(project_path, name)`. Each workspace now
  sees only its own agents (`find_agents`, the subagent config fullpane, the
  home `subagent-pool` box) and allocates constellation names within its own
  scope — hiring `orion` in one project no longer occupies the name in
  another. Existing rows are backfilled with the `project_path` of the
  session that hired them; rows with no resolvable hiring session are
  retired (`''` matches no workspace), which is the safe direction — the
  cross-workspace leak they would otherwise represent is the bug being
  fixed.

### Fixes

- **Subagent round-cap now ends gracefully instead of hard-cutting the run**
  (`3dc8934b`, `e00160e8`) — hitting the round limit no longer aborts the run
  mid-stream: the runner appends a stop notice (limit reached, tools forbidden,
  produce an interim report) and makes one final tool-free LLM exchange whose
  prose becomes the report, with the requesting exchange keeping the exact same
  `tools` definitions as the main loop (so the provider prompt cache is not
  invalidated) and any tool call the model still makes refused at the system
  layer with a wire-format result plus a repeated notice, falling back to
  `round_cap_no_report` and the last prose only after the retries are exhausted.

- **Home subagent box dropped the workers/experts switches** (`7d1574cb`) —
  those toggles are per-session state (loaded per session by the controller)
  while the home box is a global workspace view, so the mismatch is removed: the
  box becomes a pure function of the roster, registers unconditionally
  (visibility via `visibleWhen`), and `HomeContext.subagentController` is deleted.

- **Agent bar round-count chip and color-only switches** (`05c2a5c4`) — in-flight
  chips now show the current run's round progress after the name (`12/40`, or a
  bare `12` when unlimited) via `SubagentUiEntry.roundProgress`/`roundLimit`, and
  the workers/experts toggles drop their `on`/`off` suffixes, expressing state
  through color instead (on = bold success green, off = dimmed, brightening on
  hover).

## [1.1.0] - 2026-09-19

fae62ca2

### Features

- **Subagent runtime v2 — roster, pools and `agent://`** (`fba91164`) — add a
  persistent `agents` roster (drift v33) that separates identity from execution
  (name / role / domain / bound model / status / knowledge / worklog / last
  intention), split the 87 IAU constellations into an expert pool (the 12 zodiac
  signs) and a worker pool, rename the advisor role to expert, and wire the
  `agent://` reference scheme, the `[subagent]` config section, the
  `/subagent workers|experts on|off` command and the toolbar mode bar.

- **Subagent runtime v2 — runner and five tools** (`f138e03a`) — run dispatched
  work on a background `SubagentRunner` that reuses the streaming client and tool
  executor so the main agent never blocks, with cancellation (stream force-close
  plus a partial report) and a 40-round cap; `SubagentManager` owns run
  lifecycle, per-model concurrency, queue/fork/cancel dispatch and budget
  normalization; the five tools (`find_agents` / `hire_agent` / `send_agent` /
  `check_agent` / `cancel_agent`) register statically with a redirect notice when
  the mode is off, and worker/expert prompt templates plus the five-part
  `[Crux system note — subagent report]` envelope are added.

- **Subagent runtime v2 — mode behavior** (`8e9ed36a`) — zero-cache-invalidation
  mode announcements ride the first user message after a toggle flip;
  `ToolExecutor.subagentWorkersGuard` redirects the main agent's mutating tools
  (`edit` / `write` / `bash` / `powershell` / `cmd` / `git_prepare_commit`) to
  `send_agent` while workers are on, leaving read-only tools free; worker and
  expert prompts share the main agent's engineering-rules section.

- **Subagent runtime v2 — UI data wiring** (`f5ea613c`) — render live in-flight
  chips in the agent bar (role glyph, localized constellation name, six-line
  tooltip fed the domain / intention / model / status), update the agents-box
  tool-name set to the v2 five tools (v1 names kept for replaying old sessions),
  and display `agent://` references with localized constellation names.

- **Subagent runtime v2 — three-stage context distillation** (`48319d10`) —
  a shared `SubagentDistiller` compacts on the first two fills and distills on
  the third into knowledge / worklog / instruction artifacts; subagents resume
  the same assignment from the instruction, and the main agent routes its third
  auto-compaction through the auxiliary model and rides the continuation on the
  next message without touching the system prompt.

- **Subagent configuration panel** (`c22e8185`, `7c6e0055`, `ae4a3d4d`) — the
  `subagent-config` fullpane and plugin render the worker and expert model pools
  side by side with a single shared keyboard cursor, per-model concurrency,
  inline add through a model picker, copy-on-edit Save to config.toml, and a
  read-only roster; a home `subagent-pool` box mirrors the live state.

- **Subagent UI shell (presentation-only)** (`c1b7eb33`) — re-land the toolbar
  row chips, the six-line hint tooltip, the vibe agents box, the display models,
  constellation naming/localization and the bilingual strings as components
  decoupled from the runtime; also drop empty user rows at the wire layer and
  make `truncateToWidth` CJK-aware.

- **Toolbar and home agent chips** (`e322e46f`, `1ff35d6c`, `06b3d8b7`,
  `716faec4`) — animate in-flight agents as busy in the bar, turn the home
  Agents box into a scrollable chip list (role glyph + name + domain / model /
  status badges), render `agent://` references as role chips, and wire
  `chat_panel` for a persistent bar, per-session chip scoping, report
  persistence and roster caching.

- **Per-session subagent mode and agent ownership** (`39340591`) — persist the
  workers/experts toggles per session (drift v34; `NULL` falls back to the global
  default) and record each agent's creating and last-using session (v35/v36), so
  a run's chip stays in the session that dispatched it.

- **Subagent prompting: narrow domains and `agent://` references** (`73ed7a11`,
  `2ca3a47e`, `d3830461`) — make "doing the work" include investigation and
  diagnosis, require narrow user-language domains and mandate `agent://`
  references everywhere; `hire_agent` now rejects an empty domain, and
  `canonicalSubagentSection` normalizes singular/plural section names.

- **`/upgrade` command** (`b5ec6af8`, `0fccc0a0`, `ab31fb9d`) — pull the latest
  published release and replace `crux` and `cruxd` in place; refuse to run under
  a JIT / `dart run` build, install via write-to-temp + rename, stop `cruxd`
  before replacing it, resolve versions through the `releases/latest` redirect
  (avoiding the anonymous 60/hour API limit), and reach GitHub through the system
  proxy then a mirror chain for censored networks.

- **cruxd sidecar shipped and installed; installer converged** (`8e1d82c8`) —
  the release bundle now builds and ships `bin/cruxd` (previously any plugin
  declaring a `[producer]` silently never got one), and the installer accepts
  only the three published targets.

- **Single source of truth for published targets** (`b375c41c`) — move
  `kPublishedCruxTargets` into `bundled_executable.dart` and share it across the
  build tool, `install.sh`, `release.yml` and `/upgrade`; the builder now fails
  in CI when asked for an unpublished target, and a test pins the four artifacts
  together.

- **ripgrep first-download proxy/mirror chain with per-attempt verification**
  (`7a4575e2`) — route `ensureRipgrep` through the shared transport chain
  (direct → system proxy → gh-proxy mirrors) and verify the sha256 inside each
  attempt, so a mirror returning an HTML error page advances instead of failing
  the install.

- **Structured-answer prompt hardening** (`8d57155b`) — replace the terse
  diagram guidance with concise, triggerable rules (tables for comparisons,
  Mermaid/D2 for flows and relationships, GenUI surfaces for choices,
  configuration, review and progress), with table rules extended to Chat mode.

- **OpenRouter Stealth moves to Union Alpha** (`49fd8f68`) — switch the free
  provider from the deprecated Ox Alpha to Union Alpha with refreshed
  context/image/output/reasoning config, and permanently exclude Ox Alpha from
  future syncs.

### Fixes

- **Unsupported-model image sends 400 the whole session** (`e435aa3e`,
  `0590e4a3`) — a pre-send capability gate drops images the active model can't
  see (naming the model in a toast) and the wire layer's `includeImages` switch
  is actually wired, so a pasted screenshot no longer poisons every later turn
  with `invalidRequest` / code 1210; `deepseek-v4-flash` is declared
  image-capable.

- **Subagent budget probe read empty coding-plan snapshots** (`cb2d50aa`) —
  cache providers by name so coding-plan quota state is shared, wait for a first
  snapshot, and take the worst window, so a drained plan reads `exhausted`
  instead of `ample`.

- **Mid-turn subagent reports were dropped** (`30f0704f`) — the envelope's first
  line was shown as the summary and a report arriving while the main agent was
  streaming vanished; reports now parse the `report:` block, queue, and drain
  after the turn, and the envelope no longer renders as a `You:` line in vibe
  mode.

- **`SubagentRunner.start()` aborted every tool call** (`749dfb41`) — a stray
  `_abort.abort()` marked each run aborted at start so no tool ever executed; the
  signal is now set only by `cancel()`.

- **Vibe mode rendered the mode announcement as a user turn** (`44c5ec92`) —
  strip the `[Crux system note — subagent mode on/off]` block from user bubbles
  and jump-bar labels, and show ready agents in the bar as well as in-flight
  ones.

- **Parallel tests fought over the process cwd** (`e458b575`) — `SessionController`
  hard-coded `Directory.current` in 11 places, so concurrently running suites
  that changed the cwd raced; the project path is now injectable.

## [1.0.2] - 2026-09-12

ff4dd008

### Fixes

- **Windows Semble runtime** (`ff4dd008`) — export the Tree-sitter and Dart
  FFI symbols from the MinGW grammar DLL, and make the Windows release build
  load that DLL and parse real Dart and Python code before packaging.

## [1.0.1] - 2026-09-11

723e2cfa

### Features

- **Kimi K2.8 Preview** (`e7883474`) — update the standard
  `kimi-for-coding` entry in place, so existing sessions automatically
  use K2.8 Preview with its 1M context window and low/high/max thinking
  levels; retain K2.7's binary-thinking behavior only for HighSpeed.

### Fixes

- **Release installer version sync** (`723e2cfa`) — make the release
  preparation command update both READMEs and the Bash/PowerShell installer
  examples and defaults, preventing a release tag from publishing stale
  install commands.

## [1.0.0] - 2026-09-10

677b4764

### Features

- **Stable 1.0 release** (`677b4764`) — promotes the RC2 feature set to the
  first stable Crux release, including the terminal-native workbench, GenUI
  surfaces, provider setup, Git review flow, and the open-source-ready
  documentation and CI baseline.

## [1.0.0-rc.2] - 2026-09-07

1666787e

### Fixes

- **Codex coding-plan usage** (`ee27d511`) — support the current
  `/backend-api/wham/usage` response shape, including singular `rate_limit`,
  `primary_window` / `secondary_window`, second-based window lengths, and the
  latest reset-time fields, restoring the five-hour and weekly usage readout.

- **Release version assertion** (`1666787e`) — make the home-screen release
  gate assert the generated Crux version instead of a stale `v0.` prefix, so
  candidate releases continue to pass the full suite after the 1.0 version
  transition.

## [1.0.0-rc.1] - 2026-09-06

40864247

### Features

- **Generative UI surfaces** (`48a386bf`) — agents can create compact,
  interactive terminal-native surfaces directly in chat or prose: a typed A2UI
  catalog covers cards, forms, buttons, choice pickers, tables, progress bars,
  lists, metrics and status badges; data bindings and `surface_update` support
  live refresh; submitted forms persist as read-only history and Vibe renders
  tool-created and inline `<a2ui>` surfaces.

- **Reusable dashboard surfaces** (`e1286caa`) — the same surface declaration
  model now powers app-owned home and plugin content, including responsive
  dashboard primitives, usage bars, compact list widgets and the gold tracker.

- **ChatGPT Codex OAuth and setup flow** (`f94d080d`) — Crux can authenticate
  with ChatGPT device-code OAuth, adds guided setup, and includes a reviewed
  Git commit flow.

### Fixes

- **Surface interaction and layout reliability** (`fa318576`) — clickable
  `ListItem` rows now dispatch their declared actions (including Home quick
  actions); provider-mangled payloads, history restoration, focus release,
  inline parsing, narrow cards and CJK table/progress-bar layout are hardened.

- **Release builds on Windows** (`5becef76`) — the grammar builder now uses
  MSYS2 MinGW and links the ICU Unicode runtime required by Tree-sitter, so the
  Windows release bundle builds alongside macOS and Linux.

- **Chat, diagrams and tools** (`5e75f339`) — interrupted HTTP streams release
  their lease promptly, diagrams retain their highlighted edges, clipboard
  images remain available while loading, shell output respects its budget, and
  responsive input/home layout regressions are fixed.

## [0.56.0] - 2026-09-03

22125675

### Features

- **Diagrams: drag-only vertical pan when the canvas is clipped**
  (`bf012767`) — the diagram viewport still fits the whole graph by
  default, but cramped ancestors (small window, split pane) that
  clamp the height below the graph now get vertical panning as a
  pure fallback: drag pans both axes from the pointer-down position,
  vertical following only while rows are clipped; the footer shows
  down/both/up glyphs for the clipped direction. The wheel is never
  consumed by the canvas — it always chains to the enclosing chat
  scroll, which removes the wheel-hijack-at-edge awkwardness.

- **Shell: live per-run view — executing row + detail fullpane**
  (`07b1d309`) — executing shell calls in the vibe tools box break
  out of the aggregated "bash xN" row into one interactive row per
  call, showing the agent's intent phrase plus a live elapsed timer;
  hovering morphs the row into a `detail` action. The detail opens a
  terminal-style fullpane with a rolling output tail (64KB,
  follow-tail), the aux monitor's full check timeline (verdict,
  elapsed, new bytes, interval, reason), and a kill button scoped to
  this run's process group — stamped with the same agent-visible
  kill note as a toast kill. Toast noise drops accordingly: only
  STUCK and FALLBACK still toast; the other verdicts live on the
  fullpane timeline. The parsed-progress pipeline (progress box in
  both vibe bubbles) is retired end to end (`22125675`) — the live
  row + fullpane carry information the parsed meter never had.

### Fixes

- **Interrupt no longer swallows the next user message**
  (`6200cac0`) — interrupt only set a cancel flag checked between
  stream chunks and never closed the in-flight HTTP response, so a
  stalled provider stream held the lease indefinitely and the next
  message was silently dropped after the input box cleared. The
  cancel token is now force-closed per streaming round (lease
  releases in milliseconds even on a dead stream), a stale cancel
  flag is cleared at the next turn start, and if the lease still
  isn't released the text is restored to the input box with a toast
  instead of vanishing. An interrupt-produced empty round no longer
  trips the empty-stream auto-retry.

## [0.55.0] - 2026-09-02

9fe6d99e

### Features

- **V language (vlang) support: LSP + syntax highlighting**
  (`9fe6d99e`) — `.v` / `.vsh` / `.vh` files now get language-server
  feedback end to end: a declarative `v-analyzer` actor in the LSP
  registry (PATH lookup, `v.mod` / `v.mod.txt` / `v.analyzer.toml`
  root markers) plus a GitHub-release installer that downloads the
  official `vlang/v-analyzer` binary per platform into the Crux tool
  dir (respects `CRUX_DISABLE_LSP_DOWNLOAD`), so edit/write report
  V diagnostics through the usual `⎇` glyph and `<crux-lsp>` payload.
  Syntax highlighting ships the official `vscode-vlang` TextMate
  grammar (vendored into textmate_highlight, `$1` scope interpolation
  and oniguruma `{,2}` quantifier ported to plain-regex equivalents)
  wired into the chat markdown renderer, the highlight service (with
  `vsh`/`vh`/`vlang` fence-tag aliases), and the tool-detail extension
  map, so ` ```v ` code fences and `.v` diffs render in color.

## [0.54.0] - 2026-09-01

447a30cd

### Features

- **Monitor: human-in-the-loop shell toasts + zero-progress escalation**
  (`447a30cd`) — the aux shell progress monitor was invisible: a
  long-running command was judged silently and the user could not
  see what was running, what the aux model decided, or when it
  would look again. Every monitor evaluation now surfaces as a
  standing killable toast — the intent phrase as headline, the
  verdict on its own colored row (PROGRESS green / STUCK red /
  UNCERTAIN amber), the model's reason and the process's last
  output line as dim evidence, and a `[ click to kill ]` button
  that terminates the process group the same way a user interrupt
  does, freezes the toast as a "✓ killed" incident record, and
  notifies the main session so the agent continues from partial
  output instead of retrying. All wording is localized (en + zh).
  Additionally, a fully-silent process (0B new output,
  byte-identical tail) can no longer run for tens of minutes while
  the model keeps answering PROGRESS: after 3 stalled checks the
  monitor conversation carries an explicit WARNING and re-checks
  are forced to 20s; after 8 the loop overrides the verdict to
  STUCK and kills, logged with the escalation reason. Fail-open
  semantics are untouched for any process that keeps producing
  output.

## [0.53.0] - 2026-08-31

cd462647

### Features

- **Sessions: session manager search + archived sections**
  (`cd462647`) — the session management fullpane could only list
  in-memory non-archived sessions: archived rows (auto-archive after
  3 idle days) were invisible, and there was no way to find an old
  session besides paging the sidebar. The panel now loads the full
  candidate set on open (`SessionStore.listAny()`: active + archived
  rows, sessions + chats, newest-first, capped at 500 so old
  databases can't stall the pane) and renders four sections —
  Sessions / **Archived** / Chats / Chats Archived — with an
  ` archived ` tag on archived rows. A type-to-search box filters by
  title substring (case-insensitive) or `#id` prefix; any printable
  keystroke enters search, Esc clears the query then closes, and
  ↑↓ walk the filtered list while the panel's key handler owns the
  input (rune-wise backspace, CJK/emoji safe — the Fullpane
  Focusable owns focus, so the TextField is display-only).

  Behaviour rules: Enter on an archived row **unarchives** it via
  the same path a `ses://<id>` link uses
  (`SessionController.openSession(id)`, generalized from
  `openSessionFromLink` which remains as a delegate) before
  switching; delete also drops the row from the panel's snapshot so
  the live-list merge can't resurrect it; rename stays blocked on
  archived rows (the rename store path writes `updatedAt` and would
  silently reorder the recency list). Panel keeps rendering (old
  two-section behaviour) for hosts that don't wire the new loader —
  existing tests and preview call sites unchanged. Backed by
  `test/session_management_panel_test.dart`: archived-section
  rendering, search filtering to an archived row, `#id` lookup, and
  archived-row Enter routing through `onOpenSession`.

## [0.52.1] - 2026-08-31

3de2946b

### Fixes

- **Diagram: wheel over a diagram scroll the chat, not the canvas**
  (`3de2946b`) — the drag-to-pan viewport (0.52.0) also consumed wheel
  events for horizontal panning, chaining to the vertical scroll only
  at the pan edge. In practice that wheel hijack felt broken: the
  wheel's intent is vertical, and diagrams sit inside the chat flow.
  The render object no longer implements ScrollableRenderObjectMixin —
  the wheel always chains to the enclosing chat scroll, and **drag is
  the only pan gesture**. A regression test pins that wheel up/down
  over the canvas leaves the drawn diagram unmoved.

## [0.52.0] - 2026-08-31

fe27817e

### Features

- **Diagram: drag-to-pan viewport for mermaid/d2 fences**
  (`fe27817e`) — diagram fences no longer shrink+truncate to fit the
  chat width. A parseable fence in the sync markdown path lifts out
  of the TextSpan tree (no WidgetSpan in nocterm) into its own
  render object. `RenderDiagramViewport` is a drag-to-pan canvas:
  press captures the mouse (annotation.capturing), the pointer delta
  from the DOWN position pans horizontally, release ends the drag
  and drops capture; the wheel pans until the edge, then chains to
  the enclosing vertical scroll. Height always fits the whole graph
  — only horizontal overflow pans — and a footer `◀──●──▶` strip
  shows the pan position; the fence keeps its ╭─ &lt;lang&gt; frame.

### Fixes

- **Diagram: chain-edge collapse dropped middle nodes**
  (`fe27817e`) — the labelled-arrow regex `--([^|]*?)--+>` backtracked
  across arbitrary node text, so `A --> B --> C --> D` parsed as
  `A -> C` and silently dropped B and D. Plain `-->` is now matched
  before the labelled form, the label character class excludes
  `>`/leading `-`, and `_parseEdgeChain` is a strict
  node→edge→node loop (the old loop could truncate a chain when a
  node token preceded an operator).

## [0.51.0] - 2026-08-31

69decf83

### Features

- **Input: Tab session cycle reworked as a rotating ring**
  (`a9cb4b48`) — the first cut recomputed a priority target on every
  press (always the newest active session while one existed), so Tab
  never reached the done/interrupted stops and could not walk between
  several streaming sessions. The sessions now form a fixed ring:
  `buildTabCycleRing` lays out active (newest-first, incl. chats) →
  done → interrupted with every session appearing once, and
  `TabCycleRing.step` advances or retreats exactly one stop from the
  current session's own position, wrapping at both ends. Tab = next
  stop, Shift+Tab = previous stop (replacing the pinned "previous"
  stop and the last-visited bookkeeping); Ctrl/Alt+Tab and open
  overlays still fall through, home quick-chat keeps grid-navigation
  Tab.

- **Scrollbar: theme-colored thumb, track line dropped**
  (`edc00433`) — all Scrollbar/ChatScrollbar/PlanScrollbar call sites
  now pass opaque theme tokens (thumb = `onSurfaceDim`), no track
  color: the `withOpacity` pre-dilution was stacking with nocterm's
  internal state factors and collapsing every theme to a uniform
  grey. Chat/Plan scrollbars previously fell back to near-white
  `onSurface`; they now get the chosen theme color explicitly. Bumps
  nocterm to `c04cb0b` (raised thumb state alphas, track removed).

### Fixes

- **Scrollbar: marker tooltips anchored in global coords**
  (`69decf83`) — `markerSourceBounds` now returns the marker cell in
  global terminal coordinates (local position + the render object's
  last paint offset) — the same frame mouse events and hit-testing
  use — so the hover anchor and tooltip anchor can never disagree
  when the scrollbar is nested away from the app root.

- **Highlighting: missing grammars no longer fail initialization**
  (`ae59ba20`) — bumps textmate_highlight `24abf0d` → `5566303`:
  `initialize` skips unavailable grammars instead of failing the
  whole registry, and grammar inclusion regexes are scoped to the
  current line so cross-line subject text can't hijack pattern
  matching.

## [0.50.0] - 2026-08-27

42194e11

### Features

- **Diagram: `<br>` multi-line labels + shrink/truncate width fit +
  tighter gaps** (`2f435f06`) — mermaid/D2 `<br>`/`<br/>`/`<br />`
  normalize to real newlines so node labels lay out multi-line, and
  later declarations upgrade a bare id's label in place (mermaid
  `A --> B[Full Name]` chains now work). Width overflow is fixed in
  the layout itself: pass 1 re-layouts with tight node padding,
  pass 2 greedily truncates the widest label line with an ellipsis
  until the drawing fits `maxWidth` — rows are never wrapped by the
  text renderer, wrapping tears box borders. hGap/vGap tightened to
  4/3 for every direction (arrows sit exactly one shaft row from
  boxes); the renderer's left pad drops from 16 to 2 and
  label-centering is clamped inside the border columns.

- **Home: tokens box model display names + layout-aware bars**
  (`43a18bbc`) — the per-model breakdown arrives keyed by the raw
  composite `provider/modelId`; ChatPanel now maps keys to the
  TOML display names so the bar chart labels models like the rest
  of the UI (unresolvable/renamed keys fall back to themselves).
  Bar rows fill the box width via LayoutBuilder: the label column
  sizes to the longest display name actually shown (clamped
  14–20), counts right-align as one column against the edge, and
  the bar track takes the remainder; unbounded tests/previews keep
  a fixed track.

- **Providers: GMI aggressive retry budget** (`42194e11`) — GMI's
  free/preview tier occasionally 5xxs or drops mid-handshake;
  `providers/gmi.toml` now sets `max_retries = 12` /
  `retry_base_delay_ms = 250` (ladder up to a 30 s cap, identical
  knobs to `openrouter-free.toml`), trading ~92 s worst-case wait
  for a much higher first-attempt success rate.

- **Providers: zhipu slimmed to GLM-5.3 + new GLM-5.3-Flash** —
  the GLM Coding Plan now serves exactly two models; the five
  legacy entries (`glm-5.2`, `glm-5.1`, `glm-5-turbo`,
  `glm-4.7`, `glm-4.5-air`) are removed since upstream
  auto-redirects them (`glm-5.2`/`glm-5.1` → `glm-5.3`,
  `glm-5-turbo`/`glm-4.7` → `glm-5.3-flash`). The new
  `glm-5.3-flash` is natively multimodal (image support on), 1M
  context, always-on thinking, ~1/3 the credit cost of GLM-5.3.

- **Plugins: widget system renamed + placement (sidebar / home /
  both) + global plugins** — the spec-widget system is renamed to
  **plugins** with three new capabilities. (1) **Placement**: a
  spec's new `placement` key (`sidebar` — default, `home`, `both`)
  renders it on the side panel, the home dashboard grid, or both;
  home boxes are first-class grid citizens (reorder / resize /
  hide in edit mode; `Enter` fires the first available action) and
  share the exact content renderer + wiring with the sidebar row,
  so a plugin behaves identically wherever placed. (2) **Global
  plugins**: `~/.crux/plugins/*.toml` works in every project —
  the spec lives in the user's home but status paths and commands
  resolve against the current project. (3) **Fit-the-need
  prompting**: the built-in `plugin` skill (renamed from `widget`)
  and the system prompt now lead with the two jobs a plugin exists
  for — STATUS that answers a question the user actually asks,
  and ACTIONS that turn a repeated command into one click — plus
  hard rules against the common failure mode (generic labels,
  decorative buttons, unasked-for dashboards): restate the need in
  one sentence before writing, labels must answer the user's
  question, every button earns its place, propose before
  surprising. Renames throughout: `.crux/plugins/` (legacy
  `.crux/widgets/` still scanned), `plugins` tool (was `widgets`),
  `plugin` skill (was `widget`), `PluginRegistry`/`Plugin`/
  `PluginContent`/`PluginSidebarBox`/`PluginHomeWidget` Dart
  types; seeds moved to `.crux/plugins/dev-harness.toml` +
  `my-notes.toml`.

### Fixes

- **LLM: empty-stream auto-retry now covers every OpenRouter
  free-tier drop shape** — the free stealth tier (stealth/ox-alpha)
  dies in several ways that all used to end as a silent empty AI
  bubble and a stalled turn. The empty-stream auto-retry now catches
  all of them, keyed on one honest signal — **did the round produce
  any output?** — instead of trusting `finish_reason`:
  (1) a bare `data: [DONE]` with zero deltas (LlmClient now reports
  that as `finishReason: 'done'`, not `'stop'`, so the retry fires);
  (2) a bare connection close with no chunks at all;
  (3) a clean stream carrying an upstream-specific or *blank*
  `finish_reason` (OpenRouter documents blank finish_reason for empty
  completions, so a finish reason is no longer treated as proof the
  model produced anything);
  (4) a **non-retriable** error chunk or thrown exception that still
  produced zero output — OpenRouter sometimes reports an upstream drop
  as a terminal 502/unknown error; with nothing to lose, these retry
  as `overloaded` too. Credential errors (`auth`/`permission`/
  `billing`/`quota`) and `invalidRequest` are deliberately exempt from
  the zero-output retry (retrying the same key never helps, and
  `invalidRequest` covers the orphan-tool 2013 shape whose dedicated
  repair path must run instead). Also tightened the free tier's stall
  tolerance: `providers/openrouter-free.toml` sets
  `stream_idle_timeout_ms = 45000` (was the 120s default) so a dead
  connection retries fast instead of sitting for two minutes, and the
  stealth sync's `write()` now preserves the provider-level
  `stream_idle_timeout_ms` / `stream_max_duration_ms` instead of
  silently dropping them on rewrite. New tests pin the `[DONE]`
  contract (empty → `done`, content → `stop`), the executor's
  empty-stream retry loop across all four drop shapes plus the
  exemption list, and the sync watchdog-field round-trip.

- **`my notes` todo list scrolls instead of "+N more"** — the notes
  projection (`.dart_tool/my_notes.json`) now carries **all** open
  todos (was capped at 3 with a `… +N more` overflow line in
  `display`). The home-grid `my notes` box renders the full list and
  scrolls inside its existing box scroll area (scrollbar thumb
  signals more below); the sidebar `my-notes` plugin caps its list
  at 10 visible rows and scrolls inside a scrollbar'd area — count
  line and `open` button stay fixed. nocterm: scrollable viewports
  now do scroll chaining (a wheel that hits an edge hands the event
  to the enclosing scrollable), and the test binding routes wheel
  events like the production binding does.

- **i18n: auxiliary title generation follows the reply-language
  setting** — the auxiliary model's session-title prompt used to
  hardcode "use the same language as the user", so with
  `/reply-language follow` + `/language zh` a session titled from an
  English first message landed in English even though the main agent
  replies in Chinese. `AuxiliaryService` now receives the live
  `ReplyLanguageProvider` via constructor injection (threaded from
  `ChatService` and `ChatTurnExecutor`) and resolves the policy at
  call time: `follow` injects the UI locale's label into
  `titleSystemPromptFor(...)`, `auto` keeps the historical
  match-the-user behaviour.   `titleSystemPrompt` remains as a backwards-compatible alias.

## [0.30.0] - 2026-08-14

4f08887d

### Features

- **i18n: UI language switching via `/language`** (`8803861d`) — a new
  `/language` command switches the whole UI between Chinese and
  English, persisted per-project to the config store. Ship with an
  en/zh string catalog (`lib/src/i18n/`) and a
  `LocaleController` that repaints live without a restart.
- **i18n: all UI chrome localizable through the string catalog**
  (`4fb0dfa2`, `1eb4611d`, `4f08887d`) — home screen and all 12
  widgets, command descriptions + toasts, chat input placeholder,
  toolbar hints, context bar, sidebar buttons, session manager, tool
  detail pane, fullpane titles, compaction feedback, git status,
  vibe box titles, and the You:/Crux: message prefixes all resolve
  through the catalog. Width-sensitive alignment uses nocterm's
  `stringWidth()`/`padToWidth()`, so CJK and latin mix without
  special-casing. A `/reply-language` command sets the language the
  model uses in its replies (concurrent-session aware).
- **Home: full-featured quick-chat input** (`2ecbde10`, `993c5f5e`) —
  the home dashboard gains a one-line quick-chat field that starts a
  fresh Chat-mode session with the typed prompt and leaves home for
  the chat screen. The input reuses the chat input's full overlay
  machinery: slash-command completion, @/#/$ mentions, and chip
  styling, extracted into shared `InputOverlay`/`InputKeyHandler`/
  `OverlayController` helpers with the popover in a shared widget.
- **Home: settings box** (`849c079a`) — a dashboard box showing the
  current theme id, auxiliary model, chat display mode, and
  (read-only) language; activating a row seeds the matching slash
  command into the chat input and stays on home.
- **Home: usage boxes — coding-plan per provider + today stats**
  (`035bc64e`) — a `coding-plan` box lists every connected provider's
  live usage (5h/7d remaining for Kimi/Zhipu/MiniMax, API credit for
  DeepSeek), polling all connected providers, not just the active
  session's; the `today` box now shows tokens, conversation turns,
  and active-session counts via a `MessageStore.dailyUsageStats`
  aggregate.
- **Home: Quick Start setup checklist** (`4a0a3bb7`) — a first-run
  checklist (provider key, aux model, web provider, workspace)
  computed live from the home context that ticks itself off as items
  complete elsewhere; pending rows seed the matching command, and the
  box hides itself once everything is set.
- **Home: day navigation for tokens & yesterday boxes** (`1d3ff5d5`) —
  the tokens box walks the calendar with ‹ › title buttons ([ ] keys
  on the focused box); the yesterday box opens on the most recent day
  with activity and navigates up to 7 days back, each day's summary
  cached so stepping never re-calls the model.
- **Home: coding-plan hover shows remaining-time countdown**
  (`f66d12cb`) — hovering the coding-plan box's remaining window
  shows the live countdown to its reset.
- **Chat: click the model button to interrupt streaming**
  (`178b5411`) — the toolbar's model button (which already flashes
  while streaming) now interrupts the in-flight response on click,
  replacing the ESC×2 gesture; idle, the same button opens the
  /model picker. A plain ESC in the chat input now navigates home.
- **Home: my-notes dashboard box** (`943553f6`) — a `my-notes` box
  shares the sidebar widget's data and interactions: open-todo count
  inline with an `open` button, and clickable todo rows that mark
  done / restore via the shared `NotesService`.
- **Notes: per-project my-notes widget with todo tracking**
  (`30c5254a`) — a spec-driven "my notes" sidebar widget backed by a
  per-project markdown note in the crux DB (`project_notes` table,
  schema v30); the DB row is the source of truth and a
  `.dart_tool/my_notes.json` projection drives the generic TOML
  widget with open-todo count + clickable rows. Adds a `screen`
  action kind that opens an in-process fullpane.
- **Notes: read-only notes tool for the agent** (`4c9765e9`) — the
  per-project scratchpad is exposed to the agent as a read-only tool
  mirroring `SessionTool`: it reads the DB row live (full markdown,
  not the lossy projection), reads the current project only, and
  never writes.
- **Widgets: comfy-monitor sidebar widget** (`992860c8`) — a
  spec-driven widget showing live ComfyUI queue + auto-suspend state
  (running/queued, suspended, idle, cancelled, error) refreshed every
  5 s from `.crux/comfy-monitor-status.json`, with cancel + suspend
  actions; the runtime heartbeat JSON is gitignored, only the spec
  ships.
- **Commands: `/web-provider` accepts a bare key** (`09ad090a`) —
  `/web-provider <name> sk-...` works without the mandatory `key`
  sub-action, mirroring `/provider <name> <key>`; `key`,
  `remove`/`--remove`/`rm` keep working.
- **Paste: system clipboard via OSC 52 + host reader** (`b0fe4921`) —
  the paste button resolves clipboard text in the same source order
  as Ctrl+V: OSC 52 from the terminal first, then OS tools
  (wl-paste/xclip/pbpaste/...), then the session-internal buffer —
  fixing Ctrl+V pasting nothing on pure-Wayland/Linux. Bumps the
  nocterm submodule for OSC 52 read + `systemClipboardTextReader`.
- **Providers: zhipu GLM-5.3 promoted from placeholder to released**
  (`2f552124`) — GLM-5.3 is now live on the GLM Coding Plan
  (Max/Pro/Lite); the speculative placeholder entry is retired and
  doc references list the released model.
- **Sidebar: box the aux button like the spec widgets** (`f96c50a5`) —
  the auxiliary-model button in the sidebar renders in the same boxed
  style as the spec-driven widgets.

### Fixes

- **Notes: flush-left checkbox, indented wrapped lines, zebra rows**
  (`44247ad3`) — the checkbox sits flush-left with a single-space
  gutter (shared by sidebar + home), long todos wrap with a hanging
  indent so continuation lines stay aligned, and alternating row
  backgrounds match the markdown table rendering.
- **Home: fullpane opens on top of the home dashboard** (`b609dfd8`) —
  opening a fullpane from home (my-notes `open`, skills box)
  previously no-op'd because the home branch in `ChatPanel.build`
  early-returned before the fullpane overlay check; the fix avoids a
  nocterm markNeedsBuild lifecycle assert by not swapping the tree
  root mid-layout.

## [0.25.0] - 2026-08-10

860f45f7

### Features

- **Home screen: customizable launch dashboard** (`ecfcf45`) — a
  full-screen bento-grid dashboard shown on launch (opt out via
  `[home].show_on_launch = false` or `--no-home`), re-openable via
  `/home`. Responsive 4/2/1-column reflow with span packing, keyboard
  nav and mouse support, an edit mode (`e`) to reorder/resize/hide
  boxes persisted to `[home].layout` in config.toml, and a pluggable
  HomeWidget registry. Ships with quick-actions, git-status, tokens,
  recent-sessions, and yesterday boxes.
- **Home: workspace box, item-level selection, two-level nav keys**
  (`2286452`) — a new workspace box shows project dir, git branch,
  active model, and session count. List boxes gain per-item click
  targets and ↑↓ item selection; ←→ moves the focused box within its
  row, Tab/Shift+Tab jumps rows, Enter activates the selection.
- **Home: Activity box — token-per-day heatmap** (`4030c6d`) — a
  terminal-native heatmap of token usage per day: Mon–Sun columns,
  last 4 ISO weeks as rows, log-scale truecolor intensity against a
  ceiling that ratchets up to the busiest day, per-week totals, and
  a live legend.
- **Home: yesterday box summarizes via auxiliary model** (`4a4773d`,
  `45eaa7e`, `da2bc78`) — the Yesterday box replaces its static
  session list with a one-round auxiliary-model digest of what was
  worked on yesterday (developer asks + truncated replies only, so a
  full day can't overflow the cheap model). Results persist to
  `yesterday_summary.json` keyed by date + session fingerprint, so a
  relaunch with an unchanged yesterday-set skips the LLM call; the
  box is taller, soft-wraps, and scrolls.
- **Home: scrollable skills box with fullpane skill viewer**
  (`23483b1`) — a new box lists every discovered skill (project +
  global); Enter/click opens the skill's SKILL.md in a read-only
  highlighted-markdown fullpane, with esc returning to the dashboard.
- **Home: every box content lives in a scrollview** (`0df8d1b`) —
  the box chrome wraps all content in a Scrollbar +
  SingleChildScrollView, making overflow structurally impossible;
  ↑↓ selection keeps the selected item visible, mouse wheel scrolls,
  and hover maps viewport rows through the scroll offset.
- **Widgets: spec-driven sidebar widgets** (`d023a3e`) — drop a TOML
  spec into `.crux/widgets/*.toml` and every Crux session on the
  project renders a live status box within ~2 s, no rebuild. Label
  templates support multi-line text, dotted JSON paths, timestamp
  formatting, and heartbeat-driven liveness; action kinds cover
  launch (new terminal), http (POST to a live service), shell
  (project-root scripts), and prompt (submit a template to the
  session). User clicks land in the session context with outcomes.
  Ships with the hot-reload dev-harness control channel and seeded
  `dev-harness.toml`, a `widgets` tool, and a built-in `widget`
  skill.
- **Vibe: live progress box for long-running bash** (`47fbb07`) —
  progress signals (percent / bars / phase words / rate / ETA) are
  parsed directly from shell output — no aux model, zero LLM cost —
  and rendered as a live box alongside think/tools/files; a ≥2 s
  gate prevents flashing, and the persisted segment renders a
  compact ✓/✗ echo row.
- **@mention: offload index build to a worker isolate** (`3a82bbe`) —
  the worker now owns the file index end-to-end (tree walk, sort,
  pre-computed scoring arrays, immutable snapshot), removing the
  multi-hundred-ms UI freeze on the first `@` in big projects; a
  generation guard discards stale builds, and request timeouts plus
  dead-worker respawn keep a crashed isolate from hanging search.

### Fixes

- **DeepSeek: pass back assistant reasoning on tool-call rounds**
  (`38f457c`, `5030a4a`) — thinking mode requires the chain-of-thought
  returned on every post-tool-call request, and all content fields
  must be typed parts arrays; the Responses-API switch dropped both,
  causing 400s. Reasoning is now carried through buildApiMessages,
  the in-loop tool-call formatter, and a sanitizeMessages backfill,
  and all content emits as typed parts.
- **Session search: exclude the current session from sweeps**
  (`860f45f`) — the session tool's `search` scanned the N most-recent
  sessions including the current one, contradicting its "OTHER
  sessions" contract; it now skips the current session unless pinned
  explicitly, over-fetching one row so the scan doesn't shrink.
- **Vibe files: gate per-file diff action on reconstructability**
  (`45e56a9`) — rows whose segments can't reconstruct a before/after
  diff used to open a dead-end fullpane; the diff action now renders
  dim and non-clickable when `hasReconstructableVibeFileDiff` fails,
  using the same check the fullpane would.
- **Home: Ctrl+C quits** (`188d554`) — home's key handler swallowed
  every key with no quit path, trapping Ctrl+C (the app's
  CtrlCBehavior is disabled on home); Ctrl+C now routes to the single
  quit path used by /quit, in both normal and edit mode.
- **Home: mouse clicks on item-list rows fire the clicked row**
  (`144533e`) — the opaque whole-box GestureDetector shadowed row tap
  detectors, so clicks no-op'd or ran the first item; item boxes now
  rely on their rows' own detectors, with hover-focus on a non-opaque
  MouseRegion.
- **Home: hover selects the row under the cursor** (`b83a2f1`) —
  per-row MouseRegions never received hover events under the wrapping
  box region; hover-row selection moved to the box level, mapping the
  cursor's terminal y through the scroll offset to an absolute item
  index.
- **Home: unsubscribe git-status listener on deactivate** (`c73a655`) —
  a GitStatusService isolate event landing mid tree-swap tripped
  setState's active-element assert intermittently; the listener now
  unsubscribes in deactivate() and re-subscribes in activate().
- **Git: correct start-message arg order in GitStatusService isolate**
  (`041de5a`) — the start() message ordered its args differently than
  the isolate handler read them, so the as-String cast on a bool
  killed the isolate's immediate fetch and periodic timer; the sender
  now matches the handler.

## [0.24.0] - 2026-08-01

4bd1ab8

### Features

- **Chat mode: workspace-free conversations via `/chat`**
  (`25d2291`) — a new `/chat` slash command opens a session with
  no project attached (`projectPath=''`, minimal system prompt
  with no AGENTS.md / CLAUDE.md / skill discovery). Chat sessions
  are listed in a global "Chats" sidebar section visible in every
  Crux instance, rather than the project-scoped "Sessions" list,
  and are guarded by the same running-lease mechanism so a chat
  streaming in one instance can't be opened in another. Schema
  bumps to v29 with `sessions.kind`; storage gains `listChats`,
  `archivedChatCount`, and a 3-day `autoArchiveChats` sweep.
- **DeepSeek: route every model through the Responses API wire
  family** (`e6dbc88`) — DeepSeek's Responses API replaces Chat
  Completions as of deepseek-v4-flash (2026-07). Crux now POSTs
  to `https://api.deepseek.com/responses`, translates the
  OpenAI-IR message list into Responses input items, and parses
  the semantic SSE event stream (`response.output_text.delta`,
  `response.reasoning_text.delta`,
  `response.function_call_arguments.delta`) ending with
  `response.completed` / `response.incomplete` / `response.failed`.
  Gating on the wire family rather than the model id makes
  deepseek-v4-pro a no-op when it lands in early August 2026.
- **Vibe diff: streamline the fullpane for the single-file case**
  (`5933ed2`) — the diff fullpane now drops the redundant files
  box when only one file changed and keeps the file's header
  context in place, so single-file reviews no longer scroll past
  the file picker before the diff.
- **Vibe diff: syntax highlighting and line numbers** (`2acf972`)
  — diff lines render in their language's syntax colour via the
  textmate grammar, and a left gutter shows the source line
  number for each diff row, matching the diff view in the IDE
  users already know.
- **Vibe files: per-file multibutton rows and width-adaptive diff
  fullpane** (`4a91d6f`) — each file in the changed-files box
  now sits on its own MultiButton row (open, diff, archive), and
  the diff fullpane adapts its width to the terminal so the
  per-file layout doesn't waste columns at 120-col terminals.
- **Vibe files: open / diff actions on every file row** (`3a55e50`)
  — the files box exposes an open action (open the file in the
  configured editor) and a diff action (jump straight to the
  diff fullpane for that file) per row, removing the
  open-via-sidebar round-trip.
- **Vibe diff: soft-wrap is always on; horizontal scroll and the
  wrap toggle are gone** (`1584916`) — diff lines now soft-wrap
  on word boundaries regardless of terminal width. The horizontal
  scroll fallback and the keyboard wrap toggle were removed
  because soft-wrap is the only sensible behaviour for prose in
  a narrow terminal; the wrap-toggle UI is no longer needed.

### Fixes

- **Diff: highlight comments correctly via textmate per-line fix**
  (`467758b`) — the diff view used to apply textmate colour to
  the whole snapshot, which leaked scope across lines and made
  comment tokens render with the wrong hue. Comments now colour
  correctly per line.
- **Vibe diff: force comment lines to the comment colour**
  (`751aec1`) — comment lines in the diff view occasionally
  lost their colour because textmate's range highlighting didn't
  paint comment-only spans. The diff renderer now forces
  comment lines to the configured comment token.
- **Vibe diff: highlight the whole snapshot, add horizontal
  scroll + wrap toggle** (`ebac84eb`) — superseded by the
  soft-wrap feature above; kept here so the commit history
  stays traceable. Diff lines that lost their syntax colour
  when the snapshot grew past a single screen now colour
  consistently, and the wrap toggle gives users control over
  line-wrapping behaviour. (The toggle was later removed when
  soft-wrap became the default; see the matching feature.)
- **Vibe diff: actually show syntax colours** (`9ff5a3db`) — the
  textmate highlight pipeline was wired but never invoked for
  the diff rows; the live renderer now calls the grammar and
  the colours paint.
- **Vibe files: build the files-box body as a growable Component
  list** (`495dc928`) — the files-box used a fixed-size list that
  overflowed when more than a handful of files changed; the body
  is now a growable Component list that scrolls cleanly.
- **Chat input: don't trap the user when text starts with `/`
  but isn't a command** (`f22c9b2`) — typing `/foo` where `foo`
  isn't a registered slash command used to leave the input in a
  state where it couldn't be cleared or focused. The input now
  stays editable when a `/`-prefixed message isn't a registered
  command.

## [0.23.0] - 2026-07-30

02f423b

### Features

- **UI: faint top-right version badge with JIT suffix**
  (`189e287`) — a new `crux v0.23.0` badge sits in the
  top-right corner of the chat panel, dim enough to stay
  out of the way but readable at a glance. When the binary
  was built from a dirty tree or unpushed commit, the
  suffix shows `+jit` so it's obvious the running build
  isn't a tagged release.
- **Ask-form: recap bubble for submitted answers
  (vibe + verbose)** (`77b39e8`) — after the user submits
  an ask-form, the chat log now shows a recap bubble of
  the chosen answers instead of letting the raw wire
  prose stand on its own. Both the compact (`vibe`) and
  the detailed (`verbose`) chat modes render an answer
  card that lists the selected options and any free-text
  note.

### Fixes

- **Ask-form: persist the answer row at submit so the
  bubble survives turn end** (`2307b80`) — the ask-form's
  recap bubble used to disappear as soon as the session
  ended; the answer row is now persisted at submit time
  so it survives into subsequent turns and across
  compaction.
- **Ctrl+C is quit-only; ESC×2 is the sole interrupt**
  (`02f423b`) — Ctrl+C no longer cancels a streaming
  response — it only quits the app. When any session is
  running (including a streaming one), the first press
  arms the double-press quit guard with a warning toast;
  a quick second press within 3s exits. With nothing
  running, Ctrl+C quits immediately as before.
  Interrupting a response is now exclusively ESC×2's job;
  the input placeholder, `/help` sheet, `/quit` rejection
  toast, and Ctrl+C guard tests are updated to match.

## [0.22.0] - 2026-07-29

905e1da

### Features

- **Skills: skip already-loaded body on `$` chip, persist bodies
  in compaction** (`282d71f`) — when the `$`-chip parser hits a
  skill already present in this session's loaded-skills registry
  it skips re-emitting the skill body (the chip alone is enough
  to invoke it). Newly-loaded skill bodies now persist into the
  chat-log compaction summary, so they survive context rollup.
- **Compaction: render "loaded skills:" section in chat log
  summary** (`d83a5bf`) — the compaction chat-log summary now
  lists the session's loaded skills in a dedicated section
  alongside the existing tools/agents/notes rollups, so the
  rolled-up context keeps the skill set across windows.
- **LSP: gray glyph when no server is configured for a file
  type** (`b289873`) — files whose extension has no registered
  LSP actor now paint the LSP glyph in the neutral gray used
  for `lsp:disabled`, instead of the success-green that
  implied a working server.
- **LSP: color-coded outcome glyph on write/edit tool calls**
  (`c77924a`) — write and edit tool calls now render the LSP
  glyph in success/failure color depending on the post-edit
  server response, so users see at a glance whether the
  language server accepted the change.
- **ToolContext exposes ShellMonitorLogSink** (`06c3c52`) —
  the monitor pipeline's batched event sink is now reachable
  through `ToolContext`, so tool implementations can record
  their own mid-run events into the same `/d-monitor` history.
- **Shell-monitor persists runs to shell_monitor_logs via
  batched sink** (`5e1145d`) — completed monitor runs
  (verdicts, intermediate events, timing) are now written
  into a new drift-backed `shell_monitor_logs` table and
  surfaced through `/d-monitor`. Combined with the exposed
  sink, the entire monitor history is now queryable post-run.
- **Storage: add shell_monitor_logs table (schema v28)**
  (`806840b`) — schema bumps to v28 with a new
  `shell_monitor_logs` table keyed by `runId`; the migration
  is idempotent (see fix below) and survives repeated opens.

### Fixes

- **Storage: shell_monitor_logs v28 migration is idempotent**
  (`905e1da`) — re-opening a database at v27 now upgrades
  to v28 reliably across repeated launches; the previous
  migration could double-apply when the helper ran more
  than once per startup.
- **LSP: show outcome glyph in the live vibe tools box**
  (`b5b94e0`) — the post-edit outcome glyph now appears in
  the live tools box while a tool call is still rendering,
  not only in the final settled vibe box.
- **Shell-monitor: raise minimum next-check interval from
  5s to 15s** (`374283c`) — the monitor's poll cadence now
  bottoms out at 15s instead of 5s, so long-running idle
  commands stop pummeling the database with empty runs.
- **Ask-form: dismiss cancels the turn; note field is
  mouse-focusable** (`bd29483`) — pressing `esc` on an
  unanswered ask-form now cancels the form (matching the
  chip-style dismiss). The note field accepts mouse focus
  for click-to-edit.

## [0.21.0] - 2026-07-27

6f5489e

### Features

- **Aux-model button moves to the side panel, with live
  task labels** (`5d63e05`) — on wide terminals the
  auxiliary-model button leaves the toolbar for a
  full-width slot in the ExtraInfoPanel (narrow
  terminals keep it in the toolbar). A new app-wide
  `AuxiliaryTaskTracker` registry feeds live labels of
  running auxiliary tasks into the UI.
- **Kimi K3 exposes low/high reasoning efforts** (`91bf9a7`)
  — K3 now accepts `reasoning_effort` of low/high/max
  (previously max-only), with Crux's five-level internal
  scale mapped onto K3's three levels.

### Fixes

- **Ask-form options stack vertically** (`6f5489e`) —
  long option labels used to be clipped off screen when
  cells sat side-by-side in one row; each option now
  gets its own full-width soft-wrapping row, and
  arrowLeft/arrowRight step through options with
  group-boundary clamping.
- **Multi-button keeps multi-row height on hover**
  (`a1da7a5`) — the hovered state collapsed
  soft-wrapped labels to a single row; the button now
  pins its footprint to the idle label's measured
  height and centres the segment row vertically.
- **Context bar refreshes immediately on model switch**
  (`75afd84`) — `/model` switched the session model
  but never rebuilt the chat panel, leaving the cached
  context-size label stale until the next hover or
  timer tick.

## [0.20.0] - 2026-07-21

2d9fd4c

### Features

- **LSP multi-language support with opencode-style
  auto-install** (`2d9fd4c`) — the in-process Dart LSP
  stack gains a per-language actor registry, automatic
  download-and-install of language servers that aren't
  on `PATH`, and a clean fallback to a generic JSON-RPC
  client for languages without a first-class actor.
  New `lib/src/lsp/actors/csharp.dart`,
  `java.dart`, `python.dart`, `rust.dart`,
  `typescript.dart`, plus a `generic.dart` that handles
  any language server speaking the LSP wire protocol.
  New `lib/src/lsp/actors/registry.dart` (405 lines)
  picks the right actor per file extension / language
  hint, falling back to `generic` for unknown ones.
  New `lib/src/lsp/actors/installers.dart` (359 lines)
  plus `lib/src/lsp/installer.dart` (431 lines) own
  the opencode-style auto-install flow: detect missing
  server binary → resolve a download URL from a small
  per-language registry → fetch the platform-appropriate
  archive (zip / tarball / npm-style) → extract into
  `~/.crux/lsp/<lang>/<version>/` → symlink or shim
  the `command` so the actor can spawn it. All file
  writes go through the existing
  `BundledDirectory` helpers so the install survives
  Crux upgrades. `lib/src/lsp/actor.dart` shrinks by
  29 lines as the per-language code moves into the
  dedicated actors; `dart.dart` loses 20 lines as the
  same generalisation kicks in. `lib/src/lsp/spawn_util.dart`
  gains 30 lines wrapping the process-group spawn
  pattern that previously lived in `actor.dart`.
  `lib/src/lsp/language.dart` (+7 lines) carries the
  new language enum additions. The chat panel gains a
  small `+4` line wire-up so the new registry is the
  authority for "which server runs for this file".
  `test/lsp/installer_test.dart` (+138 lines) covers
  the download / extract / shim happy paths plus the
  failure modes (network down, archive corrupted,
  permission denied on `~/.crux/lsp/`).
  `test/lsp/registry_test.dart` (+153 lines) covers
  per-extension actor resolution and the generic
  fallback. Net effect: edit / write / same-turn
  diagnostics now reach the model for **csharp, java,
  python, rust, typescript, and any other LSP-speaking
  language** without a manual `npm install -g` /
  `pip install` step — the same auto-install pattern
  opencode uses.

## [0.19.0] - 2026-07-21

e06c62d

### Features

- **`ask` tool for structured multi-part questions
  (ASK 2.0)** (`9a6873a`) — the LLM can now call a
  dedicated `ask` tool to gather structured multi-part
  answers from the user, beyond the existing single-
  choice `ask://` buttons that render in chat replies.
  `AskTool.execute(...)` blocks on a
  `Completer<ToolResult>` until the user submits or
  dismisses an interactive form that swaps in for the
  chat input box while the round is pending. Same
  `Future<ToolResult>` contract as `bash` / `webfetch`
  / etc — just a different source of the future's
  completion (the user instead of the network). The
  existing inline `ask://` buttons stay the cheapest
  path for yes / no / A / B / C single-choice replies.
  New `lib/src/components/ask_form.dart` (536 lines)
  owns the form widget; new `lib/src/tools/ask_tool.dart`
  (420 lines) is the tool implementation; the tool
  registers via `registry.dart`; the chat panel
  (`chat_panel.dart`, +153 lines) wires the round-
  pending UI swap, and `chat_turn_orchestrator.dart`
  surfaces the round state. System prompt gains an
  `ask` tool description so the model knows when to
  reach for it. `test/components/ask_form_test.dart`
  adds 494 lines covering rendering, submit / dismiss,
  multi-part payloads, and the round-pending swap.

- **Aux-model progress monitor replaces static
  shell-command timeout** (`e06c62d`) — when an
  aux model is configured, `bash` / `cmd` /
  `powershell` no longer enforce the static
  `~10 s` timeout. A monitor loop snapshots the
  running process at model-scheduled intervals and
  asks the aux model — in one *continuing*
  conversation — whether the command is still making
  progress. Only a confident `STUCK` verdict kills
  the process group; long-but-progressing commands
  (multi-GB `tar`, deep `find`, large `cargo` / `go`
  builds, …) now run to completion instead of being
  killed mid-stream. Without an aux model configured,
  the classic static-timeout behavior is unchanged
  (no regression for users who don't set
  `auxiliaryModel`). New
  `lib/src/tools/shell_monitor.dart` (225 lines)
  owns the snapshot loop and aux-model conversation;
  `shell_base.dart` (+220 lines) drops the static
  `timeout` enforcement when a monitor is active;
  `auxiliary_service.dart` (+148 lines) gains the
  continuing-conversation API; `auxiliary_prompts.dart`
  (+62 lines) gains the STUCK-judgement prompt.
  `test/auxiliary_shell_monitor_test.dart` adds 112
  lines covering STUCK-kills-early, preserved classic
  timeout (no aux model), the conversation shape
  passed across snapshots, and short-commands-never-
  fire (under the monitor interval, the monitor never
  sees a running process and never asks). The
  integration test `shell_monitor_integration_test.dart`
  adds 166 lines using a fake evaluator that drives
  the STUCK and PROGRESS verdicts through the real
  `chat_turn_executor`. The shell-risk guardrail
  (v0.17.0's `020e4aa`) is layered above this and
  still fires before the command starts; the monitor
  only kicks in once the command is running.

## [0.18.0] - 2026-07-21

32b98ea

### Features

- **Theme system rework with terminal light/dark
  auto-detection** — the theme loader, controller, and
  registry now expose a richer surface that powers both
  manual theme selection (`/theme`) and a startup-time
  automatic default based on the terminal's background
  brightness. New `lib/src/theme/terminal_brightness.dart`
  inspects `COLORFGBG` (set by konsole / rxvt / some
  VTE setups as `fg;bg`), `TERM_BACKGROUND` (a few
  terminals), and falls back to a per-process random
  choice between the bundled dark and light themes
  (`dracula` / `github`) when no env hint is available.
  The detection is intentionally heuristic and
  non-blocking — no OSC 10/11 escape-sequence
  round-trips, which can stall boot on terminals that
  don't answer. Each bundled theme (catppuccin, cobalt2,
  dracula, flexoki, github, onedarkpro, rosepine,
  synthwave84) gains the surface the new system reads.

- **New rosepine-main theme** (`themes/rosepine-main.toml`)
  — the existing `rosepine` theme is dark; this adds
  the official Rosé Pine *Main* variant as a separate
  theme the picker can select independently.

- **New shared `Spinner` component**
  (`lib/src/components/ui/spinner.dart`) — braille
  frames (`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`) on terminals that support
  rich glyphs, ASCII (`- \ | /`) fallback otherwise.
  Centralized `spinnerFrames()` accessor picks the
  appropriate frame list at build time, and the
  TickerRegistry-aware base stops the animation when
  the host is destroyed. `test/spinner_test.dart`
  covers frame cycling, terminal-symbol fallback, and
  registry teardown.

- **New shared `LayoutMetrics` module**
  (`lib/src/components/ui/layout_metrics.dart`) —
  centralizes the responsive thresholds and inset
  sizes used by the main chat surfaces (chat panel,
  message bubbles, input, toolbar, tool detail pane,
  fullpane) so related surfaces stay visually
  consistent and each number carries its rationale in
  one place. Includes `kSidebarShowThreshold = 100`
  columns (the right-hand info sidebar appears at or
  above this width), `kSidebarWidthMin = 28` /
  `kSidebarWidthMax = 40`, and fullpane sizing
  constants. Switching any number now is a deliberate
  visual change, not a refactor.

## [0.17.0] - 2026-07-21

d89ef1d

### Features

- **Shell high-risk command guardrail with auxiliary-model
  review** (`020e4aa` + `91ab6f6`) — three-layer defense
  before any `bash` / `cmd` / `powershell` command executes:
  (1) **heuristic pre-screen** (pure function, zero cost) —
  obviously-safe commands run immediately; catastrophic
  patterns (`rm -rf /` or `~`, `dd` / `mkfs` on devices,
  fork bombs, `shutdown`, Windows disk-root deletion) are
  hard-blocked with no override; suspicious patterns
  (`sudo`, `curl | sh`, `rm -rf` absolute paths,
  `git push --force`, writes to system paths, `kill -1`,
  `pkill`, …) escalate to layer 2; variable / indirect
  `rm` targets (`$HOME`, `~user`, backticks) are treated
  as suspicious so the model always sees them. (2)
  **auxiliary-model evaluation** — reuses the existing
  `auxiliaryModel` config and `AuxiliaryService`; the
  cheap model judges `SAFE / UNSAFE / UNCERTAIN` with a
  strict one-word output contract. `SAFE` runs; `UNSAFE /
  UNCERTAIN` are rejected with guidance to explain the
  risk and re-issue with `confirmed: true` after explicit
  user approval (`ask://`). ~10 s timeout wired to a
  stream-cancel token. (3) **escape hatch** —
  `confirmed: true` skips layer 2 (never layer 1
  catastrophic blocks); the system prompt forbids
  self-approving. Fail policy: aux unconfigured /
  timeout / error → fail-open with a warning appended to
  the output (audit metadata `shellRisk` recorded either
  way). `CRUX_DISABLE_SHELL_RISK_GUARD` env var (runtime,
  unlike the existing shell-guard's compile-time flag)
  disables the whole guardrail. An abort check
  immediately before `Process.start` closes the race
  where an abort during evaluation still ran the
  command. `91ab6f6` follow-up shrunk the
  auxiliary-model prompt from ~350 input tokens (with
  four few-shot examples) to ~90 tokens — the same four
  judgement axes folded into three sentences — so the
  auxiliary-model cost drops measurably on every
  bash / cmd / powershell invocation.

### Fixes

- **Snap quota widgets on provider / session switch
  instead of lerping** (`1f12219`) — when the chat panel
  swapped the active provider (or session), the toolbar
  rebuilt `CodingPlanUsageDisplay` /
  `CreditBalanceDisplay` with a fresh stream from the
  new provider's polling lifecycle. `didUpdateComponent`
  rebinds the subscription but left the old provider's
  `_usage` / `_balance` and any in-flight lerp
  animation in place, so the next stream event animated
  from the previous provider's quota into the new
  provider's quota — a meaningless red / green flash
  that took ~3 s to settle. On stream identity change
  the displays now cancel the animation / countdown
  tickers, clear the refresh state, reset the internal
  snapshot to the new provider's initial value, and
  push the settled frame immediately. Within-provider
  quota deltas still animate normally; only
  cross-provider transitions stop lerping.
  `coding_plan_usage_test.dart` adds 401 lines pinning
  the new behavior plus regressions for the
  timer-cancel, the still-animating, and the
  null-initial-placeholder paths.

- **Pin width on hover and distribute segments evenly
  in `MultiButton`** (`43b7367`) — hovering a
  `MultiButton` no longer resizes the component, and
  the options now spread evenly across the original
  footprint instead of clustering in the middle.
  Captures the non-hovered layout width via
  `LayoutBuilder` and pins both idle and hovered
  states to it, so the surrounding `Column` (e.g. the
  side panel's git-status rows) never jitters as the
  mouse moves in and out. Each segment is wrapped in
  an `Expanded` inside the fixed-width `Row` so the
  segments spread out evenly with no growth past the
  container. `multi_button_test.dart` adds 163 lines
  covering hover-no-resize, distribute-loop, even
  distribution, no growth past the container, and
  segment tap routing.

- **Hide skill bodies in vibe history + show queued
  messages immediately** (`d89ef1d`) — vibe mode
  rendered the persisted user message verbatim, so a
  `$skill` chip's expanded body (appended for the LLM
  only) leaked into the chat log. Extracts the verbose
  bubble's strip logic into a shared `stripSkillBodies()`
  util (new `lib/src/utils/strip_skill_bodies.dart`)
  and applies it in `VibeSegmentBubble` and the
  jump-bar labels too. Separately, `QueuedMessagesBubble`
  read the controller's mutable queue without
  subscribing to `SessionCubit`, so an enqueued message
  only appeared when some other rebuild happened to
  fire. The fix subscribes to the `messageQueues`
  snapshot like `messages` / `btwTurns` already do.

## [0.16.0] - 2026-07-20

e8340cb

### Features

- **Local-target routing for webfetch** (`d2b8824`) —
  `UrlSafety.isLocalTarget()` detects machine-local targets
  (literal IPs in loopback / RFC1918 / CGNAT ranges, plus
  hostnames whose DNS answers are all local). When the
  tool is invoked on such a URL, `execute()` now routes
  it straight to the local raw fetch — which still applies
  the SSRF guard — instead of pushing it to the configured
  cloud provider (TinyFish), which can never reach those
  addresses from its network and just used to fail
  upstream. Net effect: `192.168.x` intranet wikis and
  `localhost` dev servers now work end-to-end via the
  agent. `url_safety_test.dart` adds 65 lines,
  `webfetch_tool_test.dart` adds 38.

- **Zhipu (GLM Coding Plan) provider** — add `zhipu` as a
  built-in provider (`providers/zhipu.toml`) backed by
  Zhipu's GLM Coding Plan API at
  `https://open.bigmodel.cn/api/coding/paas/v4`. The plan
  is open to all tiers (Lite / Pro / Max) per
  [docs.bigmodel.cn/cn/coding-plan/latest-model](https://docs.bigmodel.cn/cn/coding-plan/latest-model).
  Uses a custom `type = "zhipu"` (registered in
  `llm_provider.dart`'s `resolveProvider()`) backed by a
  new `ZhipuProvider extends OpenAICompatibleProvider with
  CodingPlanProvider`. Ships with five models:

  - `GLM-5.2` (1M context) — newest flagship, the only
    Coding Plan model with a true 1M context window.
  - `GLM-5.1` (200K) — previous flagship.
  - `GLM-5-Turbo` (200K) — "lobster" long-task enhanced.
  - `GLM-4.7` (200K) — workhorse; the recommended default
    for Lite-tier users because the higher-tier models are
    billed at 2–3× the rate.
  - `GLM-4.5-Air` (128K) — budget option for subagent or
    batch work.

  Two Zhipu-specific wire-format quirks are handled by
  `ZhipuProvider.buildRequestBody` (full rationale in
  `lib/src/services/providers/zhipu_provider.dart`'s
  class doc):

  - **`max_tokens`, not `max_completion_tokens`.** The
    Zhipu cURL / Python / Java SDK examples only show
    the legacy `max_tokens` field. The generic
    `OpenAICompatibleProvider` body uses
    `max_completion_tokens`; we rename it before the
    request hits the wire so a future Zhipu tightening
    of the spec can't 400 on us.
  - **Lowercase + dot-separated model IDs.** Every
    authoritative wire-format reference uses lowercase
    (`glm-5.2`, `glm-4.5-air`) even though the marketing
    names are mixed case. The TOML `id` field is the
    source of truth for the canonical ID.

  The `CodingPlanProvider` mixin polls
  `<origin>/api/monitor/usage/quota/limit` so the toolbar
  can display the user's live 5-hour and weekly quota
  alongside the model metrics. The endpoint URL is
  derived from the chat `endpoint_url` (origin extracted,
  path replaced with the well-known quota path) so a
  self-hosted proxy or regional mirror automatically
  works without code changes. The response parser lives
  in `lib/src/services/zhipu_usage_parser.dart` and
  inverts the `percentage` field (which is *used*, not
  *remaining*) into the toolbar's remaining-quota read;
  the row `unit` field (3 = 5h, 6 = weekly, 5 = monthly
  MCP) maps the flat `data.limits[]` array onto the
  toolbar's two cells.   The Zhipu quota endpoint uses a
  raw `Authorization: <key>` header (no `Bearer `
  prefix) and an `Accept-Language: en-US,en` header so
  the server returns the English `level` field
  spellings the parser expects.

### Fixes

- **Block link-local / metadata targets in webfetch raw
  fetch (SSRF)** (`ba14e78`) — the raw `webfetch` path
  could be pointed at internal addresses; the most
  damaging target on a developer machine or cloud VM is
  `169.254.169.254`, which hands out instance credentials
  on AWS / GCP / Azure. A new `UrlSafety` guard rejects
  `169.254.0.0/16` (link-local), `100.64.0.0/10` (CGNAT),
  `0.0.0.0/8`, `fe80::/10`, `::`, IPv4-mapped IPv6
  equivalents, and any non-http(s) scheme. Private ranges
  (`10/8`, `172.16/12`, `192.168/16`) and loopback stay
  allowed — intranet wikis and dev servers are legitimate
  agent targets. Hostnames are resolved and every DNS
  answer is checked (DNS-rebinding mitigation). Redirects
  are no longer auto-followed: each hop (max 5) is
  re-validated so an open redirect on a public host cannot
  proxy into a blocked target. The provider path (TinyFish)
  is unchanged — it fetches from the provider cloud, not
  this machine, so it's not a local-SSRF vector.
  `url_safety_test.dart` adds 121 lines,
  `webfetch_tool_test.dart` adds 21.

- **OpenAI-compatible URL builder recognizes any `/v\d+` version segment, not just `/v1`**
  (`llm_client.dart`) — `LlmClient._buildUri` used to detect
  "the endpoint already declares its API version" by
  checking for a trailing `/v1`. Zhipu's
  `https://open.bigmodel.cn/api/coding/paas/v4` URL ends in
  `/v4`, so the check missed it and Crux prepended a second
  `/v1`, producing the request path
  `/v4/v1/chat/completions` — Zhipu returned 404
  `Resource not found`. The check now matches
  `/v\d+$` (one or more version digits, with optional
  trailing slash), so any provider whose base URL ends in
  `/v2` / `/v3` / `/v4` / etc. is now routed correctly.
  Existing `/v1` and no-version-segment paths keep their
  previous behavior — the regression is locked down by a
  new test in `llm_client_test.dart` ("does NOT append
  /v1 when endpoint already ends in /v4 (Zhipu)") that
  asserts the captured path is exactly
  `/v4/chat/completions`.

## [0.15.1] - 2026-07-20

fe5933d

### Fixes

- **Markdown / `ask://` / `ses://` spans preserve nested
  parent styles after token substitution**
  (`fe5933d`) — `applyMarkdownLinkStyles`,
  `applyQuickReplyTokens`, and `applySessionLinkStyles`
  each flatten the markdown visitor's nested span tree
  into a flat list and then rebuild the styled spans.
  The flatten walked children but only read each leaf's
  own `style`, so any ancestor's color / weight /
  background (a paragraph color wrapping a bold run
  wrapping italic, for example) was dropped. Whenever
  an `ask://` / `ses://` / markdown-link token was
  present inside a markdown paragraph, the rendered
  line lost its color and weight and looked like plain
  prose. The fix threads an `inherited` parameter
  through each flatten call, accumulating the parent's
  style onto the child's `style` via the existing
  `_mergeStyles` helper in each file. Merge direction
  is base = inherited, overlay = leafStyle — so the
  leaf wins on conflicts, but a plain leaf still
  carries the full ancestor chain. Pinned by a new
  regression in `quick_reply_parser_test.dart`
  ("preserves nested parent styles after substitution")
  that builds a paragraph-color + bold + italic tree
  around an `ask://X{x}` token and asserts every
  emitted span (sibling, bold run, and the reply
  label) inherits the full effective style.

## [0.15.0] - 2026-07-17

3efb13f

### Features

- **Kimi Code provider** (`bd5a448`) — add `kimi` as a built-in provider
  (`providers/kimi.toml`) backed by Moonshot's Kimi Code API
  at `https://api.kimi.com/coding/v1`. Uses a custom
  `type = "kimi"` (registered in `llm_provider.dart`'s
  `resolveProvider()`) backed by a new
  `KimiProvider extends OpenAICompatibleProvider with
  CodingPlanProvider`. Ships with four models:

  - `Kimi K3 (1M context)` / `Kimi K3 (256K context)` —
    both map to the upstream `k3` model ID. The split is
    a UX signal so users can match the variant to their
    Kimi Code plan's granted context window
    (Allegretto+ = 1M, Moderato = 256K); the actual
    server-side cap is set by the plan tier, not the
    request.
  - `Kimi K2.7 Code` / `Kimi K2.7 Code Highspeed` —
    `kimi-for-coding` and `kimi-for-coding-highspeed`
    (6x speed / 3x cost).

  Two Kimi-specific wire-format quirks are handled by
  `KimiProvider.buildRequestBody` (full rationale in
  `lib/src/services/providers/kimi_provider.dart`'s
  class doc):

  - **K3 model-ID remap.** `k3-1m` and `k3-256k` are
    translated to the single upstream `k3` model ID at
    request time. Reasoning-effort presets are
    `reasoning_labels`-filtered to `off` + `max` only —
    K3 currently only honors `max` and 400s on unknown
    values.
  - **K2.7 binary thinking.** K2.7 is documented as a
    binary Thinking:ON/OFF knob. The `reasoning_effort`
    field the generic OpenAI-compatible builder would
    emit is stripped before the body hits the wire, so
    the request body matches what the kimi-cli kosong
    SDK sends. The picker surfaces `[off, on]` (max is
    renamed to `on` via `reasoning_labels`) for a clean
    binary UX.
  - **Temperature is pinned to 1.0** for every Kimi Code
    model (K3 and the K2.7 Code family). The Kimi API
    rejects any other value with
    `400 invalid temperature: only 1 is allowed for this model`,
    so the provider forces `temperature = 1.0` and pairs
    it with `top_p = 0.95` (Kimi's recommended default)
    on the wire regardless of the TOML model config or
    the `/temperature` runtime override. The
    `temperature` field on each `[[models]]` entry in
    `kimi.toml` is documented as ignored; the value
    shown in the toolbar reflects Crux's view of the
    config, not what's actually sent to Kimi. The
    toolbar renders a non-interactive `T:1 (fixed)` chip
    for Kimi sessions so the user sees the pinned value
    and a hover hint explaining `/temperature` has no
    effect. Driven by a new `LlmProvider.forcedTemperature`
    getter (default `null`) which KimiProvider overrides.
  - **Stream lerping on every Kimi model.** Kimi streams
    very chatty chunks (single tokens / token-pairs) which
    would otherwise render in a visibly stuttery burst.
    Each `[[models]]` entry sets `stream_lerp = true` so
    the chat executor's 60Hz drain timer smooths the
    output, same UX knob MiniMax and LongCat use for the
    same reason.

  Live quota readout: the toolbar's existing
  `CodingPlanUsageDisplay` (built for MiniMax's 5h/1w
  format) now lights up for Kimi via
  `KimiProvider.getCodingPlanUsage`. It polls
  `{endpoint_url}/usages` (Bearer auth) on the same
  30s-active / 180s-idle cadence as MiniMax, parses
  Kimi's flexible `{usage, limits[]}` shape, and maps
  the 5h row to the interval cell + the 1w summary to
  the weekly cell. The Kimi API commonly returns a 5h
  row in `limits[]` plus a top-level `usage` block
  (which the API and the kimi-cli `/usage` command
  both call the "Weekly limit" summary), so the parser
  routes the weekly cell to the `usage` block when
  `limits[]` only contains the 5h row — duplicating the
  5h row to both cells was an early regression. When
  `limits[]` has multiple distinct windows (5h + 1w +
  1m, etc.), those rows take precedence and the
  `usage` block is used only for the model name
  (display label) + the hover hint. 401 / 404 / non-2xx
  get the same error surface the kimi-cli `/usage`
  command uses, so the messages read identically
  across the two tools. The base `CodingPlanProvider`
  mixin's `startCodingPlanPolling` gained an optional
  `baseUrl` parameter (pass-through — the mixin doesn't
  cache it; subclasses save it on their own instance)
  so the polling coordinator can thread the per-
  provider `endpoint_url` TOML field through.

  `LlmVendor.kimi` added to `llm_error.dart` so Kimi
  errors get the "Kimi" display label in user-facing
  toast text.

- **Working `/help` and discoverable `/undo`**
  (`c06bca7`) — `/help` now prints a help sheet into the
  chat history, generated from the live command registry
  so it can never drift from reality again (command list,
  shortcuts, provider quick-start). `/undo` (alias
  `/撤销`) was implemented but never registered — it is
  now in the registry, the completion overlay, and the
  README. `/clear` and `/history`, which were registered
  and documented but never implemented, were removed from
  the registry and docs instead of failing with "not yet
  implemented" at runtime.

### Fixes

- **Reasoning-effort chip agrees with the picker when the
  session's stored value is filtered out by the model**
  (`session_controller.dart`) — `Session.reasoningEffort`
  and `SessionRuntimeState.reasoningEffort` defaulted to
  the hardcoded string `'normal'`, so a session created
  before the user switched to a model that filters
  `normal` out of its preset list (Kimi K3 / K2.7 Code
  expose only `[off, max]`) would render the chip as
  "normal" while the picker offered only the filtered
  subset, and the wire request would carry the
  unsupported value to the API (Kimi 400s on anything
  other than `max`). The runtime state init now
  reconciles the stored value against the active
  model's preset list via a new
  `_resolveReasoningEffort` helper: case 1 (stored
  value is supported) passes through; case 2 (stored
  value isn't supported) falls back to the model's
  TOML `reasoning_effort`; case 3 (TOML default also
  filtered out) falls back to the first enabled preset;
  case 4 (model has no presets) keeps the stored
  value as-is. The cycle picker in
  `chat_panel._cycleThinkingLevel` now also documents
  the `idx = -1` fallback for the same edge case (a
  runtime value the model's filtered list no longer
  contains). Backed by 5 new cases in
  `test/session_controller_resolve_effort_test.dart`
  (case 1 + Kimi K3 case 2 + Kimi K2.7 case 2 + Kimi
  case 1 + `reasoning_effort = "none"` case 4).

- **Ctrl+C matches the docs: cancel first, quit second**
  (`c06bca7`) — pressing Ctrl+C while a response streams
  now cancels the response (like ESC×2) instead of
  quitting Crux; a quick double-press still exits. The
  README previously documented the opposite of the real
  behavior, so users following the docs quit the app and
  lost context. The input hint, `/quit` toast, and README
  shortcut list were all rewritten to the real keymap
  (Tab, Ctrl+V image paste, Ctrl+D/Ctrl+R in the session
  panel, `@` files, `$` skills).

- **Same-turn LSP diagnostics reach the model**
  (`c06bca7`) — write/edit collected diagnostics were
  only attached at persistence time, so the model only
  "saw" the compile errors it introduced after a session
  reload. Error-level diagnostics now ride the same-turn
  tool result as a compact budgeted block, closing the
  advertised edit-feedback loop. Missing-API-key errors
  also name the actual provider and the next step
  instead of `No API key for provider ""`.

- **Storage integrity: foreign keys on, deletes atomic**
  (`c06bca7`) — SQLite foreign keys were never enabled,
  silently disabling every declared `ON DELETE CASCADE`;
  session deletion now runs in a transaction and also
  removes orphaned `file_last_writer` rows, and the
  orphan tool-row repair skips corrupt-JSON rows instead
  of treating them as terminators.

- **First-run onboarding and README truthfulness**
  (`c06bca7`) — the empty state now guides new users to
  `/provider` and `/`, a startup warning fires when no
  API key is configured, the README command table lists
  every registered command (`/view`, `/temperature`,
  `/web-provider`, `/undo`) plus `/tldr` detail levels
  and `CRUX_API_KEY`, and the hard-coded version number
  was replaced by a pointer to this changelog.

- **Release pipeline can no longer ship broken bundles**
  (`3efb13f`) — install.sh accepted only the
  pre-`dart build cli` zip layout, so every published
  release since the build-system switch failed to
  install; it now probes both layouts (plus `crux.exe`).
  Release bundles include the jieba dictionary (CJK word
  jumps crashed outside the source tree), the release
  workflow downloads the potion-code-16M embedding model
  before building and fails the build when the model or
  executable is missing instead of silently shipping
  degraded bundles, and the long-red `run_metrics_test`
  no longer asserts vendored ANSI bytes, so the full
  test suite can gate releases.

## [0.14.1] - 2026-07-16

e976f6a

### Features

- **Loaded skills moved to context bar hover hint**
  (`4ed3b57`) — replaces the inline `LoadedSkillChips`
  widget in the chat toolbar (added in 0.14.0) with a
  hover tooltip on the context bar. The bar already had
  a hint slot ("Context window usage. Click to compact
  the session history"); merging the loaded-skills list
  into that hint means one hover surfaces both pieces of
  info, instead of inline chrome that clutters the
  toolbar.

  What changed:
  - `chat_toolbar.dart` — drop the outer `Hinted`
    wrapper around the context bar; the bar's own
    `HintStateMixin` now drives the hint. Drop the
    inline-chip row + width budget + `LoadedSkillChips`
    dependency.
  - `context_bar.dart` — mix in `HintStateMixin`;
    `hintContent` composes the usage block + a blank
    line + the loaded-skills line. Empty runtime reads
    "Loaded skills : none" (positive empty state, not a
    hidden tooltip) so the user has a "feature works,
    just empty" signal. Placement = below (bar lives
    at row 0; above would always overflow).
  - `loaded_skill_chips.dart` — deleted (replaced by
    the tooltip path).

  Hint format (4 lines max in the overlay):

  ```
  Context window usage.
  Click to compact the session history.

  Loaded skills : alpha, mu, zeta
  ```

  Or "Loaded skills : none" when the runtime set is
  empty. `disabled: true` swaps the usage block to the
  "compaction unavailable while the agent is
  responding" wording (preserves the original
  `ChatToolbar.Hinted` behavior).

  Backed by `test/context_bar_loaded_skills_hint_test.dart`
  (4 cases pinning the empty / populated / running-state
  / no-session hint text) and
  `test/context_bar_loaded_skills_e2e_test.dart` (2 cases
  wiring real `expandSkillChips` + a temp `.agents/skills/`
  tree + the `ContextBar` in `testNocterm` so the full
  chip-submit-to-tooltip pipeline is exercised end-to-end
  — both the chip path and the tool path show up in the
  merged skills line).

  Runtime tracking (`SessionRuntimeState.loadedSkillNames`,
  `chat_turn_orchestrator.sendTurn`, `SkillTool.execute`)
  is unchanged from `afe0bf9`; only the read path moved
  from inline chips to tooltip.

### Fixes

- **Vibe files box dedupes by basename, not full path**
  (`e976f6a`) — the files box in vibe mode deduped by
  string equality on the full path. When the LLM (or
  the executing-side `_toolExecutionPreview`) reported
  the same file under different path strings — e.g.
  absolute vs. relative, project-relative preview vs.
  the raw LLM path — dedup failed and the basename
  rendered twice with the same `+N -M` diff. Symptom:
  a vibe-mode turn that ended with edit + edit on the
  same file showed two rows in the files box.

  Switch the files-box dedup key to `p.basename` in
  two layers:
  - `walkSegments` (`vibe_box_data.dart`) — `modPaths`
    is now deduped by basename. `modLinesAdded` /
    `modLinesRemoved` are keyed by basename, so the diff
    sums across tool calls that name the same file with
    different path strings (the two edits collapse to
    one row with `+N +M -K -J` rather than two rows
    each with the wrong total). The `_emitSegment` fold
    translates back via `p.basename` when summing
    across the 8-row cap.
  - `VibeStreamingBubble` (`vibe_streaming_bubble.dart`)
    — the rendering loop dedupes `baseMods.paths` and
    `_collectLiveFilePaths()` by basename. `baseMods`
    wins on overlap because it carries the `+N -M`
    diff; the live row would be a strict downgrade.

  Backed by a walker dedup regression in
  `vibe_segment_test.dart` (two edit calls with
  different path strings for the same file produce ONE
  row with the summed `+N -M`, plus a sanity test that
  genuinely-different files like `foo.dart` vs.
  `foo.dart.bak` keep separate rows) and a streaming
  bubble dedup regression in `vibe_streaming_bubble_test.dart`
  (persisted edit on `lib/foo.dart` + live edit on
  `${tempDir.path}/lib/foo.dart` renders exactly one
  `foo.dart` row in the files box).

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
  active styling).

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
  file-guard bodies.

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
  `test/utils/quick_reply_parser_test.dart`.

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
  25 min, 30 s) render readably.

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
  correctly.

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
  (e.g., suggest `/compact` for context-length errors).

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
