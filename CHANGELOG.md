# Changelog

All notable changes to Crux are documented in this file.

Changes are grouped under each version, with the commit SHA on the line
below the version header. Each version has at most two categories:
**Features** and **Fixes**.

## [Unreleased]

## [0.7.1] - 2026-06-21

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
