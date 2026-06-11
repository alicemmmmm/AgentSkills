---
name: ask-claude
description: Use when the user explicitly asks the current agent to consult Claude or Claude Code CLI for an independent answer, review, multi-round discussion, validation, or environment execution, including requests such as “问 Claude”, “让 Claude 看看”, “让 Claude review”, “和 Claude 讨论”, or “让当前 Agent 调 Claude”.
---

# Ask Claude

通过本机 `claude` CLI 获取一个与主会话分离的第二判断源。主 Agent 负责整理最小上下文、调用 CLI、在需要时组织多轮讨论，并给出最终综合判断。

## 核心规则

- 仅在用户明确要求咨询 Claude 时触发。
- 默认不把完整主会话原样转发给 Claude，只传最小必要上下文。
- 默认不传 `--model`，继承用户当前 Claude CLI 的默认模型。
- 仅在用户明确指定模型时原样传递 `--model <user_model>`。
- 优先返回结构化结果，建议使用 `--output-format json`。
- 当前宿主 Agent 权限只决定 Claude 可获得的权限上限，不自动把所有请求提升到最高权限。
- 单次调用 Claude 不构成“讨论”。只有当 Claude 能看到主 Agent 的明确观点，且主 Agent 能看到 Claude 的回应并继续回复时，才算讨论。

## 分支选择

先看用户是否显式指定：

- `ask`：问答、解释、思路、文案、独立意见
- `review`：代码审查、风险判断、报错分析、方案比较、正确性校验
- `debate`：多轮讨论、辩论、观点碰撞、反驳与再回应
- `execute`：明确要求 Claude 自己运行命令、读取仓库、使用工具或修改文件

如果用户没有显式指定，按下面规则选择：

1. 请求要求 Claude 实际操作环境、运行命令、读仓库、改文件时，用 `execute`。
2. 请求明确要求“讨论”、“辩论”、“反驳”、“来回聊几轮”或需要 Claude 对主 Agent 观点做回应时，用 `debate`。
3. 请求关注风险、质量、报错、审查、方案比较时，用 `review`。
4. 其余情况用 `ask`。

不确定时，不进入 `execute`，默认降到 `review` 或 `ask`。

## 与宿主权限联动

把当前宿主 Agent 权限视为 Claude 的权限上限，而不是默认档位。

- `请求批准`
  - `ask`：低权限
  - `review`：低到中权限
  - `debate`：低到中权限
  - `execute`：默认降级为 `review`；只有用户明确要求执行时才进入 `execute`，并接受宿主平台的批准流程
- `替我审批`
  - `ask`：低权限
  - `review`：中权限
  - `debate`：中权限
  - `execute`：可进入高权限，由主 Agent 按风险自行审批
- `完全访问权限`
  - `ask`：仍按低权限运行
  - `review`：仍按中权限运行
  - `debate`：仍按中权限运行
  - `execute`：默认可用最高权限

即使在 `完全访问权限` 下，也不要把纯问答或普通 review 自动提升为最高权限执行。

## 命令模板

## Session 策略

- `ask`：默认新建 Claude 短会话，保持独立判断，避免旧话题污染。
- `review`：默认新建 Claude 短会话，保持审查结果独立、可复现。
- `debate`：默认新建 Claude 短会话，并通过显式注入上一轮摘要延续讨论；不要为了省会话而长期复用。
- `execute`：默认新建 Claude 短会话，避免执行上下文、工具状态和旧错误污染后续任务。

只有在用户明确要求连续延续某个已有 Claude 会话时，才显式使用 `--resume <session_id>` 或 `--session-id <uuid>`。

用户说“继续刚才的讨论”、“继续上面的”、“你们再讨论下”、“在刚才基础上继续”等表达时，可以自动续接最近一次 `debate` 的 Claude session，但必须同时满足：

1. 最近一次可续接 session 的分支是 `debate`。
2. 仍在当前主会话内，或 `last_used_at` 距当前时间不超过 2 小时。
3. 新请求与最近一次 `debate` 的主题明显一致。
4. 最近只有一个候选 `debate` session；如果有多个候选，不要猜，要求用户指定。

如果新请求明显换主题，即使用了“继续刚才”，也新建 Claude 短会话，并把旧结论摘要显式注入 prompt。

### 会话索引

维护轻量 JSONL 索引：`<ask-claude skill dir>/.state/sessions.jsonl`。如果宿主平台不允许写入 skill 目录，改用当前工作区的 `.ask-claude/sessions.jsonl`。

每次成功调用 Claude 后，如果返回了 `session_id`，追加一条记录：

```json
{"session_id":"<uuid>","branch":"ask|review|debate|execute","topic":"<short topic>","cwd":"<cwd>","created_at":"<iso8601>","last_used_at":"<iso8601>","status":"active","prompt_preview":"<first 80 chars>","summary":"<short result summary>"}
```

索引用途只限：

- 审计 ask-claude 创建过哪些 Claude 会话。
- 查找最近一次可续接的 `debate` session。
- 辅助用户按时间或数量清理历史。

索引不用于普通 `ask`、`review`、`execute` 的自动 resume，不做长期 topic 匹配，不作为主流程依赖。索引写入失败、损坏或拿不到 `session_id` 时，静默跳过记录，不阻断 Claude 调用。

## 平台适配

本技能的平台边界是 `claude` CLI，不抽象成任意模型 CLI。迁移到 Qoder、Claude Code、Codex 或其它 Agent 时，只需要适配宿主平台能力：

