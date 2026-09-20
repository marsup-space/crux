# Subagent v2

## 理念

两个**独立开关**，可单开可同开（同开 = 中间模式：既派活又请教）：

- **workers on**：主 agent 可派发 worker 干活（自己是否动手见开放问题）
- **experts on**：主 agent 可请教只读专家把关

## 执行模型（主 agent 永不阻塞）

**身份持久、执行临时**：agent 档案（名字/角色/领域/模型/状态/知识/工作记录）持久存在；send/hire 触发一个后台 run——独立上下文 + 完整轮次循环，跑完任务，**报告通过系统信封事件送回主 agent**。

- **send/hire 工具调用立即返回**（"已派发 agent://orion，完成后会主动汇报"），主 agent 可继续与用户对话
- 无持久 worker 进程、无重启回放；runs 零持久化，**一张档案表** + meta 复用 agentBubble
- 后台 run 由进程内 runner 管理（同 cruxd producer 的生命周期模式）；重启 = 无 run：档案自动回 ready，旧版"busy 卡死"结构性消失
- ESC 打断主轮次不杀后台 run（用户想停某 worker 用 cancel_agent / 点 chip）
- 状态只有两种：**busy / ready**（无 retired——见"上下文与蒸馏"）

### 报告送回（旧版 wake bug 的根治）

subagent 完成/失败/被取消 → 以**系统信封事件**注入主会话唤醒主 agent——**绝不作为 user 消息**。信封走 system content（同旧版修复 83775b41 的运行时信封路径），模板：

```
[Crux system note — subagent report]
from: agent://orion (worker, domain: token-refresh)
intention: 修复 token 过期竞态
status: completed | failed | cancelled
report: |
  <worker 的报告正文，颗粒度由派活 message 指定>
next: 该 worker 已就绪（ready），可继续 send_agent 派活。
```

规则：
- 信封是**唯一**的送回通道；任何 subagent 内容不得以 user 角色进入主会话（wire 层已有空 user 行丢弃闸门，双保险）
- 信封可被 compact 保留（同 Internal Subagent events 的 compaction 规则）
- UI 渲染：verbose 显示 AgentBubble，vibe 折叠进 agents box（既有通路）

## 工具面（按开关注册，两开关共用 agents 目录）

| 工具 | 开关 | 说明 |
|---|---|---|
| `find_agents(query?, role?)` | 任一 | 找 agent（规格见下） |
| `hire_agent(role, domain, intention, message)` | 任一 | 新建 agent 并**立即执行**首个任务；星座命名 |
| `send_agent(agent, intention, message, ifBusy)` | 任一 | **唯一动作入口**：agent 空闲→消息即任务开跑；busy 按 `ifBusy`：**queue**（默认，入队）或 **fork**（复制档案+新星座名立即执行，工具结果告知"X busy，已 fork 为 Y 执行"） |
| `check_agent(agent)` | 任一 | **快照式状态检查**（回答"他怎么样了"）：复制该 agent 当前上下文 → 发"请停止当前工作，给我一个 status update" → 拿到回复即丢弃该快照会话。原会话零干扰；快照有完整上下文且前缀缓存命中（费用低）。ready 的 agent 不 fork，直接返回档案摘要（零 LLM 调用） |
| `cancel_agent(agent, reason?)` | 任一 | 中断该 agent 当前 run + 清空队列 + 状态回 ready（档案保留）；reason 写入 worklog |

- `intention` 必填：一行话说明这次派活的意图——UI tooltip 给用户看，compact 后档案仍记得"做过什么"（写入 worklog）
- 角色=权限：worker 读写+工具；expert 只读+工具。**同一个 send_agent**，行为由档案 role 决定（expert 跑完的"报告"自然就是回答）
- 禁递归 subagent；expert 禁问用户

### 命名（延续星座系，按角色分池）

- **expert = 黄道 12 宫**（白羊/金牛/双子/巨蟹/狮子/处女/天秤/天蝎/射手/摩羯/水瓶/双鱼——用大众化占星译名，不用天文规范译名）
- **worker = 其余 75 个 IAU 星座**（沿旧版 `worker_constellations.dart`，去掉 crux 与黄道 12）
- 池耗尽则加数字后缀：`orion-2`；克隆/fork 从对应池取下一个可用名
- 持久 id 存星座名，**显示名走本地化**（`WorkerNameLocalizer` 已有 en/zh 双语表，补黄道 12 宫词条）

### 引用格式

- agent 在对话/输出里必须用 **`agent://orion`** 表示（同 `ses://<id>` 的 可点击 scheme）
- 传 tool 参数时也用这个格式——解析到档案；UI 渲染本地化显示名，持久层只见稳定 id

## 模型分配（hire/fork 的选型规则）

配置按角色分池，每模型带并行上限，如 workers 池：

