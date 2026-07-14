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

根据任务选择入口：

| 入口 | 适用场景 | 成本边界 |
|------|----------|----------|
| `run` | 一次性调研、提取、文本或数字判断 | `-p` 同步执行；必须给 `-MaxTurns`，并给 DeepSeek 软阈值 `-ProviderBudgetCny` 或可选 SDK 硬闸 `-MaxBudgetUsd`；默认保存 session |
| `start` | 需要后台运行、长期保留并可随时接回的员工 | 官方 `--bg` 不支持硬预算；靠阶段化派单、状态监控和 stop 止损 |
| `reply` | 给既有员工追加短增量任务 | 通过 `-p --resume`；预算参数与 `run` 相同，并返回 subtype、usage 和 DeepSeek CNY 估算 |

只有 `run -NoTools -Ephemeral` 才禁用 session persistence，且只适合可丢弃的冒烟/连通性检查。普通 `run` 不使用 `--no-session-persistence`，避免预算或回合错误后无法取回已有工作。

官方 supervisor 会写入 `~/.claude/daemon` 和 `~/.claude/jobs`。Codex sandbox 拒绝这些写入时，直接为这个固定脚本请求沙箱外批准；不要换 shell 或绕过权限。

## 权限模型

**核心理念：Codex 可以授权 CC；未被当前 workforce profile 预授权的动作通过 MCP 中间层交给 Codex 判断。** 正常任务不通过 `--tools` 删除工具；`-NoTools` 只用于可丢弃的无工具冒烟。

权限按能力、数据敏感度、目标和副作用分级，不做全 deny 或全 allow。公开只读检索可预授权，只读用户配置需脱敏；写入、外发、认证、安装、发布和破坏性操作按当前具体请求审批。只有无法安全约束或明确不可接受的动作才进入 deny。

本技能的模型、Effort、联网和权限规则由 `new-workforce-session-profile.ps1` 临时生成，只作用于 Codex 派出的 MCP/Agent View 会话，不改动用户日常直接运行 `claude` 时的默认模型或权限。员工可以只读并遵循用户全局配置，但不得在没有当前任务明确授权时修改；即使读取到敏感值，也不得回显或外发。

**权限模式：**

| Mode | `--permission-mode` | 含义 |
|------|---------------------|------|
| `inspect` | `plan` | 只读为主；编辑操作需请求 |
| `write` | `default` | 可提议编辑；每次编辑都需请求授权 |

> ⚠️ `write` 模式不使用 `acceptEdits` / `auto` / `dontAsk` / `bypassPermissions`。当前 DeepSeek 自定义 provider 也不满足官方 `auto` 模式的适用条件。

**临时 `--settings` 与 MCP 中间层：**

- **allow**：Read、Glob、Grep、WebSearch、Plan/EnterPlanMode/ExitPlanMode，以及精确命名的公开搜索 MCP。Plan 是工作方式，不是风险动作。**注意**：allow 是免审批预授权（工具存在且本次直接放行），与工具的单纯存在（tools）不同。
- **ask**：Bash、Edit、Write、NotebookEdit、WebFetch、Agent/Task、任意 URL 抓取和 context execute MCP；`.env`、认证配置、私钥、Codex/Claude settings 等敏感 Read 规则也放在 ask 中，优先于宽泛 Read allow。**注意**：ask 通过 `canUseTool` 向 Codex 逐次审批；宽泛 Read 虽在 allow，但敏感路径 Read 规则在 ask 中且优先级更高，因此仍会触发审批。
- **deny**：正常 profile 保持空。**注意**：deny 是硬阻断，被 deny 的工具即使 ask/allow 规则匹配也无法使用。任务可能需要的能力不做永久封死；真正不可接受的具体请求由 Codex 拒绝。
- **MCP 顶层工具表**：`allowedTools=[]`、`disallowedTools=[]`、`strictAllowedTools=false`，复用社区维护的 `claude-code-mcp` 的 `canUseTool`、`claude_code_check`、`respond_permission` 流程，不自制 shell/URL 权限解析器。Codex 可直接批准公开 URL、只读 Git/目录检查等低风险请求；写入、敏感读取、本地数据外发、认证、安装、发布和部署按具体输入审批。
- **Agent**：默认 ask；显式 `-AllowNestedAgents` 时只在当前员工会话改为 allow。是否开启取决于任务能否独立并行以及总成本，而不是一律禁止。
- **兼容键**：`AllowBroadWebFetch` 仍可被旧私有配置解析，但不再改变权限。公共 WebFetch 可由 MCP 主管快速批准，回环、私网、带凭据或可能外发本地数据的目标继续拦截。

