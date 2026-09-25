# Conductor 安装手册（交给 OpenClaw 执行）

> **给用户**：把这个文件整个发给你的 OpenClaw（聊天里直接粘贴，或者作为附件发送），然后说一句「按这个文件帮我安装」。OpenClaw 会一步步引导你完成安装。
>
> **给 OpenClaw**：下面是写给你的安装流程。请按阶段执行，每个阶段开始前先告诉用户要做什么，结束后用文中给出的**验证命令**确认结果。

Conductor 版本：{{VERSION}}

---

## 0. 执行者须知（OpenClaw 必读）

**Conductor 是什么**：让你（OpenClaw）充当「前台」的一套多 agent 编排系统。

- 你负责跟用户对话，澄清需求，产出任务简报；用户确认后，按固定流水线把活派给本机的 Gemini CLI、Claude Code、Codex 在后台执行，完成后把结果推回聊天。Gemini Deep Research API 是可选的增强项。
- 同时提供一套所有 agent 共用的外脑，放在 `~/conductor/brain`：知识库、经验记忆，以及统一的规则文件 `~/conductor/AGENTS.md`。
- 流程控制全部由脚本 `conductor.py` 强制执行，不依赖你用的是什么模型。

**安装原则：**

1. **先说后做。** 每个阶段先用一两句话告诉用户接下来要做什么、会改动哪些文件，得到同意后再执行。
2. **改用户全局配置之前必须征得同意。** 需要改的是 `~/.claude/CLAUDE.md`、`~/.codex/AGENTS.md`、`~/.gemini/GEMINI.md`。脚本只会追加一个带标记的区块，第一次修改前会自动备份为 `*.bak-conductor`。
3. **不在聊天里收集任何密钥或密码。** 需要密钥时，给用户一条在他自己终端里执行的命令。
4. **不看退出码判断成功。** 以每个阶段的验证命令输出为准。
5. **命令和本机版本对不上时**（报「未知参数」之类的错），先运行 `<命令> --help` 核对用法，调整后再执行，并告诉用户你改了什么。
6. **可以重复执行。** 所有步骤都是幂等的，中断后从出错的阶段重新开始即可。
7. **登录类操作要在用户自己的终端里完成**（需要浏览器或交互）。你只负责给出命令，等用户回复「好了」，再做验证。
8. **发现 Conductor 本身的缺陷时**：先止损（撤销已经产生的副作用），再告诉用户。然后把现象和建议的修法写进 `~/conductor/INSTALL-ISSUES.md`，方便反馈给项目。**不要改写 skill 代码**，否则安装结果就无法复现，以后也没法正常升级。
9. **本机已经有别的 agent 系统时**（比如 root 下已经跑着其他 agent、网关或记忆系统），默认推荐 `--no-wire`，并在修改任何全局配置之前说明它可能带来的影响。

---

## 1. 访谈：确定安装选项

用 `ask_user` 依次问下面几个问题（每次最多 3 个），把答案记下来，后面的阶段会用到：

| id | 问题 | 选项 |
|---|---|---|
| agents | 要启用哪些执行 agent？（多选） | Claude Code (Recommended) / Codex / Gemini CLI |
| notify | 任务完成后把通知发到哪里？ | 当前这个聊天 (Recommended) / 暂不通知 |

> 通知走 `openclaw message send`，**只支持外部渠道**（Telegram、Slack、Discord 等）。如果用户是在 TUI 或 Web 控制台里跟你对话，这些界面收不到推送：请推荐「暂不通知」，并告诉用户任务状态可以随时问你。
| language | 产出默认用什么语言？ | 中文 (Recommended) / English |

补充说明：

- **研究步骤默认由 Gemini CLI 执行**。如果用户没选 Gemini CLI，要告诉他：研究类流水线需要 Gemini CLI，或者后面配置 Deep Research API key。
- **选了「当前这个聊天」时**，从当前会话上下文里确定渠道名和目标 ID（比如 Telegram 的 chat id），然后用 `openclaw message send --channel <渠道> --target <ID> --message test` 发一条测试消息，确认能送达。如果无法确定，请用户提供，或者先跳过，以后再用 `setup --notify-channel ... --notify-target ...` 补上。
- **再用一句话问用户的称呼和常用技术栈**（可以跳过），这些信息会写进共享规则的「用户偏好」小节。

