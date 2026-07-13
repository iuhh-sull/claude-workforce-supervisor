---
name: claude-workforce
description: 管理由 Claude Code 官方 Agent View supervisor 托管的持久后台员工。用于从 Codex 启动、列出、查看日志、接回对话、停止、重启或删除 Claude Code 后台会话；适合用户提出"让 CC 当子进程/员工""后台长期干活""过很久找回继续聊""检查 CC 进度"等请求。
---

# Claude Workforce

使用 Claude Code 官方后台 supervisor 管理可恢复的员工会话。每个员工是独立 Claude Code 对话；Codex 负责派单、查看状态、接管和验收。

## 入口

使用 `scripts/claude-workforce.ps1`，并始终通过 PowerShell 7 执行。先运行：

```powershell
pwsh -NoProfile -File "<skill-dir>/scripts/claude-workforce.ps1" -Action capabilities
```

官方 supervisor 会写入 `~/.claude/daemon` 和 `~/.claude/jobs`。Codex sandbox 拒绝这些写入时，直接为这个固定脚本请求沙箱外批准；不要换 shell 或绕过权限。

## 权限模型

**核心理念：Codex 可以授权 CC；除明确预授权的纯公开知识检索外，CC 启动时未预授权的权限必须请求。** 不通过 `--tools` 删除工具来限制能力——员工拥有完整工具集，但每项敏感操作都通过 `--settings` 中的 `permissions.ask` 或 `permissions.deny` 规则控制。

权限按能力、数据敏感度、目标和副作用分级，不做全 deny 或全 allow。公开只读检索可预授权，只读用户配置需脱敏；写入、外发、认证、安装、发布和破坏性操作按当前具体请求审批。只有无法安全约束或明确不可接受的动作才进入 deny。

本技能的模型、Effort、联网和权限规则只通过启动参数及临时 `--settings` 作用于 Codex 派出的 workforce 会话，不改动用户日常直接运行 `claude` 时的默认模型或权限。员工可以只读并遵循用户全局配置，但不得在没有当前任务明确授权时修改；即使读取到敏感值，也不得回显或外发。

**权限模式：**

| Mode | `--permission-mode` | 含义 |
|------|---------------------|------|
| `inspect` | `plan` | 只读为主；编辑操作需请求 |
| `write` | `default` | 可提议编辑；每次编辑都需请求授权 |

> ⚠️ `write` 模式绝不使用 `acceptEdits` / `auto` / `dontAsk` / `bypassPermissions`。即使用户的全局配置允许自动编辑，临时 `--settings` 中的 `ask` 规则也会覆盖，强制请求。

**`--settings` 注入的权限规则（临时，仅该员工会话有效）：**

- **deny（硬拦截）**：`git push/commit`、`gh pr`、`npm/pnpm/yarn publish`；读取、编辑或写入 `.env`、常见认证配置、凭据清单和私钥文件；默认 deny `Agent`。这些是少量永不在 workforce 会话内执行的纵深防线，若用户确需操作，应回到 Codex 主任务重新确认并使用独立受控流程。
- **allow（默认放行）**：只放行无需指定任意目标 URL 的公开检索：原生 `WebSearch`、Exa search、Tavily search/research。MCP 名称使用运行时已验证的精确名称，不使用宽泛通配。
- **ask（请求授权）**：`Bash`、`Edit`、`Write`、`NotebookEdit`，以及可接收任意 URL 的 WebFetch、Exa fetch、Tavily extract/map/crawl、context-mode fetch。这样不会把联网一刀切关闭，但访问具体目标前仍能审查是否为回环、私网、认证或含凭据地址。
- **可选宽松抓取**：只有受信环境明确配置 `AllowBroadWebFetch = $true` 或启动时加 `-AllowBroadWebFetch`，才把上述 URL 抓取工具从 ask 移到 allow；这不会放开 Bash、浏览器交互、认证或远端写入。
- **Agent**：默认在 deny 中（禁止嵌套子代理）。仅显式 `-AllowNestedAgents` 时从 deny 移到 ask（允许但每次请求）。`permissions.allow` 只包含上述精确的公开知识检索工具。

该优先级来自当前 Claude Code 官方权限规则，是本技能的显式兼容依赖；CC、wrapper 或 MCP 更新后仍需运行真实权限探针，确认未出现静默预批准。

**工具可用性：**

