# 开发思路

> 本文记录 Conductor 为什么长成现在这样：调研了什么，排除了哪些方案，真机测试暴露了什么问题，以及后续怎么扩展。
> 需求见 [REQUIREMENTS.md](REQUIREMENTS.md)，实现见 [DESIGN.md](DESIGN.md)。

## 1. 出发点

最初的设想是：用一个便宜的本地模型（比如本地 Qwen），通过 Hermes 或 OpenClaw 跟用户对话；由它拆解任务，再派给本机已经装好的 Claude Code、Codex、Gemini；比如先让 Gemini 做深度研究，再把结果交给 Claude 或 Codex 完成后续工作。

讨论中很快明确了一个关键判断：**小模型不适合做开放式的任务拆解和流程控制。** 它擅长在有限选项里做选择、按格式填字段；但很不擅长判断「信息够不够了」「这一步算不算做完」，也不擅长多轮连续地正确调用工具。因此设计成：

> **小模型决定「派给谁、填什么」，代码决定「能不能走下一步」，强模型决定「具体怎么做」。**

这句话是整个项目的地基。后面每一个取舍，都是在守住它。

## 2. 调研结论（2026-09）

动手之前，先调研了现有的开源方案，目的是不重复造轮子。结论是：**没有哪个现成项目能同时满足「顺序流水线 + 模型无关的前台 + 聊天回传 + 共享记忆」。**

| 类别 | 代表项目 | 结论 |
|---|---|---|
| 个人 agent 网关 | **OpenClaw**、Hermes Agent | OpenClaw 有 `ask_user` 结构化追问、原生多渠道、skill 体系、记忆检索，还能挂外部目录，适合当前台。当时 Hermes 没有通用的 ACP client，派发只能靠在终端里敲命令，小模型用起来不稳，因此选 OpenClaw |
| 多 CLI 编排器 | AionUi、cc-connect、comanda、mco、acpx、PAL MCP(clink)、Claude-Code-Workflow | 有的偏并行自由分派，有的偏 IM 桥接，有的只是单个 CLI 内部的编排，都没有「澄清 → 确认 → 固定流水线 → 回报」这一整条链 |
| 规格驱动工具 | GitHub Spec Kit、OpenSpec、BMAD、Task Master | Spec Kit 的 `/clarify`（标记不确定项、集中追问）直接影响了本项目的追问设计。但这些工具都不负责把任务派给不同的 CLI |
| 编排框架 | LangGraph、CrewAI、Google ADK、Temporal、n8n | 能力都够，但对一个 OpenClaw skill 来说太重：引入运行时依赖，也偏离了「一个文件就能安装」的目标 |
| Deep Research | Gemini Interactions API、gpt-researcher、open_deep_research | Gemini Deep Research 只能通过 API 调用（预览版，需要付费 key），Gemini CLI 没有这个能力；社区封装多数没跟上 2026-05 的接口变更 ⇒ 自己写几十行 REST 调用 |

最终决定：**做一个 OpenClaw skill，外加一个零依赖的 Python 运行器。** OpenClaw 已经解决的问题（多渠道、会话、结构化追问、记忆检索、定时任务）一律复用；它没解决的问题（确定性流水线、产物校验、共享外脑的写入纪律）放进运行器。

## 3. 关键决策与被否决的方案

### 3.1 不用 Lobster，不用 acpx

OpenClaw 生态里有 Lobster（类型化的确定性流水线，带审批门）和 acpx（通过 ACP 协议统一驱动各个 CLI）。看起来正合适，最终都没用：

- **Lobster**：通过 OpenClaw 工具调用时，默认超时 20 秒。而研究步骤要跑 5 到 60 分钟，只能另起一个后台进程，那 Lobster 就只剩一层外壳。另外，它内嵌运行时对 LLM 步骤和 `input:` 恢复的支持也不确定。
- **acpx**：能统一调用方式，但要多一层适配器（首次使用时用 npx 下载），权限模式也多一层要配。三个 CLI 的无头参数都已经核实过，而且足够用，直接调用最简单、最透明。
- **代价**：需要为每个 CLI 写一个小适配函数（见 DESIGN.md §6）。换来的是零依赖、行为可预测、出错时一眼能看懂。

### 3.2 闸门放在代码里，而不是提示词里

「必须先确认才能执行」如果只写在 SKILL.md 里，弱模型迟早会跳过。所以：

- 未确认的任务，`run` 直接拒绝；
- 必填项没填满，`confirm` 直接拒绝；
- 产物不合格，步骤判为失败。

SKILL.md 只负责告诉模型「应该怎么做」；做不做得到，由运行器兜底。

### 3.3 不看退出码，只认产物

这一条来自反复出现的教训：CLI 认证失败、额度用尽、权限被拒时，退出码经常仍然是 0，输出却是空的或者是一段报错文字。所以每一步都以产物为准：

