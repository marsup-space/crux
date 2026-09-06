<div align="center">

```
  ██████╗   ██████╗  ██╗   ██╗ ██╗  ██╗
 ██╔════╝  ██╔══██╗ ██║   ██║  ██╗██╔╝
 ██║      ██████╔╝ ██║   ██║   ███╔╝
 ██║      ██╔══██╗ ██║   ██║  ██╔██╗
  ██████╗ ██║  ██║  █████╔╝ ██╔╝ ██╗
```

# Crux · 十字星

**别人把 TUI 当入口，Crux 把 TUI 当产品。**

终端里交互密度最高的 AI 编程助手：模型可换、缓存最优、体验对标桌面应用。

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
curl -fsSL .../install.sh | bash -s -- --version v0.30.0
curl -fsSL .../install.sh | bash -s -- --binary /path/to/crux
curl -fsSL .../install.sh | bash -s -- --no-modify-path
```

环境变量（与参数等效，CI / Docker 场景常用）：

- `CRUX_VERSION=v1.0.0-rc.1` 锁定版本（默认 `latest`）
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

**十字星（Crux）** 是一个运行在终端中的 AI 编程助手（AI Coding Agent）。它不只把你和模型连起来——它把终端本身变成了一个可点击、可悬停、可拖拽的工作台，让"和 agent 一起写代码"这件事第一次有了桌面应用级别的手感。

当前版本见 [CHANGELOG](CHANGELOG.md)。项目已经进入日常可用状态，仍保持快速迭代。

| 中文名 | 十字星 |
|--------|--------|
| 英文名 | Crux |
| 寓意 | ✚ 十字 = 拉丁文 crux 本意，亦指枢纽交汇点 |
| | ⭐ 星 = 南十字星座，指引方向的坐标 |
| | 🧗 攀岩术语 crux = 路线最难路段，harness 助你跨越 |
| | 🎯 the crux of = 核心关键 |

### 为什么是 Crux

市面上的终端 coding agent 越来越像：一个输入框、一段流式文本、几个斜杠命令。Crux 选了另一条路——**TUI 不是入口，是产品本身**。

这意味着三件竞品没有同时做到的事：

1. **交互密度对标桌面应用。** 自研的 Nocterm TUI 框架（纯 Dart，无 Electron、无浏览器壳）提供真实按钮、鼠标 hover、分段按钮、弹窗、可拖拽/缩放/隐藏的 home dashboard 网格、语法高亮的 diff 全屏面板、可点击的 todo 列表。在终端里，这些交互是断档式的领先。
2. **缓存优化是 provider 无关的。** 有的 agent 为 DeepSeek 的 prefix cache 做了极致对齐——但代价是模型绑死。Crux 的缓存工程（分层系统提示、稳定 cache prefix、provider/model prompt addition 与运行态元信息分离）对**所有** provider 生效，同时 TOML provider 体系支持 DeepSeek / Kimi / MiniMax / Zhipu / MiMo / LongCat / OpenRouter / 本地模型。缓存命中率和成本直接显示在 UI 里，不是藏在日志里。
3. **协作协议层面的原创。** `/btw` 临时侧问（不污染对话）、`/undo` 把上一条输入放回输入框重新编辑、plan mode 双栏计划面板、`ask` 结构化提问让 agent 向你发起多选/表单、辅助模型自动生成 TLDR 和会话标题、agent 甚至能给自己写插件 UI——这些不是"模型套壳"，是"人与 agent 怎么协作"的重新设计。

### 特性

**体验**

- 🖥️ **桌面 App 级 TUI** — 基于自研 [Nocterm](https://github.com/marsup-space/nocterm)（纯 Dart）；按钮、鼠标 hover、分段按钮、弹窗、状态栏、点击交互，无 Electron、无浏览器壳
- 🏠 **Home Dashboard** — 可拖拽/缩放/隐藏的网格工作台：quick-chat 输入、会话切换、token 活动热力图、昨日摘要（辅助模型生成）、coding-plan 用量、设置面板、技能浏览
- 📋 **Plan Mode** — 双栏计划面板：左侧实时更新的计划文档，右侧对话；计划与 session 绑定，`ask` 工具让 agent 向你发起结构化多选/表单提问
- 🧾 **自动 TLDR** — 长回复超过阈值后自动用辅助模型生成 TLDR 气泡，保留完整回答的同时让回看和续写更轻松；`/tldr` 手动生成不同详细度摘要
- 💬 **多会话工作台** — 会话侧栏、归档/恢复、重命名、自动标题、历史查看、上下文压缩、最近项目切换、`/chat` 无工作区临时会话
- 🗨️ **`/btw` 临时侧问** — 临时问模型一个旁支问题，不写入正式对话；连续 `/btw` 可串联，下一条正式消息时自动丢弃
- 🎨 **完整主题系统** — 8 个内置明暗主题 + TOML 自定义主题
- 🌐 **完整 i18n** — `/language` 一键切换中英界面，全部 UI chrome 走消息目录，CJK 列宽对齐已处理

**Harness 工程**

- 🎯 **缓存命中率优化** — 系统提示分层、稳定 cache prefix、provider/model prompt addition 和运行态元信息分离；缓存命中率实时显示在 UI
- 🔁 **Parallel toolcall 优化** — 检测并鼓励模型把独立工具调用并行发出；独立文件的写入和编辑真正并行执行，减少往返回合
- 🛡️ **编辑反馈闭环** — 写入/编辑后接 LSP 诊断，错误以专门气泡反馈给模型和用户，减少"改完才发现编译炸了"的回合
- 🧠 **可调推理模式** — `/think off|low|normal|adaptive|high|max`，适配 DeepSeek、MiniMax、Kimi、Anthropic 风格 thinking/reasoning，按模型覆盖预算
- 🔧 **完整的 agentic 工具集** — 读写文件、精确编辑、grep/glob、bash/cmd/powershell、web fetch、图片输入（拖拽/粘贴/剪贴板）
- 📊 **指标即 UI** — 实时 token、TTFT、tok/s、成本估算、缓存命中率、coding-plan 配额与剩余量、provider 余额——全部直接显示在界面里
- 🌐 **代理友好** — 直连失败自动回退系统代理，适合国内网络环境和多 provider 工作流

**可扩展性**

- 🔌 **TOML 插件系统** — 往 `.crux/plugins/*.toml`（项目级）或 `~/.crux/plugins/*.toml`（全局）丢一个 spec 文件，2 秒内侧边栏和/或 home 网格就出现一个实时状态框 + 一键操作按钮；agent 可以自己写插件
- ⚙️ **cruxd 插件 sidecar** — 用户级 daemon 管理插件的后台生产者进程：多实例引用计数、崩溃自动重启、指数退避、最后一个实例退出时自动清理
- 🤖 **TOML Provider 体系** — 一个 TOML 文件描述一个 provider 的模型、上下文窗口、图片能力、thinking 档位、价格、余额接口和系统提示增量

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

### 配置 Provider

通过 `/provider` 命令接入 LLM 服务商：

| Provider | 命令 | 模型 |
|----------|------|------|
| DeepSeek | `/provider deepseek` | V4 Flash / V4 Pro / V4 Flash Vision |
| ChatGPT Codex | `/provider codex login` | GPT-6 Astra / GPT-5.6 系列 |
| Kimi | `/provider kimi` | K3 (1M / 256K) / K2.7 Code / K2.7 Code Highspeed |
| MiniMax | `/provider minimax` | M3 / M2.7 / M2.7 Highspeed |
| Zhipu | `/provider zhipu` | GLM-5.3 / GLM-5.3-Flash |
| MiMo | `/provider mimo` | V2.5 Pro / V2.5 / V2.5 Pro UltraSpeed |
| LongCat | `/provider longcat` | 2.0 |
| OpenRouter Free | `/provider openrouter-free` | 免费档位模型自动同步 |
| Local | `/provider local` | Llama 3 / Mistral |
| 自定义 | `/provider custom` | 任意兼容 API |

也可以用环境变量直接提供 API key（无需交互，适合 CI / 脚本场景）：

- `CRUX_API_KEY` — 全局默认 key
- `CRUX_API_KEY_<PROVIDER>` — 按 Provider 覆盖（Provider 名大写），如 `CRUX_API_KEY_DEEPSEEK`、`CRUX_API_KEY_MINIMAX`

ChatGPT Codex 使用 ChatGPT OAuth（不是 OpenAI API key）。运行 `/provider codex login` 后在浏览器输入设备码即可，额度会显示在 Coding Plan widget；也可通过 `CRUX_API_KEY_CODEX` 提供外部 token。

### 命令列表

| 命令 | 说明 |
|------|------|
| `/model` | 切换 AI 模型 |
| `/new` | 创建新会话 |
| `/chat` | 创建无工作区的临时会话 |
| `/session` | 切换会话 |
| `/home` | 回到 home dashboard |
| `/plan` | 进入/退出 plan mode |
| `/compact` | 压缩上下文窗口 |
| `/help` | 查看帮助 |
| `/theme` | 切换主题 |
| `/language` | 切换界面语言（English / 中文） |
| `/reply-language` | 设置回复语言（follow / auto） |
| `/provider` | 管理 Provider |
| `/web-provider` | 配置 web 搜索/抓取 Provider |
| `/think` | 切换思考模式 |
| `/temperature` | 覆盖本会话的采样温度（0.0–1.0） |
| `/view` | 切换聊天记录显示模式（verbose\|vibe） |
| `/auxiliary` | 配置辅助模型 |
| `/tldr` | 为上一条 AI 回复生成摘要（concise\|default\|detailed） |
| `/project` | 切换项目目录 |
| `/continue` | 继续生成（别名：`/继续`） |
| `/retry` | 重试上一条用户输入（别名：`/重试`） |
| `/undo` | 撤销上一轮对话，把输入放回输入框重新编辑（别名：`/撤销`） |
| `/btw` | 临时侧问 — 不入对话记录，下次正常消息时丢弃 |
| `/archive` | 归档当前会话 |
| `/unarchive` | 恢复已归档会话 |
| `/rename` | 重命名当前会话 |
| `/debug` | 开关调试命令 |
| `/quit` | 退出 — 在主缓冲区打印运行总结（时长 / 轮数 / token / 缓存命中率） |

### 快捷键

- `Tab` — 命令补全
- `Ctrl+C`（流式输出中）— 取消当前响应
- 双击 `Ctrl+C` — 退出 Crux
- `ESC`×2 — 中断流式输出
- `Ctrl+V` — 粘贴图片（需当前模型支持图片输入）
- 会话管理面板中：`Ctrl+D` 删除会话 / `Ctrl+R` 重命名会话
- `@` — 文件提及
- `$` — 技能

### 主题

使用 `/theme <name>` 即时切换并持久化主题。内置主题：

- 暗色：`dracula`、`onedarkpro`、`catppuccin`、`synthwave84`
- 亮色：`cobalt2`、`flexoki`、`rosepine`、`github`

自定义主题放在 `~/.config/crux/themes/`。首次启动会生成完整的
`example.theme.toml` 模板；复制并重命名后即可编辑。

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

### 技术栈

- **语言**: Dart 3.13+
- **UI 框架**: [Nocterm](https://github.com/marsup-space/nocterm) — 自研纯 Dart TUI 框架（submodule）
- **数据库**: SQLite (drift)
- **语法高亮**: TextMate 语法
- **中文分词**: dart-jieba (结巴分词 Dart 移植)

### 项目结构

```
crux/
├── bin/crux.dart         # 入口
├── bin/cruxd.dart        # 插件 sidecar daemon（serve|status|stop）
├── lib/
│   ├── crux.dart         # 库导出
│   ├── src/
│   │   ├── commands/     # 斜杠命令
│   │   ├── components/   # TUI 组件（chat / home / plan / sidebar / …）
│   │   ├── daemon/       # cruxd 插件生产者管理
│   │   ├── i18n/         # 界面字符串目录（en / zh）
│   │   ├── lsp/          # LSP 诊断接入
│   │   ├── markdown/     # Markdown 渲染
│   │   ├── models/       # 数据模型
│   │   ├── services/     # 核心服务（LLM / 插件注册表 / …）
│   │   ├── storage/      # 持久化存储
│   │   ├── theme/        # 主题
│   │   ├── tools/        # Agent 工具
│   │   └── utils/        # 工具函数
├── providers/            # 内置 Provider TOML 配置
├── themes/               # 内置 TOML 主题
├── docs/                 # 设计文档
└── test/                 # 测试（163 个测试文件）
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
curl -fsSL .../install.sh | bash -s -- --version v0.30.0
curl -fsSL .../install.sh | bash -s -- --binary /path/to/crux
curl -fsSL .../install.sh | bash -s -- --no-modify-path
```

Environment variables (equivalent to flags; common in CI / Docker):

- `CRUX_VERSION=v1.0.0-rc.1` — pin a version (default: `latest`)
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

**Crux** is a terminal-based AI coding agent. Named after the Southern Cross constellation (Latin for "cross"), it embodies both the guiding star and the core challenge — helping you cross the crux of development.

Crux doesn't just connect you to a model — it turns the terminal itself into a clickable, hoverable, draggable workbench, giving "pair-programming with an agent" a desktop-app-grade feel for the first time.

See [CHANGELOG](CHANGELOG.md) for the current version. Crux is usable for daily work and still moving fast.

| Chinese name | 十字星 (Cross Star) |
|-------------|--------------------|
| English name | Crux |

### Why Crux

Terminal coding agents are converging on the same shape: an input box, a stream of text, a few slash commands. Crux took a different path — **the TUI is not an entry point, it is the product**.

That means three things no competitor combines:

1. **Desktop-app interaction density.** The self-built Nocterm TUI framework (pure Dart — no Electron, no browser shell) delivers real buttons, mouse hover, segmented controls, popovers, a draggable/resizable/hideable home dashboard grid, a syntax-highlighted diff fullpane, and clickable todo lists. In the terminal, this interaction depth is in a class of its own.
2. **Cache engineering that works with every provider.** Some agents align perfectly to one vendor's prefix cache — at the cost of locking you to that vendor's models. Crux's cache engineering (layered system prompts, stable cache prefixes, provider/model prompt additions separated from runtime metadata) applies to **every** provider, while the TOML provider system supports DeepSeek / Kimi / MiniMax / Zhipu / MiMo / LongCat / OpenRouter / local models. Cache hit rate and cost are shown in the UI, not buried in logs.
3. **Original collaboration protocols.** `/btw` ephemeral side-questions (never persisted), `/undo` putting your last prompt back in the input box for editing, a dual-pane plan mode, an `ask` tool that lets the agent ask you structured multi-choice questions, an auxiliary model auto-generating TLDRs and session titles, and agents that can write their own plugin UIs — these aren't "model wrappers", they're a redesign of how humans and agents collaborate.

### Features

**Experience**

- 🖥️ **Desktop-app-grade TUI** — Built on the self-developed [Nocterm](https://github.com/marsup-space/nocterm) (pure Dart); buttons, mouse hover, segmented controls, popovers, status bars, click interactions — no Electron, no browser shell
- 🏠 **Home dashboard** — A draggable/resizable/hideable grid workbench: quick-chat input, session switching, token-activity heatmap, yesterday's summary (auxiliary-model generated), coding-plan usage, settings panel, skill browser
- 📋 **Plan mode** — Dual-pane planning surface: a live plan document on the left, conversation on the right; plans bind to sessions, and the `ask` tool lets the agent fire structured multi-select / form questions at you
- 🧾 **Automatic TLDR** — Long responses past a threshold automatically get auxiliary-model TLDR bubbles, keeping the full answer intact while making review and follow-up easier; `/tldr` for manual summaries at different detail levels
- 💬 **Session workbench** — Sidebar sessions, archive/restore, rename, auto-title, history, context compaction, recent-project switching, `/chat` workspace-free sessions
- 🗨️ **`/btw` side questions** — Ask a quick aside without saving it to the real conversation; chained `/btw` turns disappear on the next normal message
- 🎨 **Full theme system** — Eight bundled dark/light themes plus custom TOML themes
- 🌐 **Full i18n** — `/language` switches the UI between English and Chinese; all UI chrome goes through a message catalog with CJK column-width alignment handled

**Harness engineering**

- 🎯 **Prompt-cache optimization** — Layered system prompts, stable cache prefixes, provider/model prompt additions separated from runtime metadata; cache hit rate shown live in the UI
- 🔁 **Parallel tool-call optimization** — Detects and encourages the model to emit independent tool calls in parallel; writes/edits to independent files genuinely run concurrently, cutting round trips
- 🛡️ **Edit feedback loop** — Write/edit tools collect LSP diagnostics and surface failures as dedicated bubbles for both the model and the user — fewer "edited, then found the build broken" rounds
- 🧠 **Adjustable reasoning** — `/think off|low|normal|adaptive|high|max`, with DeepSeek, MiniMax, Kimi, and Anthropic-style thinking/reasoning support plus per-model budgets
- 🔧 **Full agentic toolset** — Read, write, precise edit, grep/glob, bash/cmd/powershell, web fetch, image input (drag-drop / paste / clipboard)
- 📊 **Metrics as UI** — Live tokens, TTFT, tok/s, cost estimates, cache hit rate, coding-plan quota and remaining usage, provider balance — all rendered directly in the interface
- 🌐 **Proxy-aware** — Automatic fallback to the system proxy when direct connections fail, suited for multi-provider workflows

**Extensibility**

- 🔌 **TOML plugin system** — Drop a spec into `.crux/plugins/*.toml` (project) or `~/.crux/plugins/*.toml` (global) and within 2 seconds a live status box + one-click action buttons appear in the sidebar and/or home grid; agents can write their own plugins
- ⚙️ **cruxd plugin sidecar** — A user-level daemon managing plugin producer processes: reference-counted across instances, crash-restarted with exponential backoff, cleaned up when the last instance exits
- 🤖 **TOML provider system** — One TOML file describes a provider's models, context windows, image support, thinking tiers, pricing, balance endpoints, and prompt additions

### Quick Start

```bash
# Fetch bundled native tools for the current OS and architecture
dart run tool/third_party.dart fetch

# Run from project root
dart run bin/crux.dart

# With a working directory
dart run bin/crux.dart /path/to/your/project
```

### Configure Providers

Connect LLM providers with the `/provider` command:

| Provider | Command | Models |
|----------|---------|--------|
| DeepSeek | `/provider deepseek` | V4 Flash / V4 Pro / V4 Flash Vision |
| ChatGPT Codex | `/provider codex login` | GPT-6 Astra / GPT-5.6 系列 |
| Kimi | `/provider kimi` | K3 (1M / 256K) / K2.7 Code / K2.7 Code Highspeed |
| MiniMax | `/provider minimax` | M3 / M2.7 / M2.7 Highspeed |
| Zhipu | `/provider zhipu` | GLM-5.3 / GLM-5.3-Flash |
| MiMo | `/provider mimo` | V2.5 Pro / V2.5 / V2.5 Pro UltraSpeed |
| LongCat | `/provider longcat` | 2.0 |
| OpenRouter Free | `/provider openrouter-free` | Auto-synced free-tier models |
| Local | `/provider local` | Llama 3 / Mistral |
| Custom | `/provider custom` | Any compatible API |

API keys can also be supplied via environment variables (no interaction needed; handy for CI / scripts):

- `CRUX_API_KEY` — global default key
- `CRUX_API_KEY_<PROVIDER>` — per-provider override (provider name uppercased), e.g. `CRUX_API_KEY_DEEPSEEK`, `CRUX_API_KEY_MINIMAX`

ChatGPT Codex uses ChatGPT OAuth rather than an OpenAI API key. Run `/provider codex login`, open the verification page, and enter the device code; its remaining usage appears in the Coding Plan widget. You can also set `CRUX_API_KEY_CODEX` for an externally managed token.

### Commands

| Command | Description |
|---------|-------------|
| `/model` | Switch AI model |
| `/new` | Create new session |
| `/chat` | Create a workspace-free scratch session |
| `/session` | Switch session |
| `/home` | Return to the home dashboard |
| `/plan` | Enter/exit plan mode |
| `/compact` | Compact context window |
| `/help` | Show help |
| `/theme` | Change theme |
| `/language` | Switch UI language (English / 中文) |
| `/reply-language` | Set reply language (follow / auto) |
| `/provider` | Manage providers |
| `/web-provider` | Configure web search/fetch providers |
| `/think` | Toggle thinking mode |
| `/temperature` | Override sampling temperature for this session (0.0–1.0) |
| `/view` | Switch chat log display mode (verbose\|vibe) |
| `/auxiliary` | Configure auxiliary model |
| `/tldr` | Generate a summary for the last AI response (concise\|default\|detailed) |
| `/project` | Switch project directory |
| `/continue` | Continue generation (alias: `/继续`) |
| `/retry` | Retry the last user input (alias: `/重试`) |
| `/undo` | Undo the last turn and put the prompt back in the input for editing (alias: `/撤销`) |
| `/btw` | Ephemeral side-question — never persisted, dropped on next real turn |
| `/archive` | Archive the current session |
| `/unarchive` | Restore an archived session |
| `/rename` | Rename the current session |
| `/debug` | Toggle debug commands |
| `/quit` | Exit — prints a run summary (duration / turns / tokens / cache hit %) to the main buffer |

### Shortcuts

- `Tab` — command completion
- `Ctrl+C` (while streaming) — cancel the current response
- Double-press `Ctrl+C` — quit Crux
- `ESC`×2 — interrupt streaming output
- `Ctrl+V` — paste an image (requires a model with image input)
- In the session panel: `Ctrl+D` delete a session / `Ctrl+R` rename a session
- `@` — file mention
- `$` — skill

### Themes

Use `/theme <name>` to switch immediately and persist the selection.

- Dark: `dracula`, `onedarkpro`, `catppuccin`, `synthwave84`
- Light: `cobalt2`, `flexoki`, `rosepine`, `github`

Place complete custom themes in `~/.config/crux/themes/`. Crux seeds an
`example.theme.toml` template on first launch.

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

### Tech Stack

- **Language**: Dart 3.13+
- **UI**: [Nocterm](https://github.com/marsup-space/nocterm) — self-developed pure-Dart TUI framework (submodule)
- **Database**: SQLite (drift)
- **Syntax highlighting**: TextMate grammars
- **Chinese segmentation**: dart-jieba

### License

MIT