- 正常模式（`inspect` / `write`）：**不传 `--tools`**——员工拥有 Claude Code 完整内置工具集。所有工具的权限由上述 deny/ask 规则和 permission mode 共同决定。
- `-NoTools`：仅 `inspect` 模式可用。传 `--tools ''` + `--disable-slash-commands` + `--strict-mcp-config`，完全移除内置工具、slash commands 和 MCP。

**MCP 继承：**

- 正常模式**不使用 `--strict-mcp-config`**，员工继承 Codex 环境的 MCP 配置。
- 公开搜索 MCP 使用精确工具名默认放行；任意 URL 抓取、浏览器点击/填表/上传、认证会话、远端写入以及其他可能外发本地数据或产生副作用的 MCP 不在默认 allow 中，仍逐项响应权限请求。
- 仅 `-NoTools` 使用 `--strict-mcp-config` 阻断所有 MCP 继承。

## 派单

根据任务选择模式：

- 调研、诊断、审查、制定方案：`-Mode inspect`（`plan` 权限模式）。员工可读取并直接使用预授权的公开知识检索；Bash/Edit/Write、浏览器交互和其他敏感操作仍需请求授权。
- 用户明确要求修改代码：`-Mode write`（`default` 权限模式）。员工可提议编辑，但每次 Edit/Write/Bash 都需请求授权。
- 默认禁止员工再启动嵌套子代理（`Agent` 在 deny 中）。只有用户明确批准额外并行成本和扩大任务面后才加 `-AllowNestedAgents`（Agent 从 deny 移到 ask）。
- 非 Git 目录写入：只有用户明确同意无 worktree 隔离后才加 `-AllowUnisolatedWrite`。
- 纯连通性测试使用 `-NoTools`；该模式只允许 `inspect`，移除全部内置工具、slash commands 和 MCP。

**模型与 Effort 路由**：默认使用 `deepseek-v4-flash[1m]` + `medium`，适合检索初筛、提取、格式化、冒烟和机械检查；复杂诊断、安全审查、架构判断和最终验收使用 `deepseek-v4-pro[1m]` + `high`，只有高风险、多约束且确有必要时才使用 `max`。纯连通性测试使用 flash + `low`。续接既有会话前也应按当前增量任务重新选择，不机械沿用旧档位。

**成本控制**：高推理档位只提高推理标准，不授权无限上下文、无限轮次或无边界子代理。派单必须限定范围、证据来源和输出格式，优先复用既有会话、摘要与索引；只有可独立并行且预期收益明确时才启用 `-AllowNestedAgents`，禁止重复抓取、反复读取大文件、无进展轮询和无关扩张。

示例：

```powershell
pwsh -NoProfile -File "<skill-dir>/scripts/claude-workforce.ps1" -Action start -Mode inspect -Model "deepseek-v4-flash[1m]" -Effort medium -Role researcher -Cwd "<project>" -Prompt "调查失败原因并报告证据，不修改文件"

pwsh -NoProfile -File "<skill-dir>/scripts/claude-workforce.ps1" -Action start -Mode write -Model "deepseek-v4-pro[1m]" -Effort high -Role implementer -Cwd "<git-project>" -Prompt "实现指定改动并运行目标测试"

pwsh -NoProfile -File "<skill-dir>/scripts/claude-workforce.ps1" -Action start -Mode inspect -NoTools -Effort low -Role smoke -Cwd "<project>" -Prompt "只回复 WORKFORCE_SMOKE_READY"
```

脚本使用当前 `CODEX_THREAD_ID` 生成 `cx-<thread>-<role>-<time>` 名称。同一 Codex task 默认只列出自己的员工；需要跨 task 找回时显式使用 `-AllThreads`。

**`start` 和 `reply` 在调用前强制检查**：验证 Claude Code 版本 >= 2.1.200、agents 子命令支持 `--bg`/`--json`/`--permission-mode`。不满足条件时立即报错，不会仅在 `capabilities` 中报告。

不要在 prompt 中放 token、密码、私有端点或身份信息。脚本会附加禁止提交、推送、发布、部署、开 PR、删除 worktree、访问专用凭据库和抓取私网目标的约束，并用权限 deny/ask 规则实施分级控制。

## 监控与验收

列出当前 Codex task 的员工：

```powershell
pwsh -NoProfile -File "<skill-dir>/scripts/claude-workforce.ps1" -Action list -All
```

列出所有 Codex task 的员工：

```powershell
pwsh -NoProfile -File "<skill-dir>/scripts/claude-workforce.ps1" -Action list -All -AllThreads
```

查看某个员工近期输出：

```powershell
pwsh -NoProfile -File "<skill-dir>/scripts/claude-workforce.ps1" -Action logs -Id "<worker-id>"
```