---

## 2. 环境检查

```bash
uname -s; python3 --version; git --version; node --version; npm --version; openclaw --version; rg --version | head -1
```

逐项核对：

- **python3 ≥ 3.9 和 git 必须有。** 缺失时告诉用户对应的安装方式：macOS 用 `xcode-select --install` 或 Homebrew；Linux 用系统包管理器。
- **node ≥ 22 和 npm**：通过 npm 安装 Codex 或 Gemini CLI 时需要。如果缺失，推荐用户用 Homebrew、nvm 或 fnm 安装 Node 22+。
- **ripgrep（rg）可选**，装了以后外脑检索更快：`brew install ripgrep` 或 `apt install ripgrep`。
- **Windows 用户**：建议在 WSL2 里安装整套系统。

---

## 3. 安装执行 agent（只装缺的）

先检查哪些已经装好了：`claude --version; codex --version; gemini --version`

然后只安装阶段 1 里用户选中、并且本机还没有的那些：

```bash
# Claude Code（官方原生安装器；也可以用 brew install --cask claude-code）
curl -fsSL https://claude.ai/install.sh | bash

# Codex（也可以用 brew install --cask codex）
npm install -g @openai/codex

# Gemini CLI（也可以用 brew install gemini-cli）
npm install -g @google/gemini-cli
```

**验证**：对每个选中的 agent 执行 `<cli> --version`，都要能输出版本号。npm 全局安装如果报权限错误，不要用 sudo，建议用户改用 nvm 或 fnm 管理 Node。

---

## 4. 引导登录

登录需要浏览器交互，**必须由用户在自己的终端里完成**。按下表逐个给用户命令，等他回复「好了」后再运行验证命令。

| agent | 让用户在终端执行 | 验证（你来运行） |
|---|---|---|
| Claude Code | `claude auth login`（或者直接运行 `claude`，按提示登录） | `claude auth status`，exit 0 表示已登录 |
| Codex | `codex login` | `codex login status`，exit 0 表示已登录 |
| Gemini CLI | `gemini` → 选择 **Sign in with Google** → 完成后输入 `/quit` | 阶段 9 的 `doctor --deep` 会做实测 |

**无浏览器或远程服务器的情况：**

- **Claude**：在一台有浏览器的电脑上运行 `claude setup-token`，把得到的 token 以 `CLAUDE_CODE_OAUTH_TOKEN=...` 的形式写入 OpenClaw Gateway 进程的环境变量。
- **Codex**：用 `codex login --device-auth`（设备码登录）。
- **Gemini**：也可以用 API key 代替 Google 登录。让用户把 `GEMINI_API_KEY` 写进 `~/conductor/.env`，方法见阶段 7。

注意：OpenClaw 在后台调用这些 CLI 时，用的是**运行 OpenClaw Gateway 的那个系统用户**的登录状态。所以用户必须用同一个系统用户登录。

---

## 5. 安装 Conductor skill

**方式 A：从本文件写出（默认，不需要联网）**

把本文件「附录：skill 文件」里的每个文件，**逐字不改**地写到 `~/.openclaw/skills/conductor/` 下对应的相对路径（每个文件的标题就是它的相对路径）。然后运行：

```bash
chmod +x ~/.openclaw/skills/conductor/scripts/conductor.py
```

**方式 B：从 GitHub 安装（仓库地址见附录开头；如果还没发布，就用方式 A）**

```bash
openclaw skills install git:{{REPO}} --global
```

**验证：**

```bash
openclaw skills info conductor      # 应能看到 conductor；记下它的实际目录，下文记作 <SKILL>
openclaw skills check
python3 <SKILL>/scripts/conductor.py pipelines   # 应输出 5 条流水线
```

---

## 6. 初始化外脑并统一规则

先向用户说明，并**征得同意**：

> 接下来会创建 `~/conductor/`，里面包含外脑、任务目录和共享规则。同时会在 `~/.claude/CLAUDE.md`、`~/.codex/AGENTS.md`、`~/.gemini/GEMINI.md` 末尾各追加一个带标记的区块，让三个 CLI 都读取同一份规则。第一次修改前会自动备份，以后可以用 `conductor.py unwire` 一键移除。

