<div align="center">

```
  ██████╗   ██████╗  ██╗   ██╗ ██╗  ██╗
 ██╔════╝  ██╔══██╗ ██║   ██║  ██╗██╔╝
 ██║      ██████╔╝ ██║   ██║   ███╔╝
 ██║      ██╔══██╗ ██║   ██║  ██╔██╗
  ██████╗ ██║  ██║  █████╔╝ ██╔╝ ██╗
```

# Crux · 十字星

**终端里的 AI 编程助手 — 智能体编排框架**

[English](#english) · [中文](#chinese)

---

</div>

## ⚡ Quick Install

一行命令，所有平台都一样：

```bash
curl -fsSL https://raw.githubusercontent.com/marsup-space/crux/main/install.sh | bash
```

默认装到 `~/.crux/bin`（Windows 下是 `C:\Users\<你>\.crux\bin`）。flags / env vars / PATH 策略见下方各语言章节的 **安装** / **Installation** 部分。

## <a name="chinese"></a>🇨🇳 中文

### 安装

**Crux 的安装逻辑只有一份**：`install.sh`——它会从 GitHub Releases 拉取预编译 AOT 二进制、装到 `~/.crux/bin`、自动加 PATH。覆盖 macOS / Linux / Windows 全平台。**你只需要知道 `install.sh` 一个文件**。

一行命令，所有平台都一样：

```bash
curl -fsSL https://raw.githubusercontent.com/marsup-space/crux/main/install.sh | bash
```

脚本是纯 bash——macOS / Linux 上原生运行；Windows 上要有一个 bash 环境（WSL、Cygwin、MSYS2 都能跑；开发者机器上基本都有），install.sh 会自动检测 `MINGW*` / `MSYS*` / `CYGWIN*` 拉 Windows 二进制，并调 `setx` 把安装目录加到 Windows user PATH，让 cmd / PowerShell 也能直接 `crux`。

可选参数（任何平台都用 `-s --` 传给 bash）：

```bash
curl -fsSL .../install.sh | bash -s -- --version v0.7.0
curl -fsSL .../install.sh | bash -s -- --binary /path/to/crux
curl -fsSL .../install.sh | bash -s -- --no-modify-path
```

环境变量（与参数等效，CI / Docker 场景常用）：

- `CRUX_VERSION=v0.10.0` 锁定版本（默认 `latest`）
- `CRUX_INSTALL_DIR=...` 改安装目录（默认 `~/.crux/bin`）
- `CRUX_REPO=marsup-space/crux` 改源仓库
- `CRUX_NO_PATH_UPDATE=1` 跳过自动改 PATH（CI、Docker 场景）

特性：

- 自动检测 OS 与架构：macOS arm64/x64、Linux arm64/x64、Windows x64/arm64；在 macOS x64 下检测到 Rosetta 会自动切到 arm64
- 把 `providers/`、`themes/`、`third_party/` 复制到二进制同目录，确保 Crux 能找到这些资源
- **自动把安装目录加到 PATH**：
  - 按 `$SHELL` 在候选 rc 文件列表里选**第一个已存在的**（bash → `~/.bashrc`/`.bash_profile`/`.profile`/XDG；zsh → `~/.zshrc`/`.zshenv`/XDG；fish → `~/.config/fish/config.fish`，写入 `fish_add_path` 命令）
  - 在 Windows 下额外用 `setx` 把目录加到当前用户的 Windows PATH，让 cmd / PowerShell 也能找到 `crux`
  - 如果 `GITHUB_ACTIONS=true`，自动追加到 `$GITHUB_PATH`（CI 场景）
  - 幂等：再次运行 install 不会重复写
- 装完跑一次 `crux --version` 验证
- 本地已装同版本直接退出

> 想先看脚本再跑？[`install.sh`](install.sh) ~280 行 bash——**整个项目里唯一的安装脚本**。无第三方依赖，只要求 `curl` + `unzip` + `bash`。

**手动下载**：所有平台的 zip 都在 [Releases 页面](https://github.com/marsup-space/crux/releases)。Scoop / winget / Homebrew manifest 后续会补上。

---

### 十字星 — 跨越关键，如星指引

**Crux**（拉丁文原意"十字"）是天文学中南十字座的学名，也是英文中"核心关键"与"最难路段"的代名词。

**十字星（Crux）** 是一个运行在终端中的 AI 编程助手（AI Coding Agent），通过智能体编排（Agentic Orchestration）帮助你更高效地编写代码、管理项目。

当前版本：**0.9.0**。项目已经进入日常可用状态，仍保持快速迭代。

| 中文名 | 十字星 |
|--------|--------|
| 英文名 | Crux |
| 寓意 | ✚ 十字 = 拉丁文 crux 本意，亦指枢纽交汇点 |
| | ⭐ 星 = 南十字星座，指引方向的坐标 |
| | 🧗 攀岩术语 crux = 路线最难路段，harness 助你跨越 |
| | 🎯 the crux of = 核心关键 |

### 为什么是 Crux

Crux 不是 Claude Code 或 OpenCode 的复制品。它更偏向一个**本地优先、Provider 可换、终端体验像桌面 App 一样细腻**的编程助手：自动 TLDR 让长回复持续可读，Nocterm TUI 提供按钮、鼠标 hover、弹窗和工具详情面板，harness 会主动优化 parallel toolcall、缓存命中和整体响应性能。

### 特性

- 🧾 **自动 TLDR** — Crux 的原创亮点功能：长回复超过阈值后自动用辅助模型生成 TLDR 气泡，既保留完整回答，又让后续回看和继续协作更轻松；也可用 `/tldr` 手动生成不同详细度摘要
- 🖥️ **桌面 App 级 TUI 体验** — 基于 Nocterm，无 Electron、无浏览器壳；按钮、鼠标 hover、分段按钮、弹窗、工具详情面板、状态栏和点击交互让终端应用用起来像桌面应用
- ⚡ **高性能终端渲染** — 面向长对话、流式输出、工具详情和指标刷新做过性能优化，并内置 frame profiler 方便定位慢帧
- 🔁 **Harness parallel toolcall 优化** — 针对模型容易串行调用工具的问题，Crux 会检测、提示并鼓励独立工具调用并行发出，减少模型往返回合
- 🎯 **缓存命中率优化** — 系统提示分层、稳定 cache prefix、provider/model prompt addition 和运行态元信息分离，尽量提高 prompt cache 命中率并在 UI 中显示命中情况
- 🤖 **Provider 优先的多模型架构** — 内置 DeepSeek、MiniMax、Local、LongCat；TOML Provider 配置可描述模型、上下文、图片能力、thinking、价格、余额和系统提示增量
- 🧠 **可调推理模式** — `/think off|low|normal|adaptive|high|max`，适配 DeepSeek、MiniMax、Anthropic 风格 thinking/reasoning，并可按模型覆盖预算
- 🔧 **Agentic 工具调用** — 读写文件、精确编辑、grep/glob、bash/cmd/powershell、web fetch；独立文件的写入和编辑可并行执行
- 🛡️ **更稳的编辑反馈** — 写入/编辑后接入 LSP 诊断，工具结果会把错误以专门气泡反馈给模型和用户，减少“改完才发现编译炸了”的回合数
- 💬 **多会话工作台** — 会话侧栏、归档/恢复、重命名、自动标题、历史查看、上下文压缩、最近项目切换
- 🗨️ **`/btw` 临时侧问** — 临时问模型一个旁支问题，不写入正式对话；连续 `/btw` 可串联，下一条正式消息时自动丢弃
- 🧾 **辅助模型** — 可用更快/更便宜的辅助模型生成会话标题、自动 TLDR 和手动摘要，把主模型上下文留给真正的编程任务
- 🖼️ **图片输入** — 支持图片附件、拖拽/粘贴路径识别、剪贴板图片读取（取决于平台能力），并自动按模型能力显示入口
- 🧭 **文件与项目导航** — `@` 文件提及弹窗、最近项目补全、git 状态栏、运行中指标、工具详情面板
- 📊 **Coding plan 用量显示** — 对支持的 Provider 展示 coding plan 配额、剩余量和时间窗口，让模型使用节奏在 TUI 里直接可见
- 💰 **成本、余额与性能可见** — 实时 token、TTFT、tok/s、成本估算、prompt cache 命中率；支持 Provider 暴露余额
- 🌐 **代理友好** — 网络请求直连失败时可自动回退系统代理，适合国内网络环境和多 Provider 工作流
- 🎨 **完整主题系统** — 8 个内置明暗主题，并支持 TOML 自定义主题

### 快速开始

```bash
# 拉取当前系统和架构所需的第三方原生工具
dart run tool/third_party.dart fetch

# 运行（从项目根目录）
dart run bin/crux.dart

# 指定工作目录
dart run bin/crux.dart /path/to/your/project
```

首次启动会展示启动动画，并自动初始化数据库和语法高亮服务。

### 发布构建

Crux 在 `third_party/manifest.json` 中固定第三方原生工具版本。开发环境使用
`third_party/bin/<os>-<arch>/`，发布包只会把目标平台需要的工具复制到可执行文件旁边的
`third_party/bin/`。

```bash
# 构建当前平台
dart run tool/build_release.dart

# 构建指定目标：
# macos-arm64, macos-x64, linux-arm64, linux-x64,
# windows-arm64, windows-x64
dart run tool/build_release.dart --target linux-x64
```

构建脚本会下载缺失工具、校验 SHA-256、通过 `dart build cli` 编译 Crux，并将
providers、themes、二进制工具和许可证复制到 `build/releases/crux-<target>/`。
`dart build cli` 会构建当前宿主平台，因此指定目标时需要在对应 OS/架构的宿主机上运行。

### CI

GitHub Actions 配置见 [`docs/ci.md`](docs/ci.md)。当前自动 CI 采用私有仓库友好的省额度策略：push/PR 只跑 Ubuntu 上的 Dart 检查和稳定 smoke tests；推送 `v*` tag 会自动构建 Linux、macOS、Windows release bundles 并上传到 GitHub Release，手动出包也可在 Actions 页面触发。

### 主题

使用 `/theme <name>` 即时切换并持久化主题。内置主题：

- 暗色：`dracula`、`onedarkpro`、`catppuccin`、`synthwave84`
- 亮色：`cobalt2`、`flexoki`、`rosepine`、`github`

自定义主题放在 `~/.config/crux/themes/`。首次启动会生成完整的
`example.theme.toml` 模板；复制并重命名后即可编辑。

### 配置 Provider

通过 `/provider` 命令接入 LLM 服务商：

| Provider | 命令 | 模型 |
|----------|------|------|
| DeepSeek | `/provider deepseek` | V4 Flash / V4 Pro |
| Local | `/provider local` | Llama 3 / Mistral |
| LongCat | `/provider longcat` | 2.0 |
| MiniMax | `/provider minimax` | M3 / M2.7 / M2.7 Highspeed |
| 自定义 | `/provider custom` | 任意兼容 API |

### 命令列表

| 命令 | 说明 |
|------|------|
| `/model` | 切换 AI 模型 |
| `/new` | 创建新会话 |
| `/session` | 切换会话 |
| `/clear` | 清空聊天记录 |
| `/compact` | 压缩上下文窗口 |
| `/help` | 查看帮助 |
| `/theme` | 切换主题 |
| `/history` | 查看当前会话历史 |
| `/provider` | 管理 Provider |
| `/think` | 切换思考模式 |
| `/auxiliary` | 配置辅助模型 |
| `/tldr` | 为上一条 AI 回复生成摘要 |
| `/project` | 切换项目目录 |
| `/continue` | 继续生成（别名：`/继续`） |
| `/retry` | 重试上一条用户输入（别名：`/重试`） |
| `/btw` | 临时侧问 — 不入对话记录，下次正常消息时丢弃 |
| `/archive` | 归档当前会话 |
| `/unarchive` | 恢复已归档会话 |
| `/rename` | 重命名当前会话 |
| `/debug` | 开关调试命令 |
| `/quit` | 退出 Crux — 在终端主缓冲区打印本次运行的总结（时长 / 轮数 / token / 缓存命中率） |

### 快捷键

- `Tab` — 命令补全
- `Ctrl+C` — 取消当前流式响应
- `↑/↓` — 浏览历史消息（在会话管理面板中）

### 技术栈

- **语言**: Dart 3.11+
- **UI 框架**: [Nocterm](https://github.com/marsup-space/nocterm) — 纯 Dart TUI 框架
- **数据库**: SQLite (drift)
- **语法高亮**: TextMate 语法
- **中文分词**: dart-jieba (结巴分词 Dart 移植)

### 项目结构

```
crux/
├── bin/crux.dart         # 入口
├── lib/
│   ├── crux.dart         # 库导出
│   ├── src/
│   │   ├── agents/       # Agent 定义（可扩展）
│   │   ├── commands/     # 斜杠命令
│   │   ├── components/   # TUI 组件
│   │   ├── models/       # 数据模型
│   │   ├── services/     # 核心服务
│   │   ├── storage/      # 持久化存储
│   │   ├── theme/        # 主题
│   │   ├── tools/        # Agent 工具
│   │   └── utils/        # 工具函数
├── providers/            # 内置 Provider 配置
├── themes/               # 内置 TOML 主题
├── docs/                 # 设计文档
└── test/                 # 测试
```

### 许可

MIT

---

## <a name="english"></a>🇬🇧 English

### Installation

**Crux has one install script.** `install.sh` pulls the prebuilt AOT binary from GitHub Releases, installs to `~/.crux/bin`, and configures PATH. It works on macOS, Linux, and Windows. **You only ever need to remember one filename: `install.sh`.**

One line, every platform:

```bash
curl -fsSL https://raw.githubusercontent.com/marsup-space/crux/main/install.sh | bash
```

The script is plain bash. It runs natively on macOS / Linux. On Windows you need a bash environment (WSL, Cygwin, or MSYS2 — any of them) — install.sh auto-detects `MINGW*` / `MSYS*` / `CYGWIN*` to fetch the Windows binary, and calls `setx` to register the install dir in your Windows user PATH so `crux` is reachable from cmd and PowerShell too.

Optional flags (every platform passes them with `-s --` to bash):

```bash
curl -fsSL .../install.sh | bash -s -- --version v0.7.0
curl -fsSL .../install.sh | bash -s -- --binary /path/to/crux
curl -fsSL .../install.sh | bash -s -- --no-modify-path
```

Environment variables (equivalent to flags; common in CI / Docker):

- `CRUX_VERSION=v0.10.0` — pin a version (default: `latest`)
- `CRUX_INSTALL_DIR=...` — override the install directory (default `~/.crux/bin`)
- `CRUX_REPO=marsup-space/crux` — change the source repository
- `CRUX_NO_PATH_UPDATE=1` — skip the automatic PATH modification (useful for CI / Docker)

What they do:

- Auto-detect OS and architecture: macOS arm64/x64, Linux arm64/x64, Windows x64/arm64 — also detects Rosetta on macOS x64 and switches to arm64
- Copy `providers/`, `themes/`, and `third_party/` next to the binary so Crux can find them
- **Auto-add the install directory to PATH**:
  - Picks the **first existing** rc file from a per-shell candidate list (bash → `~/.bashrc`/`.bash_profile`/`.profile`/XDG; zsh → `~/.zshrc`/`.zshenv`/XDG; fish → `~/.config/fish/config.fish`, writing a `fish_add_path` command)
  - On Windows, additionally calls `setx` to register the install dir in the user PATH so cmd and PowerShell can find `crux` too
  - When `GITHUB_ACTIONS=true`, appends to `$GITHUB_PATH` automatically
  - Idempotent — re-running the installer doesn't duplicate entries
- Run `crux --version` after install to verify
- Exit immediately if the same version is already installed

> Want to read it first? [`install.sh`](install.sh) is ~280 lines of plain bash — **the only install script in the project**. No third-party dependencies — only `curl` + `unzip` + `bash`.

**Manual download**: per-platform zips live on the [Releases page](https://github.com/marsup-space/crux/releases). Scoop / winget / Homebrew manifests will follow.

---

### Crux — Cross the crux, guided by the star

**Crux** is a terminal-based AI coding agent with agentic orchestration. Named after the Southern Cross constellation (Latin for "cross"), it embodies both the guiding star and the core challenge — helping you cross the crux of development.

Current version: **0.10.0**. Crux is now considered usable for daily work, while still moving quickly.

| Chinese name | 十字星 (Cross Star) |
|-------------|--------------------|
| English name | Crux |

### Why Crux

Crux is not a clone of Claude Code or OpenCode. It is a **local-first, provider-swappable coding agent with a desktop-app-quality terminal experience**: automatic TLDR keeps long answers readable, the Nocterm TUI has real buttons, mouse hover, popovers, and tool detail panes, and the harness actively optimizes parallel tool calls, cache hits, and overall responsiveness.

### Features

- 🧾 **Automatic TLDR** — An original Crux highlight: long responses can automatically get auxiliary-model TLDR bubbles, keeping the full answer intact while making review and follow-up work easier; `/tldr` is also available for manual summaries at different detail levels
- 🖥️ **Desktop-app-quality TUI** — Built on Nocterm with no Electron or browser shell; buttons, mouse hover, segmented controls, popovers, tool detail panes, status bars, and click interactions make the terminal feel like a real app
- ⚡ **Fast terminal performance** — Optimized for long conversations, streaming output, tool detail panes, and live metrics, with a built-in frame profiler for chasing slow frames
- 🔁 **Harness parallel tool-call optimization** — Crux detects and reinforces independent parallel tool calls, reducing unnecessary model round trips when the model would otherwise serialize work
- 🎯 **Prompt-cache hit optimization** — Layered system prompts, stable cache prefixes, provider/model prompt additions, and separated runtime metadata are designed to improve prompt-cache reuse, with cache-hit visibility in the UI
- 🤖 **Provider-first multi-model design** — DeepSeek, MiniMax, Local, and LongCat are bundled; TOML providers describe models, context windows, image support, thinking, pricing, balances, and prompt additions
- 🧠 **Adjustable reasoning** — `/think off|low|normal|adaptive|high|max`, with DeepSeek, MiniMax, and Anthropic-style thinking/reasoning support plus per-model budgets
- 🔧 **Agentic tool use** — Read, write, precise edit, grep/glob, bash/cmd/powershell, and web fetch; writes/edits to independent files can run in parallel
- 🛡️ **Edit feedback loop** — Write/edit tools collect LSP diagnostics and surface failures as dedicated bubbles for both the model and the user
- 💬 **Session workbench** — Sidebar sessions, archive/restore, rename, auto-title, history, context compaction, and recent-project switching
- 🗨️ **Ephemeral side questions** — `/btw` asks a quick aside without saving it to the real conversation; chained `/btw` turns disappear on the next normal message
- 🧾 **Auxiliary model** — Use a cheaper/faster auxiliary model for titles, automatic TLDRs, and manual summaries so the main model stays focused on coding
- 🖼️ **Image input** — Image attachments, dropped/pasted path recognition, and clipboard image reads where the platform supports them
- 🧭 **Project navigation** — `@` file mention popover, recent project completion, git status, live metrics, and a tool detail pane
- 📊 **Coding-plan usage display** — For supported providers, Crux shows coding-plan quota, remaining usage, and reset windows directly in the TUI
- 💰 **Costs, balances, and performance visibility** — Live tokens, TTFT, tok/s, cost estimates, prompt-cache hit rate, and provider credit balance when available
- 🌐 **Proxy-aware networking** — Requests can retry through the detected system proxy after direct connection failures, useful for multi-provider setups
- 🎨 **Full theme system** — Eight bundled dark/light themes plus custom TOML themes

### Quick Start

```bash
# Fetch bundled native tools for the current OS and architecture
dart run tool/third_party.dart fetch

# Run from project root
dart run bin/crux.dart

# With a working directory
dart run bin/crux.dart /path/to/your/project
```

### Release Builds

Crux pins third-party native tools in `third_party/manifest.json`. Development
uses `third_party/bin/<os>-<arch>/`, while release bundles contain only the
selected target under `third_party/bin/` beside the executable.

```bash
# Build for the current platform
dart run tool/build_release.dart

# Build one of:
# macos-arm64, macos-x64, linux-arm64, linux-x64,
# windows-arm64, windows-x64
dart run tool/build_release.dart --target linux-x64
```

The build script downloads missing tools, verifies their SHA-256 hashes, builds
Crux with `dart build cli`, and copies providers, themes, binaries, and licenses
into `build/releases/crux-<target>/`. `dart build cli` builds for the current
host platform, so explicit targets must run on a matching OS/architecture host.

### CI

See [`docs/ci.md`](docs/ci.md) for the GitHub Actions setup. The current
configuration is private-repo friendly: push/PR runs only Ubuntu Dart checks and
a stable smoke-test suite; pushing a `v*` tag automatically builds Linux,
macOS, and Windows release bundles and uploads them to GitHub Releases, while
manual packaging is also available from the Actions page.

### Commands

| Command | Description |
|---------|-------------|
| `/model` | Switch AI model |
| `/new` | Create new session |
| `/session` | Switch session |
| `/clear` | Clear chat log |
| `/compact` | Compact context window |
| `/help` | Show help |
| `/theme` | Change theme |
| `/history` | Show current session history |
| `/provider` | Manage providers |
| `/think` | Toggle thinking mode |
| `/auxiliary` | Configure auxiliary model |
| `/tldr` | Generate a summary for the last AI response |
| `/project` | Switch project directory |
| `/continue` | Continue generation (alias: `/继续`) |
| `/retry` | Retry the last user input (alias: `/重试`) |
| `/btw` | Ephemeral side-question — never persisted, dropped on next real turn |
| `/archive` | Archive the current session |
| `/unarchive` | Restore an archived session |
| `/rename` | Rename the current session |
| `/debug` | Toggle debug commands |
| `/quit` | Exit Crux — prints a run summary (duration / turns / tokens / cache hit %) to the terminal's main buffer |

### Themes

Use `/theme <name>` to switch immediately and persist the selection.

- Dark: `dracula`, `onedarkpro`, `catppuccin`, `synthwave84`
- Light: `cobalt2`, `flexoki`, `rosepine`, `github`

Place complete custom themes in `~/.config/crux/themes/`. Crux seeds an
`example.theme.toml` template on first launch.

### Tech Stack

- **Language**: Dart 3.11+
- **UI**: [Nocterm](https://github.com/marsup-space/nocterm) — pure Dart TUI framework
- **Database**: SQLite (drift)
- **Syntax highlighting**: TextMate grammars
- **Chinese segmentation**: dart-jieba

### License

MIT
