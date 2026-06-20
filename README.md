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

## <a name="chinese"></a>🇨🇳 中文

### 十字星 — 跨越关键，如星指引

**Crux**（拉丁文原意"十字"）是天文学中南十字座的学名，也是英文中"核心关键"与"最难路段"的代名词。

**十字星（Crux）** 是一个运行在终端中的 AI 编程助手（AI Coding Agent），通过智能体编排（Agentic Orchestration）帮助你更高效地编写代码、管理项目。

当前版本：**0.7.0**。项目已经进入日常可用状态，仍保持快速迭代。

| 中文名 | 十字星 |
|--------|--------|
| 英文名 | Crux |
| 寓意 | ✚ 十字 = 拉丁文 crux 本意，亦指枢纽交汇点 |
| | ⭐ 星 = 南十字星座，指引方向的坐标 |
| | 🧗 攀岩术语 crux = 路线最难路段，harness 助你跨越 |
| | 🎯 the crux of = 核心关键 |

### 特性

- 🖥️ **纯终端界面** — 基于 Nocterm TUI 框架，无需 Electron，无需浏览器
- 🤖 **多模型支持** — 内置 DeepSeek、Local、MiniMax,亦可接入任意兼容 API 的供应商
- 🔧 **Agentic 工具调用** — Agent 可自主调用文件读写、搜索、bash 执行等工具
- 💬 **会话管理** — 多会话并行，支持切换、历史回溯、自动标题生成
- 🧠 **推理模式** — 支持思考模式（Thinking Mode），可调节推理深度
- 🖼️ **图片输入** — 支持图片附件与剪贴板图片读取（取决于平台能力）
- 🔌 **Provider 插件** — 灵活接入任意 API 兼容的模型供应商
- 💰 **用量统计** — 实时 Token 计数和成本估算
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

构建脚本会下载缺失工具、校验 SHA-256、编译 Crux，并将 providers、themes、二进制工具和许可证复制到
`build/releases/crux-<target>/`。部分目标可由 Dart 交叉编译；如果本地 SDK 不支持目标平台，发布自动化应在兼容宿主机上运行。

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
| `/config` | 查看/编辑配置 |
| `/theme` | 切换主题 |
| `/provider` | 管理 Provider |
| `/think` | 切换思考模式 |
| `/auxiliary` | 配置辅助模型 |
| `/project` | 切换项目目录 |
| `/btw` | 临时侧问 — 不入对话记录，下次正常消息时丢弃 |
| `/rename` | 重命名当前会话 |
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

### Crux — Cross the crux, guided by the star

**Crux** is a terminal-based AI coding agent with agentic orchestration. Named after the Southern Cross constellation (Latin for "cross"), it embodies both the guiding star and the core challenge — helping you cross the crux of development.

Current version: **0.7.0**. Crux is now considered usable for daily work, while still moving quickly.

| Chinese name | 十字星 (Cross Star) |
|-------------|--------------------|
| English name | Crux |

### Features

- 🖥️ **Pure terminal UI** — Built on the Nocterm TUI framework, no Electron or browser needed
- 🤖 **Multi-model** — DeepSeek, Local, and MiniMax out of the box; any API-compatible provider can be plugged in
- 🔧 **Agentic tool use** — Autonomous file read/write, search, bash execution
- 💬 **Session management** — Parallel sessions, history, auto-title generation
- 🧠 **Thinking mode** — Adjustable reasoning depth
- 🖼️ **Image input** — Image attachments and clipboard image reads where the platform supports them
- 🔌 **Pluggable providers** — Connect any API-compatible LLM provider
- 💰 **Usage tracking** — Real-time token counting and cost estimation
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

The build script downloads missing tools, verifies their SHA-256 hashes,
compiles Crux, and copies providers, themes, binaries, and licenses into
`build/releases/crux-<target>/`. Dart can cross-compile some targets, but
release automation should run each target on a compatible host when the local
SDK reports that a target is unsupported.

### Commands

| Command | Description |
|---------|-------------|
| `/model` | Switch AI model |
| `/new` | Create new session |
| `/session` | Switch session |
| `/clear` | Clear chat log |
| `/compact` | Compact context window |
| `/help` | Show help |
| `/config` | View/edit configuration |
| `/theme` | Change theme |
| `/provider` | Manage providers |
| `/think` | Toggle thinking mode |
| `/auxiliary` | Configure auxiliary model |
| `/project` | Switch project directory |
| `/btw` | Ephemeral side-question — never persisted, dropped on next real turn |
| `/rename` | Rename the current session |
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
