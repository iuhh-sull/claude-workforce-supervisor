# Claude Workforce

> 非官方项目。[English](./README.md)

Claude Workforce 让 Codex 通过官方 `claude agents` supervisor 管理 Claude Code 后台员工。Codex 负责派活、查状态、看日志和验收；任务中断后，还能通过 supervisor 接回原来的对话。

这是一个围绕官方 `agents` 子命令编写的非官方 Codex skill，适合调研、代码审查和分阶段执行的后台任务。

> 状态：beta。状态、broker、迁移、timeout 与权限架构已有确定性测试覆盖，但真实主机行为仍取决于本机 Claude Code/provider 链路。发布前应运行手动 opt-in 的 host integration，不能把单元测试等同于生产就绪。

前置条件：Windows、PowerShell 7、Claude Code `2.1.208` 或更高版本。即使部分能力探针通过，旧版本也会被拒绝。

## 安装

```powershell
pwsh -NoProfile -File Install.ps1
```

首次安装不加 `-Force`。升级或替换已有安装时才加 `-Force`，安装器会先备份旧 skill 目录。安装还会幂等迁移 schema-v2 状态；需要迁移时另建状态备份，并返回 `rollback_command`。只有准备单独审查迁移时才用 `-SkipStateMigration`；安装器不会复制覆盖 workforce 状态根。

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

一次性任务优先用 `run`。`-BudgetPolicy` 可选 `none`、`advisory`（默认）或 `hard`。正数 `-MaxTurns` 是请求的回合边界；`-MaxTurns 0` 会完全省略 `--max-turns`：

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

`auto`：无工具任务自动选用 `minimal`，其他任务自动选用 `project`；`reply` 也使用这个默认逻辑。`minimal` 关闭 rules、skills、plugins、MCP、memory 和 CLAUDE.md；`user` 只加载用户级配置但不加载 MCP；`project` 加载用户和项目规则但不加载 MCP；`full` 才继承全部配置和 MCP。所有档位默认禁用 hooks；`-AllowHooks` 只移除会话级禁用键，且永远不能弱化 `-NoTools`。

完整工具环境可能在第一句话之前就注入数万 tokens。只有任务确实需要 MCP 时才用 `full`。自定义 `ANTHROPIC_BASE_URL` 下，Claude Code 默认可能不启用 Tool Search；`EnableToolSearch = $true` 必须经过真实 MCP 调用验证后再设。wrapper 还把单个 MCP 输出默认限制在 10,000 tokens。

评估是否省额度时，不能把 Codex/GPT 和 DeepSeek/CC 的 token 或费用相加。先算 CC 避免了多少 Codex 上下文，再扣掉派单、轮询、定点复核和返工；DeepSeek 费用单独报告。CC 返回后，Codex 默认只核对它标出的路径、行号、URL、diff 和失败点，不再通读同一批材料。若最终仍需完整重读，这次调用属于交叉审查，不算节省 Codex 额度。

自定义 DeepSeek 端点下，Claude Agent SDK 的 `total_cost_usd` 可能按 Anthropic 模型价目估算，不能当成供应商账单，wrapper 默认不会输出它；只有诊断兼容层时才加 `-IncludeSdkCostEstimate`。常规结果根据本次模型、`usage` 和已审计的 DeepSeek 价格返回 `provider_billing_tokens`（缓存未命中/缓存命中/输出三类 token）、`provider_cost_components_cny`（三项费用）和合计 `provider_cost_estimate_cny`。这是本地 decimal 计算，不会让 CC 重读任务。usage 不完整时会明确标记证据不足，不猜费用。

`BudgetPolicy none` 只报告 usage，不做预算判断。`advisory` 可在调用结束后按新鲜的已审计费率比较 `-ProviderBudgetCny`，但不会中断当前调用。`hard` 必须给 `-MaxBudgetUsd` 并传入 SDK 内部硬闸；自定义 provider 下它不是供应商账单。官方后台 `--bg` 不支持逐次硬预算，所以 `start` 不声称有硬上限。未知或过期费率只能返回 unavailable/indeterminate，不能猜费用。

每次续接任务时，`reply` 还必须显式传入 `-Model` 和 `-Effort`。原生 print-mode 回复只支持检查模式；续接任务需要交互式写权限时，应走 Claude Code MCP。`start` 启动后会查询 supervisor roster，并返回 `roster_verified`、`roster_state`、`roster_cwd_match` 和 `roster_session_id`；查询失败会明确报告，不会伪装成已验证。

