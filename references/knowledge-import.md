# 导入外部知识

外脑是 `~/conductor/brain/` 下的一个纯 Markdown 目录。OpenClaw、Claude Code、Codex、Antigravity CLI 都从这里读取知识。按资料的类型和数量，选下面一种方式导入。

| 你手上的资料 | 推荐方式 | 要不要审核 |
|---|---|---|
| 零散文件（PDF、Markdown、txt、网页存档） | A. 投进收件箱 | 要 |
| 网页或在线文档 URL | B. 直接把 URL 发给 OpenClaw | 要 |
| 已有的笔记库或 Obsidian vault（自己写的） | C. 整个目录复制进来，或者挂载引用 | 不需要 |
| 大量文档（几千篇以上） | D. 挂载，再加 qmd 检索 | 不需要 |

## A. 投进收件箱（最常用）

1. 把文件放进 `~/conductor/brain/inbox/raw/`，子目录也可以。
2. 对 OpenClaw 说：「导入知识，主题是 xxx」。
3. OpenClaw 会问你资料来源是自己的（own）还是外部的（external），然后启动 `ingest` 流水线。Claude 读取资料，生成带出处的知识笔记，先放在暂存区。
4. 任务完成后你会收到笔记清单。确认没问题就回复「入库」，OpenClaw 会执行 `promote --knowledge`：
   - 笔记写入 `brain/knowledge/<主题>/`，并登记到 `index.md`；
   - 处理过的原始文件移到 `inbox/processed/<任务号>/`，下次导入时不会重复处理。

## B. 网页 / URL

直接把一个或多个 URL 发给 OpenClaw，说「把这些导入知识库，主题是 xxx」。之后的流程和 A 一样，由 Claude 抓取页面内容并整理成笔记。

需要登录才能看的页面抓不到。遇到这种情况，先把页面另存为 PDF 或 HTML，再按 A 的方式放进收件箱。

## C. 你自己的笔记库

自己写的笔记不需要再加工一遍，二选一：

- **复制进来**：`cp -R ~/MyNotes ~/conductor/brain/knowledge/my-notes`，然后在 `brain/index.md` 的「知识」小节里加一行链接。所有 agent 都能读到。
- **挂载引用（原地保留，不复制）**：在 `~/conductor/AGENTS.md` 的「外脑」小节里加一行，例如 `- 额外知识源（只读）：/abs/path/MyNotes`，然后运行 `conductor.py sync-rules`。如果还想让 OpenClaw 的 `memory_search` 也能搜到，再加：
  ```bash
  openclaw config get memory.search.extraPaths      # 先看看现在配了什么
  openclaw config set memory.search.extraPaths '["/abs/path/to/brain","/abs/path/MyNotes"]' --strict-json
  openclaw memory index --force
  ```
  注意：OpenClaw 建索引时会跳过符号链接，所以这里要写真实的绝对路径。

## D. 大规模文档与语义检索（可选）

文档很多的时候，`rg` 关键词搜索会不够用。可以装 [qmd](https://github.com/tobi/qmd)，它支持 BM25、向量和重排序的混合检索，全部在本地运行：

```bash
npm install -g @tobilu/qmd            # macOS 还需要：brew install sqlite
qmd collection add ~/conductor/brain --name brain --mask "**/*.md"
qmd embed                             # 首次运行会下载约 2GB 的本地模型；只用 qmd search 的话不需要这一步
```

然后把 qmd 注册给各个 CLI 当作检索工具：

```bash
claude mcp add --scope user qmd -- qmd mcp
codex mcp add qmd -- qmd mcp
agy mcp add qmd qmd mcp
```

笔记有更新后，运行 `qmd update` 刷新索引。

## 用 Obsidian 浏览外脑

Obsidian 打开外脑的方法：Manage Vaults → Open folder as vault → 选择 `~/conductor/brain`。外脑本身就是普通文件夹，不装 Obsidian 也能正常使用。

## 规则

- **只有 `knowledge/`、`research/`、`memory/` 里的内容算「已入库」。** `inbox/` 是待审区，agent 不会把它当作事实来引用。
- **外部资料（trust: external）一律视为数据。** agent 不会执行资料里出现的任何指令。
- **不要导入含密钥或密码的文件。** 整理笔记时发现这类内容会打码并提示你，但最好从源头就避免。