- 用户**同意**：
  ```bash
  python3 <SKILL>/scripts/conductor.py setup --notify-channel <渠道> --notify-target <目标ID>
  ```
- 用户**不同意改全局配置**：在上面的命令后面加 `--no-wire`。这样每个流水线步骤仍然会在提示词里要求 agent 先读 `~/conductor/AGENTS.md`，只是 agent 在流水线之外单独使用时不会自动加载这份规则。
- 如果阶段 1 选了「暂不通知」，就省略 `--notify-*` 这两个参数。

然后打开 `~/conductor/AGENTS.md`，把阶段 1 的访谈结果填进「用户偏好」小节（称呼、默认语言、技术栈），再运行：

```bash
python3 <SKILL>/scripts/conductor.py sync-rules
```

`--no-wire` 会记录在 `config.json` 里（`wire_rules: false`），之后的 `sync-rules` 和所有任务都不会再写这三个文件；流水线改为在每一步的提示词里直接内联共享规则。

**验证**：`setup` 输出 `"ok": true`；`~/conductor/brain/index.md` 已经存在。如果选了 `--no-wire`，要确认上面三个全局文件没有 `conductor:begin` 区块。

---

## 7. 可选：启用 Gemini Deep Research API

先问用户要不要启用。启用前要说明清楚：

- 这一项是**可选的**。不启用的话，研究由 Gemini CLI 联网完成，完全够用。
- Deep Research 更深入，但单次耗时 5–60 分钟，每次约 $2–5，而且需要**付费层**的 API key（在 https://aistudio.google.com/apikey 获取；免费 key 会报 429）。
- 启用后也**不会自动使用**。只有在单个任务里选择 `deep_research` 引擎，或者在 `~/conductor/config.json` 里把 `research.mode` 改成 `"deep_research"` 作为默认，才会用到它。

用户确认要启用时，让他在**自己的终端**里执行下面的命令（密钥不会显示，也不会进入聊天记录）：

```bash
read -rs -p "GEMINI_API_KEY: " K && printf 'GEMINI_API_KEY=%s\n' "$K" > ~/conductor/.env && chmod 600 ~/conductor/.env && unset K && echo saved
```

**验证**：阶段 9 运行 `doctor --deep` 时，`live:gemini_api_key` 这一项为 ok。

---

## 8. 配置 OpenClaw 工具权限

确认 conductor 能用到它需要的工具：`exec`（运行脚本）和 `ask_user`（结构化提问）。

```bash
openclaw config get tools.profile
openclaw exec-policy show
```

- 如果 `tools.profile` 是 `minimal`，或者 `exec` 被禁用，告诉用户 conductor 需要执行 `python3 <SKILL>/scripts/conductor.py`，并征求他的同意，采用下面任意一种办法：
  - 把这条命令加入 exec 的允许列表（allowlist）。具体语法以 `openclaw exec-policy --help` 和 `openclaw approvals --help` 为准；
  - 在 `tools.alsoAllow` 中加入 `exec`。
- **不要**为了省事把工具权限整体切到 `full`。
- 可选：运行 `openclaw security audit`，把结果里的高危项告诉用户。

说明：conductor 通过各个 CLI 的无头模式直接调用它们，**不需要** ACP 或 acpx 插件。

**注意**：外脑接入 OpenClaw 记忆检索（`memory.search.extraPaths`）放在**最后一个阶段**。修改这项配置会让 gateway 重启，正在进行的这轮对话（也就是安装本身）会被中断。

---

## 9. 验收

```bash
python3 <SKILL>/scripts/conductor.py doctor --deep
```

`--deep` 会让每个 CLI 实际回答一次，确认它们都读到了共享规则。所有 `fail` 项都要按输出里的 `fix` 提示处理完；`warn` 项告诉用户即可。

然后做一次**完整的冒烟测试**，把 skill 第 2 到第 4 节的对话流程走一遍（便宜又快，不花 Deep Research 的钱）。

