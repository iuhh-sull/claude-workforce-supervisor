# DeepSeek Provider Reference

> 本文档从 SKILL.md 提取，记录 DeepSeek 作为 workforce custom provider 的模型映射、费率结构、缓存行为和兼容性说明。切换或添加 provider 时参见 `portability.md`。

## 模型 ID

| 用途 | 模型 ID | Effort 推荐 |
|------|---------|------------|
| 快速/检索/格式化/冒烟 | `deepseek-v4-flash[1m]` | `low` / `medium` |
| 设计/debug/安全审查/验收 | `deepseek-v4-pro[1m]` | `high` |
| 高风险多约束 | `deepseek-v4-pro[1m]` | `max`（需实测确认） |

`[1m]` 后缀启用 1M token 上下文窗口。wrapper 脚本 `-Effort` 参数接受全部五档（`low`/`medium`/`high`/`xhigh`/`max`），但 DeepSeek 后端对 `xhigh` 的实际推理语义尚未经过本地兼容探针验证，使用前需在当前 provider/proxy 环境下实测。

## 费率（2026-07-14 审计）

| 模型 | 缓存命中 | 缓存未命中 | 输出 |
|------|---------|-----------|------|
| `deepseek-v4-flash[1m]` | ¥0.02/M | ¥1/M | ¥2/M |
| `deepseek-v4-pro[1m]` | ¥0.025/M | ¥3/M | ¥6/M |

以上为非高峰 off-peak 费率。DeepSeek 于 2026-06-29 公告高峰定价（北京时间 09:00–12:00, 14:00–18:00，乘数 ×2），生效日期尚未在官方定价页独立确认。**实际费率以 [platform.deepseek.com/pricing](https://platform.deepseek.com/pricing) 和供应商账单为准。** wrapper 当前使用 off-peak 费率做估算。

## Billing 公式

wrapper 将 Claude Code 返回的 usage token 字段归并为 DeepSeek 计费类别：

```
cache_miss_tokens  = input_tokens + cache_creation_input_tokens
cache_hit_tokens   = cache_read_input_tokens
output_tokens      = output_tokens
```

三类 token 分别乘以对应费率得出 CNY 估算。归并和 decimal 乘法由本地 PowerShell 完成，不消耗 CC token。

## 缓存字段兼容性

DeepSeek Anthropic 兼容层可能**始终不填** `cache_creation_input_tokens`（值为 0 或 null）。此时基于 creation 的复用率 `cache_read / (cache_creation + cache_read)` 退化。建议优先报告 `cache_read / (input + cache_read)` 并注明口径限制。

## ANTHROPIC_BASE_URL 特殊行为

- 自定义 `ANTHROPIC_BASE_URL` 下，Claude Code 默认**不启用 MCP Tool Search**；`EnableToolSearch = $true` 必须先通过真实 MCP 调用验证。
- 自定义端点下 MCP schema 可能被全量注入；`--strict-mcp-config` 可抑制。
- 认证链若依赖 user settings，不要设 `settingSources=[]`（会导致 401）；先用无敏感输出的认证探针确认。

## 与其他 provider 的差异

- DeepSeek 不支持 image/document multimodal 输入。
- 官方 Claude Code `auto` permission mode 要求 Anthropic API + 受支持 Claude 模型；DeepSeek custom provider 不满足条件，force 使用 `default` 或 `plan`。
- SDK `total_cost_usd` 在 custom provider 下按 Anthropic 内置价估算，不代表供应商实际扣费；wrapper 默认隐藏该字段。

## 相关文件

- 核心 wrapper: `scripts/claude-workforce.ps1`（`Get-ProviderPricing` 函数）
- 费率配置: 脚本内置 switch 表 / 未来 `provider-pricing.json`
- 扩展指南: `references/portability.md`
