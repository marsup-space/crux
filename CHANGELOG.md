# Changelog

All notable changes to Crux are documented in this file.

Changes are grouped under each version, with the commit SHA on the line
below the version header. Each version has at most two categories:
**Features** and **Fixes**.

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