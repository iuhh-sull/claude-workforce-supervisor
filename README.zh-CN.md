# Claude Workforce

> 非官方项目。[English](./README.md)

Claude Workforce 让 Codex 通过官方 `claude agents` supervisor 管理 Claude Code 后台员工。Codex 负责派活、查状态、看日志和验收；任务中断后，还能通过 supervisor 接回原来的对话。

这是一个围绕官方 `agents` 子命令编写的非官方 Codex skill，适合调研、代码审查和分阶段执行的后台任务。

## 安装

```powershell
pwsh -NoProfile -File Install.ps1
```

首次安装不加 `-Force`。升级或替换已有安装时才加 `-Force`，安装器会先备份旧目录。

装完可以建私有配置文件 `~/.codex/claude-workforce.local.psd1`，推荐使用的有效键是：

```powershell
@{
    ClaudeExecutable   = "C:\path\to\claude.exe"
    ExpectedClaudeSha256 = "<64位十六进制哈希>"
    EnableToolSearch = $true
}
```

旧键 `AllowBroadWebFetch` 仍会被解析，避免已有私有配置突然报错，但它不再授予任何权限，方便时删掉即可。

不要提交到公开仓库。优先级：命令行参数 > 私有文件 > 环境变量 > PATH。

`EnableToolSearch` 只在 `-ContextProfile full` 下生效，因为其他档位不会继承 MCP；加了 `-NoTools` 时则始终关闭。

## 快速开始

先确认环境：

```powershell
$workforce = Join-Path $HOME '.codex\skills\claude-workforce\scripts\claude-workforce.ps1'
pwsh -NoProfile -File $workforce -Action capabilities
```

一次性任务优先用 `run`。DeepSeek 的实际费用用 `-ProviderBudgetCny` 做运行后软阈值，执行边界主要由 `-MaxTurns` 控制：

```powershell
# 纯文本/数字判断：最小上下文、无工具，成功后不留会话
pwsh -NoProfile -File $workforce -Action run -Mode inspect -NoTools -Ephemeral `
  -ContextProfile minimal -MaxTurns 1 -ProviderBudgetCny 0.01 `
  -Model "deepseek-v4-flash[1m]" -Effort low `
  -Cwd "<项目路径>" -Prompt "只回复检查结论"

# 公开资料检索：保留 session，预算或回合用完后仍可续接
pwsh -NoProfile -File $workforce -Action run -Mode inspect `
  -ContextProfile project -MaxTurns 4 -ProviderBudgetCny 0.10 `
  -Model "deepseek-v4-flash[1m]" -Effort medium `
  -Cwd "<项目路径>" -Prompt "搜索公开资料并给出带来源的简短结论"
```

只有任务需要持续在后台运行、以后还能接回时，才用 `start` 启动员工：

```powershell
# 调研模式，flash 模型，中等推理
pwsh -NoProfile -File $workforce -Action start -Mode inspect `
  -Model "deepseek-v4-flash[1m]" -Effort medium -Role researcher `
  -Cwd "<项目路径>" -Prompt "调查失败原因并列出证据，不修改文件"

# 写代码模式，pro 模型，高推理
pwsh -NoProfile -File $workforce -Action start -Mode write `
  -Model "deepseek-v4-pro[1m]" -Effort high -Role implementer `
  -Cwd "<Git 项目路径>" -Prompt "实现 X 改动并跑目标测试"

# 需要继承 MCP 时显式用 full；自定义代理先验证 Tool Search 兼容性
pwsh -NoProfile -File $workforce -Action start -Mode inspect `
  -ContextProfile full -EnableToolSearch -Effort medium -Role researcher `
  -Cwd "<项目路径>" -Prompt "用现有 MCP 调查问题并报告证据"
```

status、log、reply、stop、remove 的完整用法见 [SKILL.md](./claude-workforce/SKILL.md)。

## 成本与上下文档位

`auto`：无工具任务自动选用 `minimal`，其他任务自动选用 `project`；`reply` 也使用这个默认逻辑。`minimal` 关闭 hooks、skills、plugins、MCP、memory 和 CLAUDE.md；`user` 只加载用户级配置但不加载 MCP；`project` 加载用户和项目规则但不加载 MCP；`full` 才继承全部配置和 MCP。

完整工具环境可能在第一句话之前就注入数万 tokens。只有任务确实需要 MCP 时才用 `full`。自定义 `ANTHROPIC_BASE_URL` 下，Claude Code 默认可能不启用 Tool Search；`EnableToolSearch = $true` 必须经过真实 MCP 调用验证后再设。wrapper 还把单个 MCP 输出默认限制在 10,000 tokens。

