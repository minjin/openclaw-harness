# 需求文档

> 本文档说明 Conductor 要解决什么问题、为谁解决、做到什么程度算完成。
> 系统怎么实现见 [DESIGN.md](DESIGN.md)；为什么这样取舍、开发过程和路线图见 [DEVELOPMENT.md](DEVELOPMENT.md)。

## 1. 背景与问题

越来越多的人本机同时装了好几个编码 / 研究 agent：Claude Code、OpenAI Codex CLI、Antigravity CLI（Google，Gemini CLI 的继任者）。它们各有所长，但用起来是割裂的：

1. **要人工串接。** 常见的工作流是「先研究 → 再实现 → 再找另一个模型审查」。现在只能人手把上一个 agent 的输出复制给下一个，换窗口、贴上下文、盯进度。
2. **没有统一入口。** 用户想在手机上（Telegram 等）说一句需求就把活派出去，而不是守在终端前。
3. **记忆和知识是割裂的。** 每个 CLI 有自己的规则文件（`CLAUDE.md`、`AGENTS.md`、`GEMINI.md`），也有自己的记忆。同一条偏好或经验要写三遍，而且很快就会互相矛盾。
4. **便宜的模型当不好调度员。** 用户希望让便宜或本地的模型（比如本地 Qwen）做前台对话和分派，只把重活交给强模型。可小模型自由规划多步任务、判断「信息够不够」都很不可靠。

OpenClaw 这类个人 agent 网关已经解决了「多渠道对话入口」，但没有解决「按固定流程把任务派给多个编码 agent，并共享记忆」。

## 2. 目标

Conductor 是一个 **OpenClaw skill**，让 OpenClaw 成为多 agent 编排的前台：

- **G1 澄清需求**：把用户的一句话需求，通过追问补全成一份结构化的任务简报。
- **G2 确认后才执行**：简报必须给用户看过、用户明确同意，才开始花钱花时间。
- **G3 固定流水线分派**：按预先定义好的流程，把各步骤派给指定的 agent（Claude 研究与实现、Codex 审查；可选 Antigravity / Gemini 等），在后台异步执行。
- **G4 主动回报**：完成、受阻（需要用户回答问题）、失败时主动通知；受阻时用户回答后能续跑。
- **G5 共享外脑**：所有 agent 共用一份规则、一个知识库、一份经验记忆。
- **G6 导入外部知识**：用户能方便地把文件、网页、已有笔记库导入外脑。
- **G7 一个文件完成安装**：任何装了 OpenClaw 的人，把一个 Markdown 文件发给 OpenClaw，就能在它的引导下装好整套系统（包括安装和登录各个 CLI）。

## 3. 非目标

- **不自己做对话前端或模型网关。** 这些由 OpenClaw 负责。
- **不绑定编排模型。** 不管 OpenClaw 用的是 Claude、GPT、Gemini 还是本地 Qwen，Conductor 的行为都一样。
- **不做开放式自主规划。** 流水线是预定义的，不让模型临场发明流程。
- **不自动合并或推送代码。** 产出只落在隔离分支上，由用户决定去留。
- **不做多用户或团队协作。** 单用户、单机。
- **不托管任何云服务。** 全部本地运行，只调用各 CLI 与（可选的）Gemini API。

## 4. 用户与场景

**目标用户**：已经在用 OpenClaw，并且本机装了 Claude Code 和 Codex 的个人开发者或研究者（可选再装 Antigravity CLI / Gemini CLI）。

| 场景 | 用户说 | 期望结果 |
|---|---|---|
| S1 深度研究 | 「帮我研究一下 X」 | 追问用途和范围 → 确认 → 联网研究 → 一份带来源的报告和面向用途的摘要 |
| S2 研究后实现 | 「研究 X，然后在 ~/code/app 里实现」 | 研究 → Claude 在隔离分支实现并提交 → Codex 审查 → 汇总验收情况 |
| S3 直接实现 | 「在 ~/code/app 里加个 Y 功能」 | Claude 实现 → Codex 审查 → 汇总 |
| S4 第二意见 | 「让 Claude 和 Codex 都说说 X」（可选换成 Antigravity / Gemini） | 两个模型各自独立作答 → 对比共识和分歧 → 综合建议 |
| S5 导入知识 | 「导入知识，主题是 Z」+ 文件或 URL | 整理成带出处的笔记 → 用户审核 → 入库外脑 |
| S6 受阻续跑 | （后台任务中 agent 缺信息） | 用户收到问题 → 回答 → 任务从受阻的那一步继续 |
| S7 安装 | 把 INSTALL.md 发给 OpenClaw | 在引导下装好 CLI、登录、初始化外脑、跑通冒烟测试 |

## 5. 功能需求