```toml
[subagent.workers]
models = [
  { model = "openai/gpt-5.6-terra", concurrency = 2 },
  { model = "deepseek/deepseek-v4.1-flash", concurrency = 8 },
]
```

- **hire**：名字随机（对应池取星座）；模型按池序选——**首选池内未满载的第一个**（terra 并行 <2 用 terra，已 2 并行才用 flash）。一旦分配，**模型与 agent 绑定死**（档案固定，provider 缓存/上下文计量都按模型走）
- **fork**：优先继承源 agent 的模型；该模型已满载才 fallback 到池内下一个可用
- **额度检查（选型前置）**：池内模型的可用性 = 并发未满 **且** 有额度。coding plan（5h/周窗口）与 credit balance（余额）需统一为一个余量查询接口——现有 `CodingPlanProvider` 轮询与 `CreditBalanceProvider` 各自为政，P1 抽象 `remainingBudget(model)` 归一：返回 充裕/紧张/耗尽；耗尽的模型跳过，紧张的照常选
- 并行计数 = 该模型当前 busy 的 run 数（含 fork 出来的）；run 结束即释放
- experts 池同理，独立配置

### find_agents 规格

- **默认返回 busy + ready 全部**（找的是"谁懂这个领域"）
- `role`: all(默认)/workers/experts
- `query` 模糊匹配 name + domain + 当前/上次任务 intention（`fuzzy_match.dart` 六级匹配）
- 返回每 agent：名字、模型、角色（✎worker/✦expert）、领域、上下文窗口 used/max、状态、任务 intention（busy=当前，ready=上次）

## 上下文与蒸馏（代替 retire 的续命机制）

**run 内三段式**（同一个 assignment 做到一半也能续命，不是等下次 assign）：

1. 上下文第 1、2 次满 → 正常走 crux compact（对话压缩），继续工作。**若正在 streaming：打断当前流 → compact → 发"继续"指令恢复**（不是等回合边界）
2. 第 3 次满 → **不再 compact**，改走**知识蒸馏**，生成三份产物：
   - **领域知识**：该领域学到的所有知识点
   - **工作记录**：做过什么、结论如何
   - **继续指令**（instruction for after compaction）：当前任务做到哪、下一步做什么
3. 蒸馏完直接把 instruction 发给该 agent → 以 `knowledge + worklog + instruction` 重启上下文，**无缝继续当前 assignment**

蒸馏产物同时写入档案（knowledge/worklog 字段），下次 send 也用。相当于 codex 式"自动总结上下文"而非压缩历史——agent 越用越有经验，永不 retire。

### 同机制用于主 agent

主 agent 目前只有手动 /compact 和回合开始前超阈值自动 compact，往往已经超限。同样引入三段式：第 3 次将满时蒸馏成 knowledge + worklog + instruction 继续当前轮次——subagent 与主 agent 共用一套蒸馏实现（复用 ChatService.createChatLogCompaction 之外的独立入口）。

## 提示词（三份，随 P1 起草）

### Worker 系统提示词（档案 run 的 system prompt）

身份与职责：你是 `<星座名>`，一名专注 `<domain>` 领域的 worker agent，由主 agent 指挥。骨架复用主 agent 提示词的工程规则段（语言镜像、代码探索、复用优先），叠加：

- 完成任务、报告结果，不与用户对话（你见不到用户）
- 报告颗粒度**由派活的 message 指定**（主 agent 说"给我一句话结论"就一句话；没说则默认：结论 + 改动文件清单 + intention 完成度）
- 上下文满会被自动 compact/蒸馏，重要结论写进报告而不是留在上下文里
- 禁止调用任何 subagent 工具（无递归）

### Expert 系统提示词

身份与职责：你是 `<星座名>`，一名 `<domain>` 领域的**只读**专家。同骨架，叠加：

- 只读工具面（无 edit/write/bash 写路径）；给判断、给依据、给建议方案，**不动手改**
- 回答 = 你的报告：结论先行，依据引用具体 file:line
- 被问"做得怎么样"时给 status update（check_agent 快照会这样问）

### 模式开启公告（骑在切换后第一条用户消息上）

一段简短使用指南（crux 系统提示格式），内容要点：

- 你现在处于 worker/expert subagent 模式；动手的活（edit/write/bash 类）**必须** send_agent 派给 worker，自己只做拆解、派发、验收
- **大任务先拆**：拆成多个独立、可并行的子任务，分别派给**不同** worker 并发执行（send_agent 即时返回、后台并发跑；子任务之间保持不重叠、无顺序依赖，结果可直接拼装）
- 拿不准方案/需要把关时 hire 或 send 一个 expert 请教
- find_agents 先看有谁；check_agent 问进度；cancel_agent 刹车
- 派活时 message 里写清：任务边界、验收标准、**报告颗粒度**
- 退出公告（对称）：已退出 subagent 模式，工具恢复亲自使用