评估是否省额度时，不能把 Codex/GPT 和 DeepSeek/CC 的 token 或费用相加。先算 CC 避免了多少 Codex 上下文，再扣掉派单、轮询、定点复核和返工；DeepSeek 费用单独报告。CC 返回后，Codex 默认只核对它标出的路径、行号、URL、diff 和失败点，不再通读同一批材料。若最终仍需完整重读，这次调用属于交叉审查，不算节省 Codex 额度。

自定义 DeepSeek 端点下，Claude Agent SDK 的 `total_cost_usd` 可能按 Anthropic 模型价目估算，不能当成供应商账单，wrapper 默认不会输出它；只有诊断兼容层时才加 `-IncludeSdkCostEstimate`。常规结果根据本次模型、`usage` 和已审计的 DeepSeek 价格返回 `provider_billing_tokens`（缓存未命中/缓存命中/输出三类 token）、`provider_cost_components_cny`（三项费用）和合计 `provider_cost_estimate_cny`。这是本地 decimal 计算，不会让 CC 重读任务。usage 不完整时会明确标记证据不足，不猜费用。

`-ProviderBudgetCny` 是运行结束后的软阈值，适合记账和告警；`-MaxBudgetUsd` 仍可作为 SDK 内部硬停止，但它不代表 DeepSeek 人民币额度。官方后台 `--bg` 不支持这两个限制，所以 `start` 不声称有硬预算。`run` 和 `reply` 必须设置有限的 `-MaxTurns`，并至少设置 `-ProviderBudgetCny` 或 `-MaxBudgetUsd`。一次公开搜索通常至少留 4 回合，覆盖工具发现、工具调用和最终回答。

DeepSeek 价格明显低于 Codex 稀缺额度时，只要任务能被清晰派单、结果可压缩且不涉及敏感审批，就默认优先交给 CC，不设机械的最低文件数或 token 门槛。约 3k tokens、2 个以上文件、2 组独立检索，或单个巨型/压缩/生成文件属于明确应委派场景；只有单个很短文件、约 1k tokens 内且一步可验收的小补丁通常由 Codex 直接做。止损看范围漂移、重复读取、无进展、返工和供应商人民币成本，不因 DS token 数看起来大而过早截断。

预算耗尽后不要丢弃已经付费的工作：保留 session 和 usage，分析是上下文、缓存、工具回合还是输出导致超支，再给同一 session 一次有依据的小额收尾预算，让它停止新工具并压缩交付；不要另开会话重读。

## 模型选择

检索、提取、格式化、冒烟和机械检查用 flash + low/medium。方案设计、复杂 debug、代码修改计划、兼容性判断、安全审查、架构决策和最终验收用 pro + high；只要判断失误会带来明显返工，就不要为了省一点模型费留在 flash。max 留给多约束高风险场景。

模型按错误代价和返工成本选择，不只看材料长度。高 effort 会消耗更多 thinking tokens；机械跟进不必延续上一阶段的 high/max 设置。常见交付时间可按 flash/low 20–60 秒、flash/medium 1–3 分钟、pro/high 3–8 分钟、pro/max 或多工具任务 5–15 分钟估计；到预计节点再查状态，权限请求和接近完成时例外。

CC 调用失败时要同时复盘模型、effort、上下文范围、工具轮次、预算和输出余量。机械读取因范围过大而超轮次，不要默认升级 Pro/max；先切片、压缩并续接原 session。`MaxTurns` 至少覆盖预计工具调用数并多留 2 个收尾回合，多文件搜证通常从 8–20 回合起估，测试阶段可按常规值的 1.5–2 倍放宽。用户明确授权的非敏感摘要、usage、错误日志片段和项目文件，可按精确工具名与路径临时放行 context-mode 读取/计算，但不扩展到凭据、全盘扫描、任意命令、写入或外发。同步原生 CLI 捕获可用 `-ProcessTimeoutSeconds` 设置 15–3600 秒的边界，默认 1800 秒；超时只请求终止本次启动的进程树，已经脱离的后代仍可能存活，重试前要检查进程和 provider 状态。

## 权限机制

`new-workforce-session-profile.ps1` 在员工启动时生成临时配置，MCP 和 Agent View 共享同一份。配置只在当前员工会话里有效，不碰 `~/.claude/settings.json`——你自己跑 `claude` 时的模型和权限完全不受影响。

**权限分四层：**