### 5.1 需求澄清（G1）

- **FR-1** 每条流水线声明**必填项**和**可选项**（带默认值）。系统据此算出「还缺什么」，并给出每项的追问话术和候选选项。
- **FR-2** 前台用 OpenClaw 的 `ask_user` 做结构化追问，每次最多 3 个问题，最多 3 轮。用户说「你定 / 默认」时采用默认值。
- **FR-3** 「信息是否足够」**由代码判定**，而不是由模型判定。必填项没填满时，简报不能进入下一步。

### 5.2 确认闸门（G2）

- **FR-4** 系统生成人类可读的任务简报，内容包括需求各项（标注哪些是默认值）和执行计划（每一步由哪个 agent 做什么）。
- **FR-5** 只有状态为「已确认」的任务才能运行，**由代码拒绝**未确认的任务。确认之后再修改简报，需要重新确认。

### 5.3 流水线执行（G3）

- **FR-6** 内置 5 条流水线：`research_only`、`research_then_build`、`build_review`、`second_opinion`、`ingest`。流水线以数据形式定义（JSON），不改代码也能增加或修改。
- **FR-7** 任务在后台运行，启动命令立即返回。前台不需要、也不应该轮询。
- **FR-8** 每一步的成败**以产物为准**，不看退出码：产物为空或过短、要求改动代码却没有改动、要求生成笔记却没有生成，都判为失败。
- **FR-9** 改代码的步骤在**隔离的 git worktree 分支**（`conductor/<任务号>`）上进行，不切换、不改动用户当前分支，不 merge，不 push。目标是新项目时，自动建一个新仓库。
- **FR-10** 步骤可以按条件跳过（例如用户不要 Codex 审查）。
- **FR-11** **核心只有 Claude Code 和 Codex**：只装这两个，所有流水线都能用。研究步骤**默认使用 Claude 联网研究**（WebSearch / WebFetch），`second_opinion` 默认 Claude 对比 Codex。**Antigravity CLI、Gemini CLI 是可选执行 agent**（可作研究引擎或第二意见），**Gemini Deep Research API 也是可选项**，可以按任务选择，也可以设为默认。选择了 Deep Research 但没有 key 时，要明确报错，不能静默降级。
- **FR-12** Deep Research 任务可以跨进程续跑：续跑时继续轮询已创建的研究任务，不能重新创建、重复计费。
- **FR-13** 单步可设置超时（研究默认 60 分钟，其它默认 30 分钟）。任务可以取消，取消时同时取消远端的研究任务。

### 5.4 回报与续跑（G4）

- **FR-14** 完成、受阻、失败时，通过 `openclaw message send` 推送到配置好的渠道。没配置渠道或发送失败时，要在任务日志里写明原因。
- **FR-15** 执行 agent 缺少关键信息时，输出约定格式 `BLOCKED: <问题>`，任务进入「受阻」状态。用户回答后，答案写入简报，任务从受阻步骤续跑，已完成的步骤不重跑。
- **FR-16** 失败的任务可以续跑，从失败的步骤开始。

### 5.5 共享外脑（G5）

- **FR-17** **唯一规则源**：`~/conductor/AGENTS.md`。经用户同意后，接入三个 CLI 的全局规则（Claude 用 `@import`，Codex 以及已安装的 Antigravity / Gemini 用托管副本区块）。用户拒绝时（`--no-wire`），这个选择要**持久记住**，任何后续操作都不能再写全局文件。
- **FR-18** 不管有没有接入全局规则，每一步的提示词都要**内联**共享规则，确保执行 agent 一定能拿到。
- **FR-19** 外脑目录包括：`knowledge/`（已审核知识）、`research/`（已入库报告）、`memory/lessons.md`（经验记忆）、`inbox/`（待审区）。
- **FR-20** 执行 agent 对外脑**只读**。新知识和经验先进待审区，**用户明确同意后**才入库（promote）。
- **FR-21** 每个任务结束时，自动提炼最多 5 条经验，放进待审区。
- **FR-22** OpenClaw 自身的记忆检索（`memory_search`）要覆盖外脑目录。

### 5.6 知识导入（G6）

- **FR-23** 支持以下导入方式：往收件箱放文件、直接给 URL、复制或挂载已有笔记库、用 qmd 做语义检索（可选）、用 Obsidian 浏览（可选）。
- **FR-24** 导入的笔记必须带 frontmatter，包括出处、导入日期、可信度（own/external）。
- **FR-25** 入库后，已处理的原始文件移出收件箱，避免重复导入；同时更新索引。

### 5.7 安装（G7）