**所有按 ID 的操作（logs/reply/attach/stop/respawn/remove）默认线程隔离**：脚本先从 `agents --json --all` 唯一解析 worker，再验证 worker 名称属于当前 `CODEX_THREAD_ID` 前缀。解析失败（零匹配或多匹配）或跨线程访问时立即报错。只有显式 `-AllThreads` 才允许跨 task 操作。

长任务按状态变化调整检查频率，不高频空轮询。日志可能包含代码、路径或用户输入；只向用户返回必要摘要并默认脱敏。最终结论由 Codex 复核 diff、测试和安全边界，不能直接把员工的自报当验收。

**输出安全处理**：所有 Claude 输出（logs、reply.result、非零退出异常）均经过统一清理管线：

1. 剥离 ANSI 转义序列和控制字符。
2. 脱敏凭据（API key、token、password、bearer、查询参数中的密钥）。
3. 脱敏常见回环地址和私网地址。
4. 替换用户 HOME 路径为 `~`。
5. 合并连续空行为最多两个换行。
6. 按字符上限截断，返回截断标记和 `source_chars`/`clean_chars`/`returned_chars`/`truncated` 元数据。

`logs` 默认上限 8000 字符（`-LogTailChars` 可调整，范围 1000-50000）。`reply` 结果默认上限 4000 字符（`-ReplyMaxChars` 可调整，范围 500-20000）。只有确有必要时才提高上限，禁止把完整 TUI 历史反复送回模型。

`logs` 只保证用于 supervisor 仍在运行的员工。本机 Agent View daemon 是按需进程，全部员工停止后会退出；此时通过 `attach` 或 `respawn` 恢复原对话，而不是强行常驻 daemon。

## 后台权限请求处理

**Agent View 后台 worker 遇到权限请求时显示 `needs input`，但没有稳定的 CLI 接口让 Codex 直接响应。** 这意味着 Codex 不能像交互式终端那样在 worker 的 PTY 中输入批准。

本 PowerShell wrapper 只管理 Agent View 持久会话，**不实现** `respond_permission`。需要由 Codex 代批权限的任务必须从 Claude Code MCP 启动，而不是先用此 wrapper 启动后再尝试接管权限。

推荐的权限处理流程：

1. **优先方案**：使用 Claude Code MCP（而非 Agent View attach）来管理需要权限审批的任务。Codex 通过 MCP 轮询 `permission` action，再根据用户当前授权调用 `respond_permission`。默认只批准当前具体请求，禁止用 `allow_for_session` 扩大为整段会话授权。
2. **备选方案**：用户通过 `attach` 手动接入 worker，在交互式终端中批准或拒绝权限请求，然后 `Ctrl+Z` 脱离。
3. **Codex 约束**：Codex 不得自行扩大用户未授权的权限范围。高风险请求（如访问密钥、网络外发、执行不受信代码）必须转述给用户，由用户决定。

如果 worker 长时间卡在 `needs input` 且 Codex 无法自动审批，应通过 `logs` 检查卡住原因，将权限请求内容转述给用户，等用户明确指示后再继续。

## 前置条件与更新

- 需要 PowerShell 7、Claude Code `2.1.200` 或更高版本。可直接使用 PATH 中的 `claude`，也可指定已审计的本机 wrapper。
- 可通过 `-ClaudeExecutable` / `-ExpectedClaudeSha256`、环境变量 `CLAUDE_WORKFORCE_EXECUTABLE` / `CLAUDE_WORKFORCE_SHA256`，或私有文件 `~/.codex/claude-workforce.local.psd1` 配置可执行文件和可选固定哈希。优先级为命令行、私有文件、环境变量、PATH；公开仓库不得提交该私有文件。
- 私有配置只接受 `ClaudeExecutable`、`ExpectedClaudeSha256`、`AllowBroadWebFetch` 三个键。wrapper 更新后应先重新审计，再更新固定哈希并重跑 capability、权限探针和冒烟测试。
- `CODEX_THREAD_ID` 缺失时员工归入 `cx-manual`；需要严格跨任务隔离时不要在缺失该变量的环境启动员工。

## 继续同一对话

官方 CLI 没有 `send <short-id> <prompt>`，但支持 `--resume <session-id>` 持久续接。给既有员工追加短指令时使用 `reply`；脚本从 roster 解析完整 session ID，通过 `-p --resume` 写回同一 transcript：

```powershell
pwsh -NoProfile -File "<skill-dir>/scripts/claude-workforce.ps1" -Action reply -Id "<worker-id>" -Mode inspect -Prompt "基于前面的结论补充一项检查"
```