| 层级 | 含义 | 示例 |
|------|------|------|
| **tools** | 工具在运行时中存在，不代表已授权。 | `Read`、`Bash`、`Agent` 都存在。 |
| **allow** | 免审批预授权——工具来了直接用。 | `Read`、`Glob`、`Grep`、`WebSearch`、`Plan`。 |
| **ask** | 经 `canUseTool` 交 Codex 逐次审批。 | `Bash`、`Edit`、`Write`、`NotebookEdit`、`WebFetch`、`Agent`/`Task`。 |
| **deny** | 硬阻断——其他规则怎么配都不管用。 | 正常 profile 留空。真正不可接受的操作由 Codex 当场拒掉。 |

有一点容易搞混：敏感路径的 Read 规则（`.env`、`auth.json`、`settings.json`、私钥文件）放在 **ask** 里，优先级比宽泛的 `Read` **allow** 高。所以就算 `Read` 是预授权的，碰到这些文件还是会弹出确认。员工只在当前任务明确授权后才能读用户配置，读到密钥也不能回显或外发。

Bash、Edit、Write、NotebookEdit、每个 WebFetch 目标、Agent 和带副作用的 MCP 工具走权限中间层。公开 URL 和明确只读的 shell/Git 检查 Codex 可以直接批；写入、往外发数据、认证、安装、发布、部署——每次都得看具体请求是什么。

本 profile **不用** `bypassPermissions`、`acceptEdits`、`dontAsk`、`skip-permissions`，也没有任何形式的全工具自动批准。每次写入、shell 命令、网页抓取和子 Agent 启动都保持可审查。

MCP 调用不在顶层预填 `allowedTools` 或 `disallowedTools`。社区维护的 `claude-code-mcp` 用 `canUseTool` 把请求交给 `claude_code_check`，Codex 通过 `respond_permission` 逐条处理。批准只管当前这一次，不会变成长期权限。

Agent 默认走 ask。只有传了 `-AllowNestedAgents` 才会在当前员工会话里改成 allow——前提是任务确实能并行、范围清楚、账算得过来。

旧参数 `AllowBroadWebFetch` 还能读，兼容已有私有配置，但它不再帮你跳过 URL 审核。Claude Code 的 `auto` 模式这里也没用：官方要求 Anthropic API 加受支持的 Claude 模型，当前 DeepSeek provider 不满足。

`maxTurns` 当请求边界看就行，别当硬保证——实测中 SDK/provider 曾超过设置值。靠得住的止损信号是重复读取、范围漂移、没进展和供应商实际费用。

每个新建的持久员工都会在名称中带上 workforce profile 版本和来源指纹。指纹由启动时的仓库根、origin、分支和 commit 共同生成；`start` 只把本地脱敏后的来源字段返回给 Codex，发给 CC 的任务合同只有来源类型和不可逆指纹。`reply` 会重新计算，遇到没有版本标记的旧员工，或 fork、分支、commit 已变化时默认停止。核对日志和 Git 状态后，可以用 `-AllowLegacySession` 接回老员工，或用 `-AllowProvenanceDrift` 接受有意的来源变化。已经运行的进程不会自动继承后来安装的新 profile；权限模型升级后应新开员工。

## Windows 说明

原生 Windows 没有 Claude Code 的完整 OS 沙箱。session 规则和 MCP 审批只在工具层面约束，不会在 OS 层阻止文件读取或进程执行。别当沙箱用。

## 删除员工

```powershell
pwsh -NoProfile -File $workforce -Action remove -Id "<id>" `
  -ConfirmRemove -CheckedWorktree
```

`-ConfirmRemove` 表示你确认删除，`-CheckedWorktree` 表示你已经检查员工状态、日志和关联 worktree 中未提交或未合并的改动。两个参数缺一不可。只有终态（stopped、completed、failed、error、dead、cancelled、exited）才能删；还在运行的员工要先 stop。

## 项目结构

```
claude-workforce/
  SKILL.md                 # Codex skill 定义
  agents/openai.yaml       # OpenAI-compatible agent 定义
  scripts/
    claude-workforce.ps1   # 核心 wrapper
    new-workforce-session-profile.ps1 # 仅当前 MCP/员工会话使用的配置
Install.ps1                # 安装脚本
tests/
  Test-ClaudeWorkforce.ps1 # 解析检查 + 运行时权限探针
README.md                  # 英文说明
README.zh-CN.md            # 中文说明
SECURITY.md                # 安全策略
```

## 卸载

```powershell
$target = Join-Path $HOME '.codex\skills\claude-workforce'
if ((Split-Path -Leaf $target) -eq 'claude-workforce' -and (Test-Path -LiteralPath $target)) {
    Remove-Item -LiteralPath $target -Recurse -Force
}
```

安装器产生过备份的话（`~/.codex/backups/claude-workforce-<日期>`），可以直接恢复。
