# AgentSkills

公开可分享的 Agent/Codex Skills 集合。

## 项目结构

```text
skills/
└── ask-claude/        # 将 Claude Code CLI 作为外部子代理调用
    ├── SKILL.md       # 技能定义与使用说明
    └── agents/
        └── openai.yaml # OpenAI Codex 接口配置
```

## 已有技能

### ask-claude

通过本机 `claude` CLI 获取一个与主会话分离的第二判断源。主 Agent 负责整理最小上下文、调用 CLI、在需要时组织多轮讨论，并给出最终综合判断。

适用场景：

- 问 Claude 问题，或让 Claude 看代码、文件、日志、diff
- 运行只读验证，写不落盘探针
- 代码 review、风险评估、架构建议
- Codex 与 Claude 进行有限讨论

## 使用方式

将需要使用的技能目录复制或链接到 Codex 可发现的 skills 目录，例如：

```powershell
Copy-Item -Recurse .\skills\ask-claude "$env:USERPROFILE\.codex\skills\ask-claude"
```