### 派活方（主 agent）约定

报告颗粒度**不编码进工具**——主 agent 在 message 里指定（"一句话结论"/"详细报告"）。worker 提示词声明默认值，message 可覆盖。

## UI

- **Toolbar 上方 subagent bar**：含 workers / experts 两个 toggle；任一开关开启即显示此 bar
- Bar 内 chips = 当前 in-flight 的执行体，喂已保留的 `SubagentToolbarRow` / `SubagentUiEntry`
- **worker 与 expert chip 外观不同**：名字前加不同图标前缀（走 `terminalSymbol()` 富文本/ASCII 双路）：
  - expert → **✦**（四芒星，与btw/system-hint 的顾问星系一脉相承）ASCII 回退 `*`
  - worker → **✎**（铅笔，动手改代码）ASCII 回退 `>`
- agents box 行（`agentBubble` meta 通路已就绪）显示派发/请教/报告，行首复用同一图标
- **vibe 模式 agents box 行为与旧版完全一致**（保留件已实现，零新逻辑）：
  - subagent 工具调用（send/hire/check/cancel）旁路出 tools box，折叠进 agents box
  - 汇报信封行折叠进当前段落，不发起新用户回合
  - 6 行上限 + 溢出计数；streaming 期间由 vibe streaming bubble 实时渲染
  - verbose 模式下同样行渲染为 AgentBubble（既有通路）

## 阶段

- **P1 核心**：两开关（/subagent workers|experts on|off + 配置持久化）+ 5 工具静态注册 + 首消息公告 + worker 模式越权拦截 + `SubagentRunner`（复用 ChatTurnExecutor 轮次循环）+ 轮次上限/输出截断
- **P2 UI**：subagent bar + 双 toggle + in-flight chips（含图标区分）
- **P3 打磨**：星座命名、tooltip 数据、报告格式（含改动文件清单）、三段式知识蒸馏（subagent + 主 agent 共用）

## 开放问题

（无——报告颗粒度已定：由主 agent 派活时在 message 里指定，worker 提示词给默认值）

## 模式切换与 cache（零失效方案）

原则：**tool 列表与 system prompt 永不因模式切换改动**（两者任一变动都 invalidate 整个会话前缀缓存）。

1. **工具静态注册**：5 个 subagent 工具常驻 tool 面；模式 off 时调用返回"subagent 模式未开启"重定向提示
2. **模式公告**：开关切换后**第一条用户消息**附加一段 crux 系统提示——on："已进入 worker/expert subagent 模式，动手的活派给 worker、拿不准请教 expert…"；off："已退出 subagent 模式，可正常使用工具"。一次性，随消息走，不碰 system prompt
3. **运行时拦截**：worker 模式下主 agent 调 edit/bash 等动手工具 → 工具结果直接返回"worker 模式下不允许亲自调用，请 send_agent 派给 worker"（复用 plan mode 守卫的拦截模式，行为约束永远反映当前实时状态）

## 已决（原开放问题）

- **新建 agent 的模型**：按角色配置池 + 并行上限选型（见"模型分配"）。

## 开发 Milestones

### M0 — 分支收尾（main 换基线到 feature/subagent-v2）✅

- [x] v2 worktree commit 已暂存的 UI 外壳（17 文件：chips/tooltip/agents box/展示模型/星座/i18n）→ `c1b7eb33`
- [x] squash 评估：14 个 cherrypick 保留独立历史（通用功能各有独立回滚价值，squash 掉反而丢信息）
- [x] main 重置到 v2（旧 subagent 的 22 个 commit 移出历史，通用功能 13 个全保留）
- [x] 验证：dart analyze 零 issue + 全量测试 3021 过 0 失败 + UI 外壳专项 11 个通过

### M1 — 基础设施（跑通最小闭环）✅

- [x] `agents` 档案表 + drift 迁移 v33（name/role/domain/model/status/knowledge/worklog/lastIntention/runOwnerSessionId）+ `AgentStore`（hire/markBusy/markReady/writeDistilled/resetAllToReady）
- [x] 星座命名分池：黄道 12 宫（expert，大众化中文译名）+ 75 星座（worker，去 crux 去黄道），池耗尽 `-2` 数字后缀
- [x] `agent://` scheme 解析（`agent_refs.dart`）+ UI 可点击渲染（`highlighted_markdown_text` 接线：解析/样式/hover/tap）
- [x] `/subagent workers|experts on|off` 命令 + 配置持久化（`[subagent]` 节，v1 `advisor` 键别名兼容）+ `SubagentController`（ChangeNotifier）
- [x] subagent bar（toolbar 上方）+ 双 toggle UI（`SubagentBar`，**始终挂载**——per-session 开关持久化在 sessions 表、覆盖全局默认，both-off 时隐藏会让当前 session 的模式不可见；常显保证状态可见、切换一键可达）