- 拿不到结构化结果，判失败；
- 结果过短，判失败；
- 要求改代码却没有改动，判失败；
- 要求生成笔记却一篇没有，判失败。

### 3.4 Deep Research 是可选项

最初设计默认使用 Gemini Deep Research API。用户指出它应该是可选项：它更贵（每次约 $2–5）、更慢（5 到 60 分钟），还需要付费 key。调整后：

- **默认用 Gemini CLI 联网研究**，使用用户已有的 Gemini 登录，不需要额外的 key；
- **Deep Research 可以按任务选择**（槽位 `research_engine`），也可以设成默认；
- **选了 Deep Research 却没有 key 时，明确报错**，不静默降级。静默降级会让用户以为自己用的是 Deep Research。

### 3.5 外脑：单写者 + 审核后入库

「让所有 agent 共享记忆」最容易做成一个人人都能写的公共区，结果会是重复、矛盾，还会被注入污染。这里的做法是：

- 执行 agent 对外脑**只读**；
- 产出先进待审区，用户点头之后由 `promote` 这一个入口写入；
- 研究报告和网页内容标记为 `trust: external`，其中的指令一律不执行。

规则层同样只有一个源头：`AGENTS.md`。Claude 通过实时导入读取，Codex 和 Gemini 读托管副本，每一步的提示词里也内联一份（原因见 §5）。

### 3.6 一个文件完成安装，而且安装者是 agent

目标用户手上已经有一个能执行命令的 OpenClaw agent，那么最自然的安装方式就是「把说明书交给它」。难点有两个：

- **说明书必须自包含**：skill 文件逐字内嵌在 INSTALL.md 里，由构建脚本生成，并在 CI 中逐字校验；
- **说明书必须经得起 agent 的自由发挥**：写明原则（先说后做、密钥不进聊天、以验证输出为准、版本不符时先查 `--help`、发现缺陷时报告而不是改代码）。

登录必须由用户在自己的终端里完成（OAuth 需要浏览器）。agent 只负责给出命令，并在用户完成后做验证。

## 4. 开发过程

1. **调研**：并行调研 Hermes/OpenClaw 的能力、多 CLI 编排器、Gemini Deep Research 的接入方式、「先澄清再派发」类框架。
2. **核实语法**：OpenClaw（skill frontmatter、配置、`ask_user`、`message send`、记忆的 extraPaths）和三个 CLI 的无头参数，都对照官方源码或文档核实过；拿不准的地方在文档里标注清楚。
3. **运行器**：先写状态机和闸门，再写各 CLI 的适配器，最后写外脑维护和自检命令。
4. **假 CLI 端到端测试**：用临时 HOME 加上假的 CLI 跑遍 5 条流水线，覆盖受阻续跑、条件跳过、空产物判失败等路径。Deep Research 单独用桩测试。
5. **安装文档生成**：模板 + 构建脚本 + 往返测试，保证 INSTALL.md 与源码不会漂移。
6. **真机测试**（见 §5），修复发现的问题，每个问题都补上回归测试。
7. **发布**：在 CI 上跑 Ubuntu（Python 3.9 最低版本）和 macOS。

## 5. 真机测试的收获

测试环境：一台 Linux 主机，上面已经运行着另一套 agent 系统。使用独立的 OpenClaw profile 和独立目录，并用 `--no-wire` 避免干扰主机原有配置。编排模型是 Claude（通过 OpenClaw 的 anthropic-cli provider），在 TUI 里对 OpenClaw 说「按 INSTALL.md 帮我安装」。

**顺利的部分**

- OpenClaw agent 自己完成了环境检查，识别出三个 CLI 已安装并登录，跳过了安装和登录阶段。
- 它用 `ask_user` 访谈安装选项；识别出主机上已有其它 agent 系统后，主动推荐 `--no-wire`。
- 它写出的 skill 文件，与仓库版本的 md5 完全一致。
- 冒烟任务 `build_review` 用真实的 Claude 和 Codex 跑通：Claude 在隔离分支实现并提交，Codex 在只读沙箱中审查，还独立执行了验收命令。

**暴露的问题**（均已修复，并补了回归测试）