DeepSeek 价格明显低于 Codex 稀缺额度时，只要任务能被清晰派单、结果可压缩且不涉及敏感审批，就默认优先交给 CC，不设机械的最低文件数或 token 门槛。约 3k tokens、2 个以上文件、2 组独立检索，或单个巨型/压缩/生成文件属于明确应委派场景；只有单个很短文件、约 1k tokens 内且一步可验收的小补丁通常由 Codex 直接做。止损看范围漂移、重复读取、无进展、返工和供应商人民币成本，不因 DS token 数看起来大而过早截断。

预算耗尽后不要丢弃已经付费的工作：保留 session 和 usage，分析是上下文、缓存、工具回合还是输出导致超支，再给同一 session 一次有依据的小额收尾预算，让它停止新工具并压缩交付；不要另开会话重读。

缓存复用是优化项，不是禁止并行的理由。同一目标的增量任务优先续接既有首席/session；没有功能需要时，尽量保持 context profile、tool catalog 和 skill 集合稳定。统计时要把 fresh 与 resumed 分开：自定义 DeepSeek 端点可能始终不填 `cache_creation_input_tokens`，此时基于 cache creation 的复用率没有意义，应报告 cache-read 占比并注明口径限制。

## 模型选择

检索、提取、格式化、冒烟和机械检查用 flash + low/medium。方案设计、复杂 debug、代码修改计划、兼容性判断、安全审查、架构决策和最终验收用 pro + high；只要判断失误会带来明显返工，就不要为了省一点模型费留在 flash。max 留给多约束高风险场景。

模型按错误代价和返工成本选择，不只看材料长度。高 effort 会消耗更多 thinking tokens；机械跟进不必延续上一阶段的 high/max 设置。常见交付时间可按 flash/low 20–60 秒、flash/medium 1–3 分钟、pro/high 3–8 分钟、pro/max 或多工具任务 5–15 分钟估计；到预计节点再查状态，权限请求和接近完成时例外。

CC 调用失败时要同时复盘模型、effort、上下文范围、工具轮次、预算和输出余量。机械读取因范围过大而超轮次，不要默认升级 Pro/max；先切片、压缩并续接原 session。正数 `MaxTurns` 至少覆盖预计工具调用数并多留 2 个收尾回合。`StartupTimeoutSeconds` 管启动到首个有效输出，`IdleTimeoutSeconds` 管启动后的连续无活动，`HardTimeoutSeconds` 是绝对墙钟（`0` 禁用）；`ProcessTimeoutSeconds` 只是兼容别名。timeout 会保存部分 stdout/stderr、尝试一次同 session 无工具收尾，并执行 broker 验证的清理。

## 权限机制

`new-workforce-session-profile.ps1` 在员工启动时生成临时配置，MCP 和 Agent View 共享同一份。配置只在当前员工会话里有效，不碰 `~/.claude/settings.json`。

`-TrustProfile` 支持 `strict`、`balanced`（默认）和 `delegated`。strict 让项目写入与常见命令继续审批；balanced 放行当前工作树写入以及有界的只读 Git/测试命令；delegated 再放行常见 formatter、类型检查和静态检查。三档都不宽泛放行任意 Shell、敏感读取、WebFetch、本地数据外发、安装、认证、破坏性命令、commit、push、发布或部署。

所有档位默认生成 `disableAllHooks: true`。`-AllowHooks` 只移除当前会话的禁用键，不代表继承 hook 已安全，也不覆盖 managed 设置；`-NoTools` 始终禁用 hooks 和工具。敏感路径读取、工作树外写入、WebFetch、Agent/Task 和带副作用 MCP 仍按具体输入审批；本项目不用 bypass/skip-permission 模式。

MCP 调用不在顶层预填 `allowedTools` 或 `disallowedTools`。`xihuai18/claude-code-mcp`（npm: `@leo000001/claude-code-mcp`）通过 `claude_code` 管理会话，用 `claude_code_check`（支持 `poll` 和 `respond_permission` action）把未处理的权限请求交给 Codex 逐条审查。兼容性由 Codex 运行时 MCP catalog 和真实权限探针验证；本公共项目不安装或绑定 MCP 版本。批准只管当前这一次，不会变成长期权限。

Agent 默认走 ask。只有传了 `-AllowNestedAgents` 才会在当前员工会话里改成 allow——前提是任务确实能并行、范围清楚、账算得过来。

旧参数 `AllowBroadWebFetch` 还能读，兼容已有私有配置，但它不再帮你跳过 URL 审核。Claude Code 的 `auto` 模式这里也没用：官方要求 Anthropic API 加受支持的 Claude 模型，当前 DeepSeek provider 不满足。

`maxTurns` 当请求边界看就行，别当硬保证——实测中 SDK/provider 曾超过设置值。靠得住的止损信号是重复读取、范围漂移、没进展和供应商实际费用。

