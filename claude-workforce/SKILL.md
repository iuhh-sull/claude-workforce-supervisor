---
name: claude-workforce
description: 从 Codex 委派一次性 Claude Code 任务，管理官方 Agent View 后台 worker，恢复已有 session，并处理资源清理、状态迁移与连接恢复。
---

# Claude Workforce

用 PowerShell 7 wrapper 管理 Claude Code 委派。Codex 负责权限、敏感信息、发布边界和最终验收；CC 负责有边界的执行与初审。

## 前置检查

- 需要 PowerShell 7 和 Claude Code `2.1.208` 或更高版本；更旧版本不受支持。
- 开始前运行 `capabilities`；升级 Claude、provider、proxy、MCP 或 wrapper 后重新运行。
- 不读取、输出或提交用户级密钥配置。私有可执行文件路径和哈希只放在 `~/.codex/claude-workforce.local.psd1`。

```powershell
$workforce = Join-Path $HOME '.codex\skills\claude-workforce\scripts\claude-workforce.ps1'
pwsh -NoProfile -File $workforce -Action capabilities
```

## 选择入口

| 入口 | 用途 | 关键边界 |
|---|---|---|
| `run` | 一次性调研、提取、审查、计算或冒烟 | 同步；默认保留 session 便于恢复，确认可丢弃时用 `-Ephemeral` |
| `start` | 需要后台持续、稍后检查或人工 attach 的任务 | 使用官方 Agent View；后台 `--bg` 不支持逐次硬预算 |
| `reply` | 续接已有 session 的短增量任务 | 必须显式给 `-Model` 和 `-Effort`；按当前增量任务重新定档 |
| Claude Code MCP | 需要 Codex 逐次批准写入、Shell、WebFetch 或其他副作用 | 轮询 permission action，并按具体输入决定 |

不要为了形式上的后台化使用 `start`；可同步验收的任务优先 `run`。

## 上下文档位

- `minimal`：关闭 hooks、rules、skills、plugins、MCP、memory 和 CLAUDE.md。
- `user`：加载用户配置，不加载 MCP。
- `project`：加载用户与项目规则，不加载 MCP；普通项目任务默认。
- `full`：继承完整配置和 MCP；仅在任务确实需要时使用。
- `-NoTools` 始终强制 minimal safe mode，不能被 `TrustProfile` 或 `-AllowHooks` 弱化。

`EnableToolSearch` 只在当前 provider/proxy 的真实 MCP 调用探针通过后启用；单个 MCP 输出默认上限 10,000 tokens。

## TrustProfile 与 hooks

`-TrustProfile` 支持 `strict`、`balanced`、`delegated`，默认 `balanced`：

- `strict`：读、搜索和规划可用；项目写入、Shell、安装、网络与 nested agents 继续审批。
- `balanced`：允许当前工作树内写入及常见只读 Git/测试命令；高风险动作继续审批。
- `delegated`：在 balanced 基础上放行更多常见格式化、类型检查和静态检查；不放行发布、认证或任意 Shell。

所有档位默认 `disableAllHooks: true`。`-AllowHooks` 仅移除会话级禁用键，不覆盖更高优先级 managed 设置，也不代表 hooks 已审计。

敏感读取、工作树外写入、任意 WebFetch、本地数据外发、安装、认证、破坏性命令、commit、push、PR、发布和部署始终按具体输入审批。详见 `references/permissions.md`。

## 预算与回合

`-BudgetPolicy`：

- `none`：只报告 usage，不要求预算。
- `advisory`：默认；`-ProviderBudgetCny` 是运行后软阈值，不中断当前调用。
- `hard`：必须给正数 `-MaxBudgetUsd`；这是 Claude SDK 内部美元硬闸，不代表第三方 provider 账单。

`-MaxTurns 0` 表示 wrapper 不传 `--max-turns`；正数才传。为有工具任务设置正数时，要覆盖工具调用并至少留两个收尾回合。

限制命中后保留 partial output 和原 session；最多一次同 session、NoTools finalize，不创建替代 session，不重复读取或副作用。详见 `references/budget-and-timeouts.md`。

## 真实 timeout

- `StartupTimeoutSeconds`：进程启动到首个有效输出或握手。
- `IdleTimeoutSeconds`：启动后连续无输出或状态变化的时长。
- `HardTimeoutSeconds`：绝对墙钟；`0` 表示禁用。
- `ProcessTimeoutSeconds` 仅为兼容别名，不是第四种独立 timeout。
- MCP startup/idle/tool timeout 与整个 Claude 进程 timeout 分开报告。

超时后保存部分 stdout/stderr，尝试同 session 收尾，清理可信 owned resources，并保留 session 供恢复。

## 常用调用

