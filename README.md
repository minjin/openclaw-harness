# Conductor — OpenClaw 多 Agent 编排 Skill

你在聊天里跟 OpenClaw 说需求，它先问清楚、写成任务简报，**等你确认后**再按固定流水线把活派给本机的 **Gemini CLI**（研究）、**Claude Code**（实现）和 **Codex**（审查）。任务在后台执行，完成、受阻或失败时会主动通知你。所有 agent 共用同一个**外脑**：知识库、经验记忆和一份统一的规则文件。

```
你（Telegram / 任意 OpenClaw 渠道）
  │  「研究一下 X，然后在 ~/code/app 里实现」
  ▼
OpenClaw（任意模型）＋ conductor skill
  │  ① 追问，把简报补全     ← 由代码判断信息是否足够
  │  ② 给你看简报，你确认   ← 未经确认的任务，代码拒绝执行
  ▼
conductor.py（确定性流水线，后台运行）
  ├─ 研究：Gemini CLI 联网研究（可选 Gemini Deep Research API）→ report.md
  ├─ 实现：Claude Code，在隔离的 git worktree 分支里 → build.md
  ├─ 审查：Codex，只读沙箱 → review.md
  └─ 汇总 → result.md；提炼经验 → 待审区
  │
  ▼
完成、受阻或失败 → 通知推回聊天；受阻时你回答后自动续跑
```

## 为什么这样设计

- **与模型无关。** 编排用的模型再弱也没关系：「简报补全了没有」「用户确认了没有」「这一步算不算完成」都由 `conductor.py` 判断，不依赖模型自觉。
- **不看退出码，只认产物。** 产物为空或过短、要求改代码的步骤没有产生改动，都判为失败。
- **多个 agent 读，只有一个入口写。** 所有 agent 对外脑只读；新知识和经验先进待审区，你点头后才入库。
- **网页内容是数据，不是指令。** 研究报告和导入的资料里出现的任何指令都不会被执行，也不会自动写进记忆。

## 安装

**最简单的方式：把 [`INSTALL.md`](INSTALL.md) 整个发给你的 OpenClaw，然后说「按这个文件帮我安装」。**

它会一步步引导你：

1. 选择要启用的 agent；
2. 安装缺少的 CLI；
3. 在你自己的终端里登录 Claude Code、Codex、Gemini；
4. 初始化外脑、统一规则；
5. 可选：配置 Deep Research；
6. 跑一次冒烟测试。

**手动安装：**

```bash
openclaw skills install git:OWNER/openclaw-conductor --global
python3 ~/.openclaw/skills/conductor/scripts/conductor.py setup --notify-channel telegram --notify-target <chat_id>
python3 ~/.openclaw/skills/conductor/scripts/conductor.py doctor --deep
```

**依赖：**

- 必需：OpenClaw、Python ≥ 3.9、git。
- 按需：Claude Code、Codex CLI、Gemini CLI，至少装一个；研究类流水线需要 Gemini CLI。
- 可选：ripgrep、qmd、Gemini 付费 API key（Deep Research 用）。

## 流水线

| 流水线 | 执行步骤 |
|---|---|
| `research_only` | Gemini 研究 → Claude 提炼交付摘要 |
| `research_then_build` | Gemini 研究 → Claude 实现 → Codex 审查 → 汇总 |
| `build_review` | Claude 实现 → Codex 审查 → 汇总 |
| `second_opinion` | Claude 和 Gemini 分别独立作答 → 对比出综合结论 |
| `ingest` | 把外部资料整理成带出处的知识笔记 → 你审核 → 入库外脑 |

流水线定义在 [`pipelines.json`](pipelines.json) 里，包括必填项、追问话术和每一步的指令，可以直接修改或新增。

**研究引擎：**

- 默认用 **Gemini CLI** 联网研究，不需要额外的 key。
- **Gemini Deep Research API** 是可选项：更深入，但每次耗时 5–60 分钟、约 $2–5，且需要付费 key。可以只对某个任务用（设置 `research_engine=deep_research`），也可以在 `~/conductor/config.json` 里设为默认。

## 外脑（共享记忆与知识）

```
~/conductor/
  AGENTS.md          唯一规则源：Claude 用 @import 实时读取，Codex / Gemini 读托管副本
  brain/
    index.md         总索引
    knowledge/       已审核的知识笔记（按主题分目录）
    research/        已入库的研究报告
    memory/lessons.md  经验记忆（每个任务提炼一次，你确认后追加）
    inbox/           待审区（raw/ 放待导入的文件，lessons/ 放待审的经验）
  jobs/<id>/         每个任务的简报、产物、日志
```

- 导入外部知识的方法见 [`references/knowledge-import.md`](references/knowledge-import.md)：往收件箱放文件、直接给 URL、挂载已有笔记库、用 qmd 做语义检索、用 Obsidian 打开外脑。
- OpenClaw 的 `memory_search` 通过 `memory.search.extraPaths` 覆盖外脑目录。

## 命令速查

```bash
C="python3 ~/.openclaw/skills/conductor/scripts/conductor.py"
$C doctor [--deep]          # 检查安装、登录状态和规则接线
$C new --pipeline P --set k=v ...  → $C set / render / confirm / run
$C status <job> | list | result <job> [--file report.md] | cancel <job>
$C answer <job> "..." && $C run <job> --resume      # 回答受阻任务的问题后继续执行
$C promote <job> --lessons | --report | --knowledge  # 你确认后才写入外脑
$C sync-rules | unwire      # 同步共享规则 / 卸载规则接线（setup --no-wire / --wire 控制是否写 CLI 全局规则文件）
```

## 安全说明

- 执行 agent 用你本机 CLI 的登录身份运行：
  - Claude 只能在任务工作目录里写文件；shell 命令只放行 `config.json` 中 `claude_build_tools` 列出的那些，默认只有 git 和 ls。
  - Codex 审查时在只读沙箱里运行。
- 代码只提交到 `conductor/<job>` 分支，**永远不会自动 merge 或 push**。
- 密钥只放在 `~/conductor/.env`（权限 600），不会经过聊天。
- 改动 `~/.claude/CLAUDE.md`、`~/.codex/AGENTS.md`、`~/.gemini/GEMINI.md` 时只追加带标记的区块，首次修改前自动备份为 `*.bak-conductor`；`unwire` 可一键移除。

## 开发

```bash
python3 tests/test_deep_research.py   # Deep Research 路径（HTTP 层用桩替代）
bash tests/e2e.sh                     # 用假 CLI 跑全部流水线（使用临时 HOME，不会碰你的真实配置）
python3 tools/build_install.py        # 修改任何 skill 文件后，重新生成 INSTALL.md
```

发布前设置 `CONDUCTOR_REPO=<你的用户名>/openclaw-conductor` 再运行 `build_install.py`，INSTALL.md 里的仓库地址就会指向你的仓库。

## License

MIT