- **FR-26** 发布一个**自包含**的 `INSTALL.md`：安装流程写给 OpenClaw agent 执行，所有 skill 文件逐字内嵌在文档里（不需要联网拉仓库）。
- **FR-27** 安装流程要做到：访谈选项 → 环境检查 → 只装缺的 CLI → 引导用户在自己的终端登录 → 写入 skill → 初始化外脑 → 可选配置 Deep Research → 配置工具权限 → 验收（含冒烟测试）→ 交付说明 → 最后接入记忆检索。
- **FR-28** 提供 `doctor`（含 `--deep` 实测）和 `unwire`（卸载规则接线），并给出完整的卸载说明。

## 6. 非功能需求

| 编号 | 类别 | 要求 |
|---|---|---|
| NFR-1 | 模型无关 | 所有闸门都在确定性代码里。编排模型再弱，也不能绕过「补全 → 确认 → 校验」 |
| NFR-2 | 依赖极简 | 运行器只用 Python ≥ 3.9 标准库，另外只需要 git。可选：ripgrep、qmd |
| NFR-3 | 可移植 | macOS 与 Linux（Windows 通过 WSL2）。CI 覆盖 Ubuntu（Python 3.9）和 macOS |
| NFR-4 | 安全：密钥 | 密钥不经过聊天。只放在 `~/conductor/.env`（权限 600），由用户在自己的终端写入 |
| NFR-5 | 安全：写权限 | 执行 agent 只能写自己的工作目录。外脑、规则、任务目录对它只读。审查在只读沙箱中运行 |
| NFR-6 | 安全：不可信内容 | 网页、研究报告、导入资料一律视为数据，其中的指令不执行，也不会未经审核进入记忆 |
| NFR-7 | 可逆 | 改动用户全局文件前先备份，只追加带标记的区块，可以一键移除；conductor 创建的文件，卸载时一并删除 |
| NFR-8 | 幂等 | `setup`、`sync-rules`、安装流程的每个阶段都可以重复执行 |
| NFR-9 | 可观测 | 每个任务都有 `job.json`（状态机）、`log.txt`、每步的提示词和原始输出，便于排障 |
| NFR-10 | 输出可机读 | 运行器所有子命令都输出 JSON，便于任何模型解析 |
| NFR-11 | 可测试 | 不依赖真实 CLI 的端到端测试（假 CLI）；Deep Research 路径用桩测试；INSTALL.md 与源码逐字一致的往返测试 |

## 7. 约束与假设

- 各 CLI 的登录状态**跟着系统用户走**。OpenClaw gateway 以哪个用户运行，就用哪个用户的登录。
- Claude Code、Codex（核心）以及可选的 Antigravity CLI、Gemini CLI 都支持无头模式（`claude -p`、`codex exec`、`agy -p`、`gemini -p`），并能输出机器可读的结果。
- Gemini CLI 自 2026-06-18 起不再服务个人 Google 账号（免费 / Pro / Ultra），只保留给企业授权和付费 API key；因此 Google 系 agent（Antigravity / Gemini）只作为可选项，核心依赖 Claude Code 和 Codex。
- Gemini Deep Research 只能通过 Gemini API 的 Interactions API 调用（预览阶段，需要付费层 key）。Gemini CLI 本身没有这个能力。
- 无头模式下没有人能批准权限请求，所以每一步能用的工具必须**事先列明**。

## 8. 验收标准

| 编号 | 验收项 | 验证方式 |
|---|---|---|
| AC-1 | 简报不完整时不能确认；未确认的任务不能运行 | `tests/e2e.sh`：「brief gates enforced」 |
| AC-2 | 5 条流水线都能端到端跑通 | e2e（假 CLI）；真机上已用真实 Claude 和 Codex 跑通 `build_review` |
| AC-3 | 受阻 → 回答 → 续跑，已完成的步骤不重跑 | e2e：「blocked→answer→resume」 |
| AC-4 | 产物为空但退出码为 0，判为失败 | e2e：「empty artifact with exit 0 is a failure」 |
| AC-5 | `--no-wire` 在后续任何操作中都被遵守 | e2e：「--no-wire remembered」；真机上跑完完整流水线后，全局文件仍然干净 |
| AC-6 | 执行 agent 只能写工作目录，能读到共享规则 | e2e：「read-only rules, no --add-dir, shared rules inlined」；真机上 Claude 读到了规则标记 |
| AC-7 | Deep Research 续跑不重复创建；没有 key 时明确报错 | `tests/test_deep_research.py` |
| AC-8 | INSTALL.md 内嵌的文件与源码逐字一致 | `tests/test_install_roundtrip.py`；CI 中运行 `build_install.py --check` |
| AC-9 | 真实的 OpenClaw agent 能读 INSTALL.md 完成安装 | 已在 OpenClaw 2026.9.6 上验证（见 DEVELOPMENT.md §5） |