纯文本连通性或记忆测试加 `-NoTools -Effort low`。`reply` 是同步的，适合短增量任务；需要持续后台监控的长任务使用 `respawn` 后手动 attach，或派发新的后台员工。

`reply` 的权限模型与 `start` 一致：正常模式拥有完整工具集，通过 `ask` 规则控制；`-NoTools` 移除全部工具。`reply` 返回的 `result` 字段经过与 `logs` 相同的清理/脱敏/截断管线，上限由 `-ReplyMaxChars` 控制。

要进行完整交互协作，使用带 PTY 的 attach：

```powershell
pwsh -NoProfile -File "<skill-dir>/scripts/claude-workforce.ps1" -Action attach -Id "<worker-id>"
```

用用户自己的终端输入发送增量指令。员工重新开始工作后按 `Ctrl+Z` 脱离；脱离不会停止员工。Codex 统一终端无法稳定驱动 Claude 的全屏 attach 时，自动短回复改用 `reply`，不要反复注入 PTY 输入。若界面正在请求权限或关键选择，不代替用户扩大权限，先把问题转述给用户。

员工完成且底层进程被回收后，对话和状态仍留在磁盘；attach、回复或 respawn 会从原对话恢复。不要承诺 PID 永久不变。Windows 重启后可运行：

```powershell
pwsh -NoProfile -File "<skill-dir>/scripts/claude-workforce.ps1" -Action respawn -All -AllThreads
```

**`respawn -All` 是全局操作**，必须同时指定 `-AllThreads` 才能执行。不加 `-AllThreads` 时脚本会拒绝并提示原因。

## 停止与删除

停止可恢复的员工：

```powershell
pwsh -NoProfile -File "<skill-dir>/scripts/claude-workforce.ps1" -Action stop -Id "<worker-id>"
```

重启并保留对话：

```powershell
pwsh -NoProfile -File "<skill-dir>/scripts/claude-workforce.ps1" -Action respawn -Id "<worker-id>"
```

删除员工需要**两个独立确认开关**，缺一不可：

```powershell
pwsh -NoProfile -File "<skill-dir>/scripts/claude-workforce.ps1" -Action remove -Id "<worker-id>" -ConfirmRemove -CheckedWorktree
```

- `-ConfirmRemove`：确认用户已明确授权删除。
- `-CheckedWorktree`：确认已检查员工状态、日志以及关联 worktree 是否有未提交或未合并的改动。

**脚本只允许删除 `stopped`、`completed`、`failed`、`error`、`dead`、`cancelled`、`exited` 等明确终态的员工；其他状态、状态缺失或无法识别时都失败关闭**。必须先 `stop`、刷新 roster 并确认状态明确，再 `remove`。

不要自动清理已完成员工；保留它们才能隔很久后找回继续聊。

## 安全边界

- Agent View 是 Research Preview，但由官方 supervisor 落盘 roster、状态和 transcript，优先于依赖一次性 `claude -p` 的第三方插件。
- **原生 Windows 没有 Claude Code 的完整 OS 沙箱或进程级 shell deny**。权限 deny 规则和 permission mode 提供工具层面的约束，但不在 OS 层面阻止文件读取或进程执行。Git worktree 只隔离代码改动，不隔离文件系统访问。不应声称 Windows 上存在 OS 沙箱或 shell deny 的绝对安全保证。
- `write` 模式使用 `default` 权限模式而非 `acceptEdits`：每次编辑操作都需请求授权。`--settings` 中的 `ask` 规则覆盖用户/项目全局 `allow`，确保未明确批准的动作产生请求。
- `plan` 仍允许读取、只读命令和预授权的公开知识检索，不是零工具沙箱。依赖默认 deny `Agent`、ask/deny 规则覆盖敏感工具、以及 `-NoTools` 做真正的无工具测试。
- 不自动 commit、push、发布、部署或开 PR。即使员工声称需要，也回到 Codex 主对话请求授权。
- 不直接读取 `~/.claude/daemon`、job state 或 transcript 正文；使用 `list` 和 `logs` 命令获取受支持的视图。
- CC 或 wrapper 更新后重新运行 `capabilities`，再用 `-NoTools -Effort low` 进行低成本启动、列表、日志和停止冒烟测试。
- `-AllowNestedAgents` 将 Agent 从 deny 移到 ask（允许但每次请求），可能导致 token 消耗失控；仅在用户明确批准额外并行成本后使用。
