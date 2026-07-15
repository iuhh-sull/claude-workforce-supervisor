# Budget, pricing, and timeouts

## Provider pricing freshness

Audited provider rates live in `config/provider-pricing.psd1`. Each model entry records the verification date, maximum accepted age, source class, currency, and per-million-token rates. The provider dashboard or invoice remains authoritative for actual billing.

At runtime, calculate `pricing_age_days` as the number of calendar days since `verified_on`. Set `pricing_stale` when `pricing_age_days` is greater than `max_age_days`. Stale pricing may still produce an `estimated_cost`, but it must not support a definite budget decision:

- `cost_exceeds_budget = null`
- `budget_enforcement_status = stale-pricing`

Community reports may annotate a rate change, but they must not replace official active pricing. Refresh `verified_on` only after rechecking the official source.

## Budget policy

`BudgetPolicy` has three modes:

| Policy | Inputs and execution | Result |
|---|---|---|
| `none` | Requires no budget and does not pass an SDK hard cap. | Reports usage only; it makes no provider-budget decision. |
| `advisory` | May accept `ProviderBudgetCny`. It never interrupts the active invocation. | Compares completed usage against fresh provider pricing and may stop new dispatch at a stage boundary. |
| `hard` | Requires `MaxBudgetUsd > 0` and passes `--max-budget-usd` to Claude Code. | If the SDK limit is hit, preserves partial output and attempts one same-session finalize. |

`MaxBudgetUsd` is Claude Code's SDK hard cap. With a custom provider, it is not the provider's invoice currency and must not be presented as actual provider spend. `ProviderBudgetCny` is a post-run advisory threshold based on the audited provider rate table.

## Max turns and omitted parameters

`MaxTurns = 0` means unbounded by this wrapper: omit `--max-turns` entirely. A positive value passes `--max-turns <value>`. Omitting `MaxTurns` uses its default of `0` and therefore also omits the CLI argument.

Other omitted parameters follow their declared defaults:

- Omitting `BudgetPolicy` selects `advisory`.
- Omitting `ProviderBudgetCny` or leaving it at `0` provides no advisory threshold.
- Under `hard`, omitting `MaxBudgetUsd` or leaving it at `0` is invalid.
- Omitting startup and idle timeout parameters selects the active invocation-level profile.
- Omitting `HardTimeoutSeconds`, or setting it to `0`, disables the absolute wall-clock timeout.

Limit results such as max turns, hard budget, timeout, context limit, or a provider rate limit after partial output may trigger one same-session, no-tools finalize. Finalization must not start new reads, tools, sessions, or repeated side effects.

## Process timeouts

- **Startup timeout**: runs from process creation until the first valid output or handshake. A process that stays silent past this deadline times out.
- **Idle timeout**: begins after startup succeeds and expires after a continuous period with neither output nor observable state change. Periodic output resets it.
- **Hard timeout**: an absolute wall-clock deadline from process creation. `0` disables it; output and state changes do not reset it.

When any enforced process timeout fires, preserve partial output, attempt the same-session finalize once, clean up owned resources, and retain the session for recovery instead of deleting it immediately. `ProcessTimeoutSeconds` is only a compatibility alias and must not be described as a fourth independent timeout.

## MCP timeout status

MCP startup, idle, and tool timeouts are separate from the whole Claude process timeouts. Report the effective status of each timeout using these terms:

- `configured`: the wrapper supplied the timeout value to the session profile, environment, or supported runtime parameter.
- `enforced`: the responsible runtime or wrapper has an active timer and an observable termination/recovery path for that exact timeout.
- `reported-only`: the wrapper can classify and report a timeout-shaped failure, but cannot prove that it actively enforced the deadline.

Configuration alone is not enforcement. If the installed Claude Code or MCP transport exposes no supported enforcement mechanism, report `reported-only`; do not claim `enforced`. HTTP/SSE recovery waits for internal reconnect before restarting a confirmed-dead registered service once. Stdio recovery restarts only a registered owned child whose exit has been verified.
