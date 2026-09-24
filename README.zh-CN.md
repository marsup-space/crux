# Crux · 十字星

**桌面级体验。终端级体量。**

你的终端 AI 编程工作台。细致的交互，即时的响应。从计划、编码到审阅，让每一步都顺手。

- **终端里的每一步，都值得打磨。** 真实按钮、鼠标交互、可调整的工作台。
- **内置 Git 客户端。** 从并排查看 diff 到暂存与提交，一处完成。
- **Agent 动态生成插件，直接在工作台使用。** 告诉 Agent 你需要什么，新插件自动加载，无需重启。
- **直接操作，让任务继续。** Agent 构建表单与控件，你的操作反馈回对话，推动任务向前。
- **终端，不代表只能展现文字。** Mermaid 图表与对话一起阅读。
- **把时间和上下文，用在关键处。** 语义代码搜索、前缀缓存与并行工具。

模型由你选。DeepSeek · Kimi K2.8 Preview · MiniMax · Codex · 自定义兼容接口。

[下载：macOS、Linux、Windows](https://github.com/marsup-space/crux/releases) · [English](README.md)

## 安装

**macOS / Linux**

```bash
curl -fsSL https://raw.githubusercontent.com/marsup-space/crux/v1.1.7/install.sh | bash -s -- --version v1.1.7
```

**Windows（PowerShell）** — 下载 [install.ps1](install.ps1)，然后运行：

```powershell
& .\install.ps1 -Version 1.1.7
```

使用预编译安装包，无需 Dart SDK。安装后若找不到 `crux` 命令，重新打开终端。

## 推荐终端与字体

- **终端：** macOS / Linux 推荐 [Ghostty](https://ghostty.org/download)；Windows 推荐 [Windows Terminal](https://learn.microsoft.com/en-us/windows/terminal/install)。
- **字体：** [Maple Mono](https://github.com/subframe7536/maple-font/releases/latest) 或 [Fira Code](https://github.com/tonsky/FiraCode/releases/latest)。安装后，记得在终端设置中选用。

## 开始使用

```bash
cd /path/to/your/project
crux
```

首次启动跟随 **Setup** 提示连接模型，然后直接描述你想实现或修改的内容。用 `/plan` 先做计划，`/project` 切换项目，`/setup` 重新配置。