- Shell 执行：用宿主平台可用的命令执行工具运行同等 `claude` 命令。
- 文件读写：如果不能写 skill 目录，把会话索引写到当前工作区 `.ask-claude/sessions.jsonl`。
- 权限模型：把宿主 Agent 当前权限当作 Claude 的权限上限；不要绕过宿主平台审批。
- 会话上下文：主 Agent 负责整理最小上下文；不要假设不同 Agent 的主会话上下文会自动共享给 Claude。
- 命令兼容：如果目标平台或 Claude CLI 版本不支持某个参数，降级为最接近的无状态 `claude -p` 调用，并在结果里说明。

### ask

```bash
claude -p --output-format json "<prompt>"
```

### review

```bash
claude -p --output-format json --permission-mode default "<prompt>"
```

如果不需要 Claude 自己动工具，进一步限制工具范围。

### debate

```bash
claude -p --output-format json --permission-mode default "<prompt>"
```

`debate` 默认和 `review` 使用同等级权限，重点区别在于它必须是多轮、双向可见的观点交换，而不是一次性征求意见。
同一次 `debate` 中，优先通过显式注入上一轮摘要延续讨论；仅当用户要求“继续刚才的讨论”且满足 Session 策略中的续接条件时，才自动 `--resume` 最近一次 `debate` session。

### execute

```bash
claude -p --output-format json --permission-mode bypassPermissions "<prompt>"
```

只有在下面两个条件同时满足时才使用 `execute`：

1. 用户明确要求 Claude 实际操作环境，或任务不操作环境就无法完成。
2. 当前宿主 Agent 权限允许进入高权限执行。

## Debate 工作流

`debate` 默认两轮，最多三轮：

1. **主 Agent 立场**：主 Agent 先给出自己的初始判断、理由和保留意见。
2. **Claude 回应**：Claude 必须针对主 Agent 的立场表态，支持、反对或部分修正，并给出依据。
3. **主 Agent 再回应**：主 Agent 看完 Claude 的回应后，明确说明接受哪些点、反驳哪些点、保留哪些判断。
4. **可选第三轮**：只有在第 2 轮后仍存在一个明确且影响最终决策的核心争议点时，再让 Claude 回应一次。
5. **最终裁决**：由主 Agent 汇总双方观点并给出最后判断。

控制规则：

- 每轮只讨论一个核心争议主题。
- 每轮都压缩摘要，不传完整长文。
- 默认两轮，除非仍有明确核心分歧，否则不要进入第 3 轮。
- 默认最多三轮，避免空转争论。
- 如果某一轮没有产生新的分歧、证据或决策信息，立即停止 `debate`。
- 超过三轮仍未收敛时，不再继续争论，由主 Agent 直接裁决。
- 如果 Claude 没有看到主 Agent 的具体观点，这次调用只能算 `ask` 或 `review`，不能算 `debate`。
- 第 2 轮和可选第 3 轮必须看见上一轮 Claude 摘要和主 Agent 回应；默认用新短会话加显式摘要，只有满足“继续刚才”的续接条件时才使用 `--resume`。

建议轮次模板：

```text
第 1 轮给 Claude：
问题：
<主题>

主 Agent 当前观点：
<初始判断>

请你完成：
1. 你同意还是反对？
2. 你认为主 Agent 忽略了什么？
3. 你的更优判断是什么？
```

```text
第 2 轮给 Claude：
问题：
<同一主题>

Claude 上轮观点摘要：
<Claude 观点摘要>

主 Agent 对你的回应：
<主 Agent 接受/反驳/修正后的回应>

请你完成：
1. 你是否改变观点？
2. 仍然存在的核心分歧是什么？
3. 给出你的最终立场。
```

## Prompt 组织

给 Claude 的 prompt 保持最小化，通常只包含：

- 当前任务
- 目标和约束
- 已尝试方案和结果
- 当前卡点
- 必要的文件路径、diff、错误信息、日志摘要
- 如果是 `debate`，必须额外包含主 Agent 当前明确观点

不要传无关闲聊、重复背景或完整长对话。

建议模板：

```text
任务：
<需要 Claude 完成的具体目标>

上下文：
<最小必要上下文>

输出要求：
请返回 summary、findings、assumptions、recommended_next_step、confidence。
```

## 输出约定

主 Agent 对用户汇报时，区分三层信息：

- Claude 的原始结论
- 主 Agent 对 Claude 结论的可信度判断
- 主 Agent 最终综合结论

至少整理出：

- `summary`
- `findings`
- `assumptions`
- `recommended_next_step`
- `confidence`

如果 Claude 实际运行了命令，再补充：

- `commands_summary`
- `files_changed`
- `risk_notes`

如果是 `debate`，额外整理出：

- `primary_agent_position`
- `claude_position`
- `main_disagreement`
- `resolution`

## 仓库和文件安全

涉及仓库操作时：

1. 调用前记录 `git status --short`
2. Claude 返回后再次检查 `git status --short`
3. 如果出现文件变更，立即在结果中明确报告

如果用户只是要独立意见，不允许 Claude 擅自修改文件。

## 失败处理

当出现以下情况时，明确告诉用户 Claude 未成功参与：

- `claude` CLI 未安装
- 未登录或认证失效
- 命令超时
- 模型不可用
- 权限不足

此时由主 Agent 本地给出备选分析，不伪造 Claude 结果。