| # | 问题 | 怎么发现的 | 修法 |
|---|---|---|---|
| 1 | `--no-wire` 只在 setup 那一次调用里有效；之后 `sync-rules` 和每个任务都会写全局规则文件 | 安装 agent 发现后立即撤销，并报告 | 持久化 `wire_rules` 开关；所有写规则的路径都检查它；`unwire` 同时关闭开关 |
| 2 | Claude 步骤读不到共享规则（规则文件不在授权目录内） | **流水线自己的「经验提炼」步骤指出来的** | 规则内联进每一步的提示词；外脑、规则、任务目录用 `Read(//…)` 规则授权只读 |
| 3 | 原本用 `--add-dir` 授权外脑，在 `acceptEdits` 模式下外脑变得**可写** | 修 #2 时的推论，并经过实验证实 | 改用只读规则，调用参数契约写进测试 |
| 4 | 只读步骤的 `git log`、`git status` 被拒 | 经验提炼步骤 + 真机实验 | 默认放行只读 git 命令，包括 `git -C <path>` 形式；不放行 `push` |
| 5 | 提交使用了 git 的默认身份 | 经验提炼步骤 | 通过环境变量补一个 Conductor 身份，不写 git 配置 |
| 6 | 修改 `memory.search` 让 gateway 重启，把安装对话本身打断 | gateway 日志 | 挪到安装的最后一个阶段，并提前告知用户 |
| 7 | `doctor` 在 `--no-wire` 下永远报红，而修复提示会诱导用户撤销自己的选择 | 安装 agent 报告 | 未接线时跳过规则检查；`--deep` 改走内联规则路径 |
| 8 | 通知未配置时静默跳过，日志里没有任何记录 | 安装 agent 报告 | 每次通知的结果都写进日志 |
| 9 | TUI 和 webchat 收不到 `message send` 的推送 | 安装 agent 报告 | 安装访谈中说明，并推荐「暂不通知」 |
| 10 | Gemini 免费额度用尽（429），冒烟测试没法跑 | doctor --deep | 安装文档增加降级方案：改用 build_review 做冒烟测试 |

**两点体会：**

- **让流水线自己「复盘」非常值钱。** 问题 #2、#4、#5 都是 `lessons` 步骤在第一次真实运行时指出来的；换成人工排查，很可能漏掉。
- **把安装交给 agent 是可行的，但要预期它会自由发挥。** 这次它甚至自己动手给已安装的代码打了补丁，补丁是对的。但这会让安装结果变得不可复现，所以安装文档改为要求它「先止损，再报告，不改代码」。

## 6. 已知限制

- Gemini 研究步骤和 `second_opinion` 流水线还没有在真机上用真实的 Gemini 跑通（测试当天额度用尽）；Deep Research 目前只有桩测试。
- 通知依赖 OpenClaw 的外部渠道；TUI 和 Web 控制台收不到推送。
- 无头模式下的权限是静态的：构建步骤要跑测试命令，需要用户事先加进 `claude_build_tools`。
- `ask_user` 只在 OpenClaw 的主会话中可用。
- 单机、单用户；同一台机器上的多个 OpenClaw profile 会共用各 CLI 的登录状态。

## 7. 路线图

| 优先级 | 事项 |
|---|---|
| 高 | 用真实的 Gemini 补跑研究类流水线和 `second_opinion`；用付费 key 实测一次 Deep Research |
| 高 | 用本地小模型（比如 Qwen3 MoE 经 Ollama）作为编排模型，完整走一遍澄清和确认流程，验证「模型无关」 |
| 中 | 研究步骤支持更多引擎（例如 OpenAI Deep Research、自托管的 gpt-researcher） |
| 中 | 构建步骤可选 Codex 实现、Claude 审查（反向组合） |
| 中 | 按项目探测测试命令（package.json、pyproject 等），在简报中建议加入 `claude_build_tools`，由用户确认后生效 |
| 低 | 外脑检索升级：内置 BM25 索引（现在依赖 rg 或可选的 qmd） |
| 低 | 并发任务的资源上限与排队 |

## 8. 怎么扩展

**新增一条流水线**：只改 `pipelines.json`。

1. 如果需要新的槽位，在 `slots` 里加上（`header`、`question`，可选 `options` 和 `default`）；
2. 在 `pipelines` 下加一项：`description`、`required`、`optional`、`steps`，要改代码的再加 `workdir: true`；
3. 每一步选一个 `agent`，写好 `task` 模板，按需设置 `write`、`in_workdir`、`inputs`、`when`、`expect_*`；
4. 在 SKILL.md 的流水线表格里加一行，告诉前台什么时候用它；
5. 在 `tests/e2e.sh` 里加一段覆盖，然后运行 `python3 tools/build_install.py` 重新生成 INSTALL.md。

**新增一个执行 agent**：在 `conductor.py` 里写一个 `run_<agent>()` 适配函数，要求：

- 调用无头模式；
- 输出写进日志；
- 解析出最终文本；
- 拿不到结果就抛 `StepError`；
- 按 `write` 选择权限模式。

然后在 `run_step()` 里分派，在 `AGENT_LABELS` 里加上显示名，并给假 CLI 加一个对应的实现。

**提交前的检查清单**：

```bash
python3 tests/test_deep_research.py
bash tests/e2e.sh
python3 tools/build_install.py && python3 tests/test_install_roundtrip.py
```