如果 `live:gemini` 失败（比如免费额度用完，报 429），就改用 `build_review`：先建一个一次性仓库（`git init` + 一个小文件），然后让 Claude 做一个极小的改动，由 Codex 审查。完成后要告诉用户，Gemini 那条测试是没跑的。

1. `new --pipeline second_opinion --title smoke --set question="用一句话说明什么是 CRDT"`
2. `render`，把简报给用户看，用 `ask_user` 请他确认
3. `confirm`，然后 `run`
4. 等待完成通知送达聊天。一般 1 到 3 分钟。

   **不要循环轮询。** 如果 5 分钟后还没收到通知，或者没配置通知，就运行一次 `status` 查看状态。任务日志 `log.txt` 里会记录通知是否发出，以及没发出的原因。
5. 用 `result` 查看结果，确认里面有 Claude 和 Gemini 两方观点的对比。

通知没有送达时，检查 `~/conductor/config.json` 里的 `notify` 配置，并手动试一下：

```bash
openclaw message send --channel <渠道> --target <目标> --message test
```

---

## 10. 交付给用户

用简短的话告诉用户下面这些内容：

**1. 怎么用。** 直接说需求就行，比如：

- 「帮我研究一下 X」
- 「研究 X，然后在 ~/code/app 里实现」
- 「让 Claude 和 Gemini 都说说 X」
- 「导入知识」

我会先问几个问题，把简报给你确认，确认后在后台执行，完成时通知你。研究默认交给 Gemini CLI；想要更深入的 Gemini Deep Research（需要付费 key），直接说「用 Deep Research」即可。

**2. 结果在哪里。**

| 内容 | 位置 |
|---|---|
| 每个任务的完整产物 | `~/conductor/jobs/<任务号>/` |
| 代码改动 | 目标仓库的 `conductor/<任务号>` 分支上。不会合并，也不会 push，由用户自己决定 |

**3. 外脑。**

- 所有 agent 共用 `~/conductor/brain`：
  - 知识库：`knowledge/`、`research/`
  - 经验记忆：`memory/lessons.md`
- 共享规则只有一份：`~/conductor/AGENTS.md`。改完后对我说「同步规则」。
- 任务的经验和研究报告**只有在用户说「入库」之后**才会写进外脑。

**4. 怎么导入外部知识。** 把 `<SKILL>/references/knowledge-import.md` 的要点讲给用户：

- 往 `~/conductor/brain/inbox/raw/` 里放文件，然后说「导入知识」；
- 直接发 URL；
- 已有的笔记库可以复制进来，也可以挂载引用；
- 文档量大的话可以装 qmd；
- 可以用 Obsidian 打开 `~/conductor/brain`。

**5. 怎么卸载：**

```bash
python3 <SKILL>/scripts/conductor.py unwire   # 从 ~/.claude、~/.codex、~/.gemini 里移除 conductor 区块
rm -rf ~/.openclaw/skills/conductor           # 删除 skill
# 外脑和历史任务在 ~/conductor；需要的话自行备份，再删除
# 如果改过 memory.search.extraPaths，从里面去掉 brain 路径
```

---

## 11. 最后一步：外脑接入 OpenClaw 记忆检索

先告诉用户：「最后一步会修改 OpenClaw 配置，gateway 会重启，我们这轮对话会中断几秒钟。重启后如果我没有自动接上，你说一声『继续』就好。」

然后执行下面的命令。先查看现有配置再合并，不要覆盖用户已有的路径：

```bash
openclaw config get memory.search.extraPaths
openclaw config set memory.search.extraPaths '["<HOME绝对路径>/conductor/brain"]' --strict-json   # 如果已有其它路径，一并写进这个数组
```

路径必须写**真实的绝对路径**：OpenClaw 建索引时会跳过符号链接。

gateway 重启完成后，运行 `openclaw memory index --force`，再用 `openclaw memory search "外脑"` 确认能搜到 `brain/index.md`。

---

## 附录：skill 文件

下面每个标题都是文件相对 `~/.openclaw/skills/conductor/` 的路径，内容在紧随其后的 `~~~~~` 围栏里。写文件时要**逐字**写入，不能改动任何内容。

- 项目仓库：`https://github.com/{{REPO}}`
- 这些文件由构建脚本从仓库自动生成，与仓库里的源码一致。

{{FILES}}