```powershell
pwsh -NoProfile -File $workforce -Action run -Mode inspect -NoTools -Ephemeral `
  -ContextProfile minimal -BudgetPolicy advisory -MaxTurns 2 -ProviderBudgetCny 0.05 `
  -Model 'deepseek-v4-flash[1m]' -Effort low -Cwd '<project>' -Prompt '<task>'

pwsh -NoProfile -File $workforce -Action start -Mode inspect -ContextProfile project `
  -TrustProfile balanced -Model '<model>' -Effort medium -Role researcher `
  -Cwd '<project>' -Prompt '<bounded task>'

pwsh -NoProfile -File $workforce -Action reply -Id '<worker-id>' -Mode inspect `
  -ContextProfile project -BudgetPolicy advisory -MaxTurns 4 `
  -Model '<model>' -Effort high -Prompt '<incremental task>'
```

模型按错误与返工成本路由：机械检索/提取/冒烟用 fast + low/medium；复杂诊断、架构、安全和最终验收用高能力模型 + high；max 只用于 high 明显不足的多约束高风险任务。

## 状态与资源信任边界

- schema-v2 Manifest 是唯一权威状态，由 supervisor 在锁和 revision CAS 下写入。
- worker 只能写 `worker-reports/`；report 是不可信审计输入，不能创建可信进程、端口、MCP 或改变 ownership。
- 资源必须通过 broker capability token 注册；落盘记录由本机 broker key 做 HMAC。
- token 不得打印、写入 prompt、worker report、日志或 Manifest。
- force cleanup 必须验证 broker signature、session/manifest、PID、启动时间、可执行文件、后代关系和端口 listener PID；无法证明即失败关闭。

注册资源是 worker 内部协议。操作者不要手工伪造 `register-process`、`register-port`、`register-mcp` 或 `unregister-resource`。

## 生命周期与验收

每次 dispatch 前先 reconcile/reaper，阻止重复任务、circuit-open dispatch 和 `cleanup-incomplete` 冲突。默认 `ResourcePolicy=retain-session`、`SessionRetentionPolicy=stop-on-complete`：保留可恢复 session，但完成后释放临时进程与端口。

```powershell
pwsh -NoProfile -File $workforce -Action list -All
pwsh -NoProfile -File $workforce -Action logs -Id '<worker-id>'
pwsh -NoProfile -File $workforce -Action reconcile -Cwd '<project>' -Role worker -Prompt '<task>'
pwsh -NoProfile -File $workforce -Action doctor -Cwd '<project>'
pwsh -NoProfile -File $workforce -Action reap
pwsh -NoProfile -File $workforce -Action stop -Id '<worker-id>'
pwsh -NoProfile -File $workforce -Action daemon-restart-keep-workers
```

不要只看模型文本。至少核对 worker/session ID、Manifest 状态、`cleanup_status`、remaining process/port、retry/finalize、circuit、roster 和来源指纹。`cleanup-incomplete` 会阻止冲突 dispatch，直到可信 cleanup 完成或人工核验。

## 迁移、恢复与删除

旧状态先迁移并保留自动 backup；rollback 只接受 workforce backup 根内的路径：

```powershell
pwsh -NoProfile -File $workforce -Action migrate
pwsh -NoProfile -File $workforce -Action rollback-migration -MigrationBackupPath '<backup>'
```

可重试 provider 错误最多一次原 session resume。认证、invalid model、TLS、DNS 配置和 unsupported endpoint 不自动重试。恢复时优先原 session；不要另开会话重读已付费材料。

`attach` 使用 canonical worker ID。`remove` 仅允许明确终态，并要求 `-ConfirmRemove -CheckedWorktree`；先检查日志、Manifest、cleanup 和 Git worktree。

## 安全边界

- 本项目是工具/会话权限层，不是 OS sandbox；原生 Windows 不提供完整文件系统或进程隔离。
- 不自动 commit、push、开 PR、发布、部署、删除 worktree 或访问凭据。
- worker 名称包含 profile 版本和 Git 来源指纹；来源漂移或旧无版本 session 默认停止，人工核验后才可显式放行。
- `AllowBroadWebFetch` 只兼容旧输入，不授予权限。
- 真机 host integration 只允许显式 opt-in 的自托管 Windows runner；会联网、写入 `~/.claude`、创建真实 worker，并可能产生费用。

## References

- `references/permissions.md`：TrustProfile、hooks、nested agents 与高风险审批。
- `references/budget-and-timeouts.md`：费率新鲜度、BudgetPolicy、MaxTurns、真实 timeout。
- `references/resource-lifecycle.md`：Manifest、worker report、broker、reaper、cleanup。
- `references/operations.md`：doctor、migration、rollback、reaper、stop/remove。
- `references/connectivity.md`：API/MCP circuit、重试与连接恢复。
- `references/port-management.md`：listener PID、lease 与端口释放。
- `references/invocation-levels.md`：并发与降级。
- `references/troubleshooting.md`：失败分类和排障。
- `references/portability.md`、`references/deepseek-provider.md`：平台/provider 扩展。