### M2 — Runner 与工具 ✅

- [x] `SubagentRunner`：复用 LlmClient 流式 + ToolExecutor 工具执行的独立轮次循环，**后台执行**（主 agent 永不阻塞），进程内生命周期管理（`subagent_runner.dart`）
- [x] `remainingBudget(model)` 统一额度接口：CodingPlan（5h/周窗口百分比）+ CreditBalance（可用性）归一为 ample/tight/exhausted；缺数据不阻塞（`subagent_manager.dart`）
- [x] 模型分配：池序 + 并发 + 额度检查；hire 绑定死、fork 优先继承源模型（满载/耗尽才 fallback）
- [x] 5 工具实现（`subagent_tools.dart`）：find（fuzzy 六级 + ✎/✦ 角色 glyph）/ hire / send（queue+fork）/ check（busy 快照 / ready 零调用档案摘要）/ cancel——send/hire **即时返回**，run 后台执行；模式 off 时五工具统一重定向提示（零 cache 失效）
- [x] 报告送回：系统信封事件（`[Crux system note — subagent report]` 模板，from/intention/status/report/next 五段），经 sendTurn 注入主会话唤醒主 agent；wire 层空 user 行闸门双保险
- [x] 轮次上限（默认 40 轮；`[subagent] max_rounds` 可配置 32–100 或 `"unlimited"`（无限），配置 fullpane 提供拖拽条调节，超限报告并提示 re-dispatch）+ agentBubble meta 全程打点（spawn/send/read/cancel）

### M3 — 模式行为 ✅

- [x] 三份提示词接入：worker / expert 系统提示词（`subagent_prompts.dart`，含与主 agent 共享的工程规则骨架段——代码探索/权威来源/no-godfiles/紧凑 shell）；模式公告 `subagentModeAnnouncement`（on 按开关组合强调、off 对称退出，五要点工作流指南）
- [x] 首消息公告机制：`SubagentController.consumePendingAnnouncement` 一次性消费 + orchestrator `sendTurn` 的 `subagentAnnouncementProvider` 注入（骑用户消息，不碰 system prompt，零 cache 失效；每次 flip 重新武装）
- [x] worker 模式越权拦截：`ToolExecutor.subagentWorkersGuard` 运行时闸门——workers on 时主 agent 调 edit/write/bash/powershell/cmd/git_prepare_commit 返回重定向提示（复用 plan mode 守卫模式，反映实时开关状态）；subagent runner 用独立无守卫 executor（worker 干活不受限）

### M4 — UI 数据接线 ✅

- [x] in-flight chips：SubagentBar 内直接渲染 manager 的 live runs（✎/✦ 图标前缀 + 本地化星座名 + Hinted 六行 tooltip：domain/intention/model/status）；onRunsChanged → _refresh 驱动 chips 出现/消失
- [x] agents box 行：vibe walker 的 subagent 工具名集合更新为 v2 五件（find/hire/send/check/cancel），保留 v1 六名兼容历史回放；agentBubble meta 通路（M2 打点）走保留件渲染——旁路 tools box、折叠入段、verbose AgentBubble 均零新逻辑
- [x] `agent://` 本地化显示名：`applyAgentLinkStyles` 的 displayNames 参数（持久 id → locale 星座名，hover 单遍处理防 offset 错位）经 ChatHistory → MessageBubble → HighlightedMarkdownText 全链接线；chips 与 AgentBubble 走 WorkerNameLocalizer（既有）

### M5 — 蒸馏（subagent + 主 agent 共用）✅

- [x] 三段式闸门 `stageFor`（`subagent_distiller.dart`）：第 1、2 次满 → 轻量 compact（工具结果>200 字符折叠为占位行，零 LLM 调用）；第 3 次满 → 蒸馏
- [x] 蒸馏引擎 `SubagentDistiller`：三产物（knowledge/worklog/instruction）请求构造 + 容错解析（缺段判无效）；**纯函数模块，subagent runner 与主 agent 共用**（plan 要求的独立入口）
- [x] subagent 侧：runner 轮次循环每轮检查上下文压力（history 估算 > 容量 75%）→ 按段分流；蒸馏产物经 `onDistilled` 写档案（knowledge/worklog 字段），instruction 立即作为 CONTINUATION 续跑同一 assignment（无缝续命，不等下次派活）
- [x] 主 agent 侧：`SessionRuntimeState.compactionsThisSession` 计数；orchestrator 自动 compact 分支接同一 `stageFor` 闸门——第 3 次走 `AuxiliaryService.distillSession`（辅助模型跑蒸馏请求，共用解析器），CONTINUATION 块骑在续跑轮次的消息上（零 cache 失效）；蒸馏失败回退普通 compact
