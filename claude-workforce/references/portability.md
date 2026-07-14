# Portability Reference

> 记录 claude-workforce 的跨 provider、跨 OS、跨项目扩展点和本地化适配清单。核心 skill (SKILL.md) 保持 provider-neutral。

## 添加新 Provider

1. **模型 ID 映射**：确保 provider 的 Anthropic 兼容端点接受对应的 model ID 字符串。wrapper 脚本现在接受任意合法 model ID（`[ValidatePattern]`），不再硬限制模型列表。
2. **Effort/thinking 控制**：验证 provider 后端对 `low`/`medium`/`high`/`xhigh`/`max` 的实际推理行为。`xhigh` 及以上语义因 provider 而异，需实测。
3. **Usage 字段提取**：wrapper 使用 Claude Code SDK 的 `input_tokens`、`cache_creation_input_tokens`、`cache_read_input_tokens`、`output_tokens`。确认你的 provider 兼容层是否填充 `cache_creation_input_tokens`。
4. **费率配置**：在 `scripts/claude-workforce.ps1` 的 `Get-ProviderPricing` 函数中添加经过审计的 switch case。未知模型返回 null/unavailable；只使用 provider 软阈值时会拒绝未定价模型，除非调用者显式给出 `-AllowUnpricedModel`，或改用 SDK 的 `-MaxBudgetUsd` 硬闸。
5. **币种**：`provider_cost_currency` 输出字段自动跟随费率配置中的 `currency` 值。wrapper 同时输出 `-ProviderBudgetCny`（旧名）和 `-ProviderBudget`（通用名）。

当前内置费率适配器：DeepSeek V4 Flash/Pro（`references/deepseek-provider.md`）。

## 跨 OS

- **安装**：`Install.ps1` 需要 PowerShell 7（Windows/Linux/macOS 均可用）。目标目录默认 `~/.codex/skills/claude-workforce`；若无 `.codex` 则手动指定 `-Destination`。
- **进程管理**：wrapper 使用 `[Diagnostics.ProcessStartInfo]` 统一管理子进程，设计上支持 Windows、Linux 和 macOS 的 stdout/stderr 重定向、超时终止和环境变量注入。当前 CI 只覆盖 Windows；Linux/macOS 仍需在对应 runner 上实测后才能视为已验证支持。
- **路径**：`Join-Path` 和 `[IO.Path]::Combine` 使用 OS 原生分隔符。所有公开文档示例改用多参数 `Join-Path` 避免硬编码反斜杠。
- **沙箱**：Windows 无 OS 级沙箱；Linux 上 Claude Code 使用 bubblewrap（若可用）；macOS 使用 Seatbelt。session 权限规则和 MCP 审批是工具层约束，不替代 OS 沙箱。
- **POSIX 本地 Git remote**：`Get-SafeGitRemote` 脱敏 Windows 盘符路径和 POSIX 绝对路径（`/home/...`）。

## Namespace / 多租户

worker 命名前缀的解析顺序：

1. `$env:WORKFORCE_NAMESPACE`（显式设定）
2. `$env:CODEX_THREAD_ID`（Codex 自动注入）
3. `$env:CLAUDE_CODE_SESSION_ID`（独立 Claude Code 会话）
4. `cx-manual`（fallback）

也可通过 `-Namespace <string>` 参数覆盖。非 Codex 环境下设 `WORKFORCE_NAMESPACE` 即可做跨任务隔离。

## MCP 工具名自定义

工作区 session profile (`new-workforce-session-profile.ps1`) 默认只包含内置工具权限规则。如需为特定 MCP 服务（如 Tavily、Exa、自定义搜索）预授权或纳入 ask，用当前进程的环境变量注入精确工具名：

```powershell
$env:WORKFORCE_MCP_ALLOW_TOOLS = 'mcp__tavily__tavily_search'
$env:WORKFORCE_MCP_ASK_TOOLS = 'mcp__tavily__tavily_crawl'
```

未列出的 MCP 工具遵循 `full` context profile 下的默认权限（由 Codex supervisor 逐次审批）或 `strict-mcp-config` 下的禁用规则。环境变量只对当前进程树生效，不写入用户日常 Claude Code 配置。

## 本地运营政策

以下决策属于部署者运营选择，不写入公共 SKILL.md：

- 默认模型 ID（可用当前进程的 `WORKFORCE_DEFAULT_MODEL` 设置；未设置时交给 Claude Code/provider 自身选择）
- 是否允许 Anthropic 官方模型（wrapper 本身不禁止任何合法 model ID）
- 预算默认值（`MaxTurns` 起点、`ProcessTimeoutSeconds`、`LogTailChars`）
- `EnableToolSearch` 是否启用（需先通过真实 MCP 探针验证）
- 是否固定 Claude 可执行文件哈希（`ExpectedClaudeSha256`）

这些配置通过 `~/.codex/claude-workforce.local.psd1` 或环境变量设置，不进入公开仓库。

## 相关文件

- 核心 skill: `SKILL.md`
- Provider 参考: `references/deepseek-provider.md`
- 权限 profile: `scripts/new-workforce-session-profile.ps1`
- 核心 wrapper: `scripts/claude-workforce.ps1`