Claude Code 官方权限文档说明：匹配的 ask/deny 规则仍优先于 hook allow；本项目因此不叠加自制 PreToolUse/PermissionRequest hook。CC、wrapper 或 MCP 更新后要重跑真实权限探针，确认没有静默预批准。

**Effort levels**: Claude Code CLI 接受 `low`、`medium`、`high`、`xhigh`、`max`。官方 Agent SDK `EffortLevel` 定义包含全部五档，参见 [`claude-agent-sdk-python/types.py`](https://raw.githubusercontent.com/anthropics/claude-agent-sdk-python/refs/heads/main/src/claude_agent_sdk/types.py)——该文档仅作为 Claude Code 客户端接受这些 effort 值的证据。workforce wrapper 的 `-Effort` 参数接受全部五档，这是客户端参数兼容。**本项目实际使用的模型始终是 `deepseek-v4-flash[1m]` / `deepseek-v4-pro[1m]` 自定义 provider**；DeepSeek 后端对 `xhigh` 的实际推理语义尚未经过本地兼容探针验证，需要当前 provider/proxy 环境下实测确认。不得因此切换或调用 Anthropic 官方 Claude 模型。

**Adding a new provider**: requires adapting model ID mapping, effort/thinking controls, usage-field extraction, and provider-specific cost calculation. Audit the provider's current token rates and billing fields before enabling `-ProviderBudgetCny` estimation.

**工具可用性：**

- 正常模式（`inspect` / `write`）：**不传 `--tools`**——员工拥有 Claude Code 完整内置工具集。工具权限由 session settings、permission mode 和 MCP 的逐次审批共同决定。
- `-NoTools`：仅 `inspect` 模式可用。传 `--tools ''` + `--disable-slash-commands` + `--strict-mcp-config`，完全移除内置工具、slash commands 和 MCP。

**MCP 继承：**

- `minimal`、`user`、`project` 都使用 `--strict-mcp-config`，默认不继承 MCP；`full` 才继承当前配置的 MCP。
- `full` 中的公开搜索 MCP 使用精确工具名默认放行；任意 URL 抓取、浏览器点击/填表/上传、认证会话、远端写入以及其他可能外发本地数据或产生副作用的 MCP 不在默认 allow 中，仍逐项响应权限请求。
- `-NoTools` 额外移除内置工具和 slash commands，并强制 `--strict-mcp-config`；即使显式选择 `full` 也不会启用 MCP 或 Tool Search。

## 派单

### 调用门槛

调用前先估算净收益，比较 Codex 直接完成与“CC 执行 + MCP/worker 轮询 + Codex 复核 + 可能返工”的总成本。DeepSeek 实际价格显著低于 Codex 稀缺额度时，只要任务边界清楚、结果可压缩且不涉及敏感审批，就默认优先调用 CC；下列是明确应委派场景，不是最低门槛：

跨模型评估必须分账：节省 Codex/GPT 配额是主指标，DeepSeek/CC tokens 和费用是独立副指标，不能直接相加。净节省只计算“CC 避免的 Codex 输入、输出和工具回灌”减去“Codex 派单、轮询、定点复核和返工”；若 Codex 最后仍通读同一批大材料，该调用只能记为质量交叉审查，不能记为节省额度。

CC 自己产生的 usage、session、进程状态与日志元数据，优先让 DeepSeek 在原会话或原进程侧完成提取、归并、简单计算和状态判断，Codex 只接收小型结构化结果，不再读取完整 transcript。若同一工作可由本地确定性脚本直接完成，则先用脚本，避免额外模型调用；仅当数据依赖 CC 上下文或进程内部状态时才交给 DS。费用结果至少包含模型、三类计费 token、费率版本、分项费用和合计，便于 Codex 定点复核。

第三方或自定义模型经 Claude Code/MCP 运行时，`totalCostUsd` 只视为兼容层的美元估算，不能当作供应商实际扣费，也不能与人民币账单直接比较。wrapper 默认不返回该字段；只有诊断兼容层时才显式加 `-IncludeSdkCostEstimate`，此时仍须把币种和“非供应商账单”说明一并保留。实际账单以供应商控制台或发票为准。若返回值精确命中某个 Claude 官方价格公式，只能说明 Claude Code/SDK 套用了内置价目，不能说明第三方发生该笔扣款。

wrapper 已为两个 DeepSeek V4 模型加入确定性 CNY 估算：缓存未命中使用 `input_tokens + cache_creation_input_tokens`，缓存命中使用 `cache_read_input_tokens`，再加 `output_tokens`；根据本次 `Model` 选择 Flash 或 Pro 的已审计费率。结果会返回 `provider_billing_tokens` 三类 token、`provider_cost_components_cny` 三项费用和合计 `provider_cost_estimate_cny`。模型只返回原始 usage，归并和 decimal 乘法由本地 PowerShell 完成，不需要 CC 重读内容或再次推理。DeepSeek 控制台或发票仍是最终依据；usage 不完整时返回 null，不补猜，未知模型直接拒绝估价。

`-ProviderBudgetCny` 是调用结束后核验的软阈值，不会中途终止进程。`-MaxBudgetUsd` 仍按 Claude Code 的内置美元估值触发，只是可选的 SDK 硬闸；在自定义 DeepSeek provider 下不代表实际美元消费。默认优先使用 `MaxTurns`、严格工具/读取范围、输出上限和 `ProviderBudgetCny`，避免错误 Opus 价在最终交付前截断；确需纵深止损时才另外给足够宽的 `MaxBudgetUsd`。

- 需要处理约 3k tokens 以上原始材料，CC 可以只返回 1k-2k tokens 的证据摘要。
- 涉及两个以上文件的检索、分类、机械审查或一致性修改。
- 需要在单个巨大、压缩或生成文件中定向搜索，或要完成两个以上彼此独立的只读检索，Codex 只需接收证据索引。
- 需要生成长文初稿、跨来源摘要、批量文本、重复性代码或测试样板，并能让 CC 直接落盘后只回报 diff 和验证结果。
- 工作会产生大量搜索、日志、测试或文件读取输出，但 Codex 主对话只需要带路径/行号/URL的结构化摘要。
- 需要隔离主对话假设的独立代码审查、提交前验证或第二意见，并能用测试或定点证据验收。
- 多个子任务彼此独立、不会同时修改同一文件，也不需要代理之间持续协调。
- 已有持久会话包含可复用上下文，续接的增量成本明显低于 Codex 重新读取。

以下任务默认由 Codex 直接处理，不调用 CC：

- 单个很短文件、约 1k tokens 以内相关上下文、一步可验收且派单与复核明显更贵的小补丁；巨大/压缩/生成文件不按文件数豁免。
- 全局配置、权限策略、密钥边界、发布、提交、推送、部署和其他高风险或外部副作用操作。
- CC 的产物仍需 Codex 逐行重做、无法压缩返回，或预计轮询与复核成本不低于直接完成。
- 需要频繁来回澄清、多个阶段共享大量上下文、步骤强顺序依赖，或多个员工会同时修改同一文件。
- 子任务必须互相通信、协商或共享不断变化的状态；普通 subagent/worker 只适合清晰 handoff，不适合隐式协同。
- 任务边界尚未明确，或关键选择会实质改变结果。先由 Codex 澄清或收敛范围。

这些数量是默认路由线，不是机械门槛。DeepSeek 单价显著低于 Codex 稀缺额度时，应优先委派可压缩返回的低敏执行工作；用户明确要求调用 CC 时优先寻找合适子任务。仍须使用边界明确的范围、足以完成交付的有限预算和完整提示词合同；止损依据是范围漂移、重复读取、无进展、不可压缩返工和真实供应商费用，而不是孤立的 DS token 数。

CC 返回后，Codex 默认只读它给出的证据索引、命中行、最终 diff、测试失败点和不确定项，不再通读原始材料。只有安全/权限/密钥/发布、证据冲突、测试失败或定点抽样发现错误时，才扩大到相关局部；必须记录扩大读取的触发原因。高风险验收需要检查原始 diff，不等于重读 CC 已扫描的全部仓库或资料。

上述边界参考 Anthropic 的 [subagent 使用指南](https://claude.com/blog/subagents-in-claude-code) 与 [官方 subagent 文档](https://code.claude.com/docs/en/sub-agents)。社区问题只作为风险信号：官方仓库已有[跨会话重复工作报告](https://github.com/anthropics/claude-code/issues/39961)和[未读取源文件便生成结论的报告](https://github.com/anthropics/claude-code/issues/44317)，因此不能把员工自报当验收，也不能用未经核验的社区数字承诺节省比例。

根据任务选择模式：

- 调研、诊断、审查、制定方案：`-Mode inspect`（`plan` 权限模式）。员工可读取并直接使用预授权的公开知识检索；Bash/Edit/Write、浏览器交互和其他敏感操作仍需请求授权。
- 用户明确要求修改代码：`-Mode write`（`default` 权限模式）。员工可提议编辑，但每次 Edit/Write/Bash 都需请求授权。
- Agent 默认 ask。只有额外并行确实能降低总交付成本、任务范围清楚时才加 `-AllowNestedAgents`，在当前员工会话中改为 allow。
- 非 Git 目录写入：只有用户明确同意无 worktree 隔离后才加 `-AllowUnisolatedWrite`。
- 纯连通性测试使用 `-NoTools`；该模式只允许 `inspect`，移除全部内置工具、slash commands 和 MCP。

**模型与 Effort 路由**：Flash 只用于检索初筛、提取、格式化、冒烟和可机械验证的检查；设计、debug、代码修改方案、兼容性、安全审查、架构判断和最终验收，只要错误会带来明显返工，就使用 `deepseek-v4-pro[1m]` + `high`。高风险、多约束且 high 明显不足时才用 `max`。纯连通性测试使用 flash + `low`。选择模型时优先比较错误与返工成本，不能只为降低单次 token 费用而降档；续接会话也按当前增量任务重新选择。

每次 CC 调用失败或结果不可用时，故障记录必须额外判断模型和 Effort 是否匹配，并与上下文范围、工具轮次、预算、输出余量、provider/CLI 状态分别归因。机械任务因读取范围或轮次不足失败时，先用本地代码切片、缩小工具面或续接原会话，不得把升级 Pro/max 当作默认修复；只有证据表明推理质量不足时才升档。

启动或续接前必须根据当前增量任务写明模型与 Effort 的选择理由。不要因为任务篇幅长就直接使用 pro/high，也不要因任务表面简单就忽略事实核验风险：大批量低风险文本处理优先 flash/medium；需要跨文件推理、处理相互冲突的约束或作出高影响判断时再升到 pro/high；`max` 仅用于错误代价高、约束复杂且 high 明显不足的任务。高强度阶段结束后，后续机械修改和格式检查应降档或交回 Codex，避免整段会话持续使用高档位。

**派单提示词合同**：每次 `start`、`reply` 或 Claude Code MCP 调用都要明确写出任务目标、允许读取和修改的范围、必须保留的事实/命令/参数/安全说明、禁止事项、输出格式和验收标准。没有当前任务的明确授权时，员工不得擅自删减需求、简化安全说明、改变目录结构或命令参数、补造事实、扩大修改范围。文案润色可以调整语气和结构，但技术含义、功能覆盖和安全边界必须保持不变；若为了可读性确有必要删减，应先列出拟删内容及理由，等待确认。

**成本控制**：高推理档位只提高推理标准，不授权无限上下文、无限轮次或无边界子代理。派单必须限定范围、证据来源和输出格式，优先复用既有会话、摘要与索引；只有可独立并行且预期收益明确时才启用 `-AllowNestedAgents`，禁止重复抓取、反复读取大文件、无进展轮询和无关扩张。

一次性任务使用 `run` 或 Claude Code MCP，并显式设置有限的 `MaxTurns`、返回大小和 DeepSeek `ProviderBudgetCny` 软阈值。`MaxTurns` 至少覆盖预计工具调用数并额外预留 2 个收尾回合；多文件搜证通常从 8-20 回合起估，测试阶段可按常规值的 1.5-2 倍放宽，再按工具链增减，不能在已支付读取成本后截掉最终回答。`MaxBudgetUsd` 仅在确需 Claude SDK 内部硬闸时启用，不能用它表示 DeepSeek 实际费用。官方后台 `--bg` 不支持这些逐次边界，因此 `start` 不得声称或模拟硬预算；后台员工要拆成可验收阶段并按状态 stop。连续两个实质回合重复读取或重复结论、开始修改范围外文件、擅自删减要求，或预计返工成本已超过 Codex 直接完成时，停止会话并由 Codex 接管。

预算上限必须根据预计输入 token、缓存读取、工具轮次和输出规模估算，并留出完成最终回答的余量。不要给需要读取长日志或大 transcript 的任务设置无法覆盖首次完整处理的低预算；这类任务优先使用可信的结构化用量工具（如 `ccusage --json`）或本地确定性代码提取、去重并汇总 `input/output/cache creation/cache read`，再让 CC 只判断压缩后的元数据。发生 budget error 或状态异常时，先记录 result subtype、`session_id`、usage、费用和轮次，再用 session metadata 与一次最小 `poll` 取回可复用输出；只有确认无法恢复时才补充调用，禁止不看结果就直接重跑。用量审计必须区分“增加”“减少”和“证据不足”，不得把缺失数据解释为持平。

发生 budget error 时必须做同会话收尾和复盘：先判断超支主要来自初始上下文、cache read、工具链回合、模型档位还是输出长度；保留已有工具结果和 partial output；按实际 usage 估算一个只够完成最终回答的小额补充预算，通过同一 session 明确要求停止新工具、压缩现有证据并立即交付。除非 session 无法恢复，不得新开会话重读。任务记录必须写明原预算、终止点、根因、恢复费用、最终是否交付和下次预算调整。

**上下文档位**：`auto` 在 `NoTools` 时选择 `minimal`，其他任务选择 `project`。`minimal` 使用 safe mode，关闭 hooks、skills、plugins、MCP、memory 和 CLAUDE.md；`user` 只加载用户级配置并禁用 MCP，适合明确需要用户 skill 的文案工作；`project` 加载 user/project 规则并禁用 MCP，适合大多数代码和内置 WebSearch 调研；`full` 才继承全部 local 配置和 MCP。只有任务确实需要 MCP 时才使用 `full`。

直接通过 Claude Code MCP 启动自定义 provider 时，不要为省上下文盲目设置 `settingSources=[]`：若认证链依赖 user settings，这会在推理前产生 401。先用无敏感输出的认证探针确认；需要 user settings 时保留 `settingSources=[user]`，再通过 `tools`、`strictAllowedTools`、短 prompt 和输出上限削减上下文。严格工具列表只能使用运行时目录中的精确名称；已有 `strictAllowedTools=true` 时不要再添加不存在的冗余 deny 工具。`strictAllowedTools` 只约束实际可调用权限，不保证其他 MCP 工具不会被运行时展示或尝试；必须同时核对权限结果。

用户明确授权的非敏感本地摘要、usage、错误日志片段或项目文件，可临时按精确工具名和精确路径放行 context-mode 读取/确定性计算，让 CC 直接返回压缩结论。该授权不得扩展到凭据目录、全盘扫描、任意命令、写入、联网外发、认证或发布；含敏感值的配置仍由 Codex 脱敏或定点核验。

Claude Code 在自定义 `ANTHROPIC_BASE_URL` 下可能默认把 MCP schema 全量注入。`EnableToolSearch` 必须先用真实 MCP 调用验证兼容性，通过后再启用；它只在 `full` 档位且未使用 `NoTools` 时生效。不兼容时回退到 `project` 或显式最小 MCP 配置，不得盲目强制。wrapper 默认把 `MAX_MCP_OUTPUT_TOKENS` 设为 10000，长结果优先落盘后只返回路径、摘要和验证结论。

回合预算必须覆盖完整工具链：无工具短任务通常需 2 回合；1-2 文件机械读取常规 4-6、测试期 6-10 回合；3-8 文件搜证常规 8-12、测试期 12-20 回合；仓库级只读审查常规 12-20、测试期 20-30 回合；复杂 Pro/high 或 Pro/max 任务可从 20-30 回合起估。一次公开搜索至少需要 4 回合，始终额外预留至少 2 个收尾回合；多工具任务按实际链路增加。`error_max_turns`、`error_max_budget_usd` 等非零退出仍要解析并返回 subtype、session、cost 和 usage，不能先抛异常丢掉证据。

**Claude Code MCP 轮询**：正常监控使用 `responseMode=minimal` 或 `delta_compact`，`includeActions=true`、`includeResult=true`，并关闭普通 events、progress events、terminal events、structured output 和中间 usage。给用户的初始 ETA 可按 Flash/low 20-60 秒、Flash/medium 1-3 分钟、Pro/high 3-8 分钟、Pro/max 或多工具 5-15 分钟估计，再按实测调整。遵守 MCP 返回的 `pollInterval`，除权限即将超时、状态已接近终态或用户明确要求外，不高频空轮询；等待期间继续处理可独立的本地工作。只有诊断 MCP、hook 或权限协议时才临时打开所需事件，并设置 `maxBytes` / `maxEvents`。不得把模型思考、完整 hook 输出、重复工具事件或整段 transcript 回灌到 Codex 上下文。

示例：

```powershell
pwsh -NoProfile -File "<skill-dir>/scripts/claude-workforce.ps1" -Action run -Mode inspect -NoTools -Ephemeral -ContextProfile minimal -MaxTurns 1 -ProviderBudgetCny 0.05 -Model "deepseek-v4-flash[1m]" -Effort low -Cwd "<project>" -Prompt "只回复结构化判断"

pwsh -NoProfile -File "<skill-dir>/scripts/claude-workforce.ps1" -Action run -Mode inspect -ContextProfile project -MaxTurns 4 -ProviderBudgetCny 0.25 -Model "deepseek-v4-flash[1m]" -Effort medium -Cwd "<project>" -Prompt "搜索公开资料并返回带来源的简短结论"

pwsh -NoProfile -File "<skill-dir>/scripts/claude-workforce.ps1" -Action start -Mode inspect -Model "deepseek-v4-flash[1m]" -Effort medium -Role researcher -Cwd "<project>" -Prompt "调查失败原因并报告证据，不修改文件"

pwsh -NoProfile -File "<skill-dir>/scripts/claude-workforce.ps1" -Action start -Mode write -Model "deepseek-v4-pro[1m]" -Effort high -Role implementer -Cwd "<git-project>" -Prompt "实现指定改动并运行目标测试"

pwsh -NoProfile -File "<skill-dir>/scripts/claude-workforce.ps1" -Action start -Mode inspect -NoTools -Effort low -Role smoke -Cwd "<project>" -Prompt "只回复 WORKFORCE_SMOKE_READY"
```

脚本使用当前 `CODEX_THREAD_ID` 生成 `cx-<thread>-<role>-<time>` 名称。同一 Codex task 默认只列出自己的员工；需要跨 task 找回时显式使用 `-AllThreads`。

**`run`、`start` 和 `reply` 在调用前强制检查**：验证 Claude Code 版本 >= 2.1.200、agents 子命令支持 JSON/permission mode、主命令支持 JSON 输出和预算。当前 CLI 接受 `--max-turns` 但可能不在 `--help` 中展示，因此以版本下限和真实冒烟测试共同确认，不做 help-only 误判。不满足条件时立即报错，不会仅在 `capabilities` 中报告。

不要在 prompt 中放 token、密码、私有端点、仓库 remote、分支名或身份信息。脚本会附加禁止提交、推送、发布、部署、开 PR、删除 worktree、访问专用凭据库和抓取私网目标的约束，并用 session ask/allow 与 MCP 逐次审批实施分级控制。敏感 Read 一旦获批，内容可能进入持久 transcript；批准前必须确认任务必要性和输出脱敏。

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

同步 `run`/`reply` 及其他原生 CLI 捕获默认受 `-ProcessTimeoutSeconds 1800` 约束（范围 15-3600 秒）。冒烟测试应显式使用较短但足以完成一次模型响应的超时；超时后 wrapper 只对自己启动的进程树请求终止，不扫描或终止其他 Claude/Node 进程。已经脱离该进程树的后代可能存活；重试前检查进程与 provider 状态。若已经返回可恢复 session，应优先续接该 session，不能重开会话重复读取。

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
- 私有配置的有效键是 `ClaudeExecutable`、`ExpectedClaudeSha256`、`EnableToolSearch`；旧 `AllowBroadWebFetch` 仅为兼容而接受，不授予权限。`EnableToolSearch` 必须先通过当前 provider/proxy 的真实 MCP 调用探针。wrapper 更新后应先重新审计，再更新固定哈希并重跑 capability、权限探针和冒烟测试。
- `CODEX_THREAD_ID` 缺失时员工归入 `cx-manual`；需要严格跨任务隔离时不要在缺失该变量的环境启动员工。

## 继续同一对话

官方 CLI 没有 `send <short-id> <prompt>`，但支持 `--resume <session-id>` 持久续接。给既有员工追加短指令时使用 `reply`；脚本从 roster 解析完整 session ID，通过 `-p --resume` 写回同一 transcript：

```powershell
pwsh -NoProfile -File "<skill-dir>/scripts/claude-workforce.ps1" -Action reply -Id "<worker-id>" -Mode inspect -ContextProfile project -MaxTurns 2 -ProviderBudgetCny 0.15 -Model "deepseek-v4-pro[1m]" -Effort high -Prompt "基于前面的结论补充一项检查"
```

`reply` 必须显式指定 `-Model`，按当前增量任务重新选择 Flash/Pro，避免续接 Pro 员工时静默降为默认 Flash，也确保供应商费用使用正确费率。未指定 `-ContextProfile` 时按 `auto` 处理：加 `-NoTools` 选 `minimal`，否则选 `project`，默认不继承 MCP。纯文本连通性或记忆测试加 `-NoTools -Model "deepseek-v4-flash[1m]" -Effort low`。`reply` 是同步的，适合短增量任务；需要持续后台监控的长任务使用 `respawn` 后手动 attach，或派发新的后台员工。

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

## 会话版本与 Git 来源

- 每个新持久员工名称都带 `w<profile-version>-p<fingerprint>`。指纹由启动时仓库根、原始 origin、branch 和 commit 计算；本地输出向 Codex 返回脱敏来源字段，发给 CC 的任务合同只含来源类型和不可逆指纹，不发送 remote 或 branch。
- `reply` 会在恢复前重算来源。没有标记的旧会话默认停止，核对日志、cwd、fork、branch 和配置后才可显式加 `-AllowLegacySession`。来源指纹改变时默认停止，确认 checkout、commit 或 fork 变化是预期行为后才可加 `-AllowProvenanceDrift`。
- 已运行进程不会因安装新 skill/profile 而自动升级。权限模型或 profile 版本变化时新开员工；不要把旧 fork、旧 branch 或旧 profile 的结论当成当前代码状态。

## 安全边界

- Agent View 是 Research Preview，但由官方 supervisor 落盘 roster、状态和 transcript，优先于依赖一次性 `claude -p` 的第三方插件。
- **原生 Windows 没有 Claude Code 的完整 OS 沙箱或进程级 shell deny**。session 权限规则、MCP 审批和 permission mode 提供工具层面的约束，但不在 OS 层面阻止文件读取或进程执行。Git worktree 只隔离代码改动，不隔离文件系统访问。不应声称 Windows 上存在 OS 沙箱或 shell deny 的绝对安全保证。
- `write` 模式使用 `default` 权限模式而非 `acceptEdits`：每次编辑操作都需请求授权。`--settings` 中的 `ask` 规则覆盖用户/项目全局 `allow`，确保未明确批准的动作产生请求。
- `plan` 仍允许读取、规划和预授权的公开知识检索，不是零工具沙箱。敏感路径、编辑、通用 Bash、WebFetch 和 Agent 由 ask 规则交给主管；`-NoTools` 才用于真正的无工具测试。
- 不自动 commit、push、发布、部署或开 PR。即使员工声称需要，也回到 Codex 主对话请求授权。
- 不直接读取 `~/.claude/daemon`、job state 或 transcript 正文；使用 `list` 和 `logs` 命令获取受支持的视图。
- CC 或 wrapper 更新后重新运行 `capabilities`，再用 `-NoTools -Effort low` 进行低成本启动、列表、日志和停止冒烟测试。
- `-AllowNestedAgents` 将 Agent 从 ask 移到当前会话 allow，可能显著增加 token；只有可独立并行且预期净节省时使用。
