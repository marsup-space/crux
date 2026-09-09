# Crux

**Desktop-class feel. Terminal-sized.**

Your AI coding workbench in the terminal. Rich interactions. Immediate feedback. A smoother path from planning to code review.

- **Every interaction. Worth getting right.** Real buttons, mouse interaction, and a workbench you can arrange.
- **Built-in Git client.** From side-by-side diffs to staging and commits, in one place.
- **Agent-built plugins. Live in your workbench.** Tell the agent what you need. New plugins load without a restart.
- **Interact directly. Keep the task moving.** Agent-built forms and controls feed your actions back into the conversation.
- **A terminal can show more than text.** Read Mermaid diagrams alongside the conversation.
- **Time and context. Spent where they matter.** Semantic code search, prefix caching, and parallel tools.

Your model. Your workbench. DeepSeek · Kimi · MiniMax · Codex · Custom compatible APIs.

[Download for macOS, Linux & Windows](https://github.com/marsup-space/crux/releases) · [中文](README.zh-CN.md)

## Installation

**macOS / Linux**

```bash
curl -fsSL https://raw.githubusercontent.com/marsup-space/crux/v1.0.0-rc.2/install.sh | bash -s -- --version v1.0.0-rc.2
```

**Windows (PowerShell)** — download [install.ps1](install.ps1), then run:

```powershell
& .\install.ps1 -Version 1.0.0-rc.2
```

Prebuilt binaries; no Dart SDK required. Open a new terminal after installation if `crux` is not found.

## Recommended terminal & font

- **Terminal:** [Ghostty](https://ghostty.org/download) on macOS / Linux; [Windows Terminal](https://learn.microsoft.com/en-us/windows/terminal/install) on Windows.
- **Font:** [Maple Mono](https://github.com/subframe7536/maple-font/releases/latest) or [Fira Code](https://github.com/tonsky/FiraCode/releases/latest). Install it, then select it in your terminal settings.

## Getting started

```bash
cd /path/to/your/project
crux
```

Follow the first-run **Setup** prompts to connect your model, then describe what you want to build or change. Use `/plan` to plan first, `/project` to switch projects, or `/setup` to revisit configuration.

## Contributing

Focused bug fixes are welcome. Please discuss new features and larger changes in
an issue before opening a pull request. See [CONTRIBUTING.md](CONTRIBUTING.md)
for the project scope and development checks.

Please report security issues privately as described in
[SECURITY.md](SECURITY.md).