每个新建的持久员工都会在名称中带上 workforce profile 版本和来源指纹。指纹由启动时的仓库根、origin、分支和 commit 共同生成；`start` 只把本地脱敏后的来源字段返回给 Codex，发给 CC 的任务合同只有来源类型和不可逆指纹。`reply` 会重新计算，遇到没有版本标记的旧员工，或 fork、分支、commit 已变化时默认停止。核对日志和 Git 状态后，可以用 `-AllowLegacySession` 接回老员工，或用 `-AllowProvenanceDrift` 接受有意的来源变化。已经运行的进程不会自动继承后来安装的新 profile；权限模型升级后应新开员工。

## 资源生命周期与连接恢复

schema-v2 Manifest 是唯一权威生命周期状态，只能由 supervisor 在 mutex、原子替换、backup、revision CAS 与状态迁移检查下写入。worker report 只是非可信审计输入，不能注册资源或改变 ownership。进程、端口与 MCP 只有经 capability-token broker 注册后才可信；落盘资源和 lease 使用 HMAC，token 不持久化也不输出。

每次 dispatch 前都会先执行 reaper/reconcile。reaper 幂等收敛终态/陈旧 worker，并重试符合条件的 cleanup；reconcile 阻止重复任务、损坏状态和 `cleanup-incomplete` 冲突，检查 provider/model 熔断状态，并应用软并发上限：

| 档位 | 稳定 active | Burst | Nested agents |
|---|---:|---:|---:|
| low | 2 | 3 | 0 |
| medium | 4 | 6 | 2 |
| high | 6 | 10 | 4 |

默认是 `retain-session` + `stop-on-complete`：transcript 和 session metadata 可续接，但临时进程和端口必须释放。`-ResourcePolicy` 支持 `cleanup`、`retain-session`、`keep-resources`；`-SessionRetentionPolicy` 支持 `stop-on-complete`、`remove-on-complete`、`idle-ttl`、`manual`。自动删除仅在 Agent View worker 已验证终态且 Git worktree 已验证干净时执行，否则失败关闭。print-mode `run` 会为 same-session 恢复保留 session；若 transcript 可丢弃，请使用 `-Ephemeral`。

```powershell
pwsh -NoProfile -File $workforce -Action reconcile -Cwd $project -Role researcher -Prompt '<任务>'
pwsh -NoProfile -File $workforce -Action resources
pwsh -NoProfile -File $workforce -Action ports
pwsh -NoProfile -File $workforce -Action doctor -Cwd $project
pwsh -NoProfile -File $workforce -Action reap
pwsh -NoProfile -File $workforce -Action migrate
pwsh -NoProfile -File $workforce -Action daemon-restart-keep-workers
pwsh -NoProfile -File $workforce -Action stop -Id '<worker-id>' -GracefulShutdownSeconds 10 -PortReleaseTimeoutSeconds 15
```

可重试 provider 错误最多进行一次同 session 恢复，并保留 partial output。认证、模型、TLS 校验、DNS 配置和不支持的 endpoint 错误不会自动重试。circuit open 时冻结新 dispatch。清理不会信 worker report，也不会按进程名/端口号杀：force cleanup 必须同时验证 broker HMAC、安全的 key ACL、Manifest/session、PID/启动时间/可执行文件/后代关系和 listener PID；任一证据失败都保留 `cleanup-incomplete`。

状态默认位于 `~/.codex/claude-workforce/`。每次 lifecycle 结果都包含 `cleanup_status`、owned process/port 数、retry/finalize 和复用决策。旧状态迁移会创建 rollback backup；`doctor` 会报告 migration、state lock/corruption、broker key/ACL、stale/cleanup、端口、费率和环境漂移。详细说明见 `claude-workforce/references/`。

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
    workforce-lifecycle.ps1 # 权威 Manifest 状态机
    workforce-state.ps1    # Mutex、原子 JSON、backup、CAS
    workforce-resource-broker.ps1 # capability/HMAC 资源 broker
    workforce-reaper.ps1   # 终态/陈旧任务 Postflight 收敛
    workforce-timeouts.ps1 # startup/idle/hard 进程监控
  config/provider-pricing.psd1 # 已审计 provider 费率
  references/              # 权限、预算/超时、生命周期、恢复、运维
Install.ps1                # 安装脚本
tests/
  Test-ClaudeWorkforce.ps1 # 可移植 fake-runtime 套件
  Test-WorkforceRemediation.ps1 # 并发/安全/timeout 回归
  helpers/                 # 确定性进程/状态夹具
.github/workflows/
  test.yml                 # Windows unit/remediation CI
  host-integration.yml     # 手动 opt-in 真实主机 CI
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
