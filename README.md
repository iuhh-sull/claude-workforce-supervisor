# Claude Workforce

> Unofficial project. [中文说明](./README.zh-CN.md)

Claude Workforce lets Codex manage background Claude Code workers through the official `claude agents` supervisor. Codex dispatches work, checks status and logs, and reviews the result. If a task is interrupted, the supervisor can resume its conversation later.

This unofficial Codex skill wraps the official `agents` subcommand. It is intended for research, code review, and background work completed in stages.

> Status: beta. The state, broker, migration, timeout, and permission architecture is covered by deterministic tests, but real-host behavior still depends on the installed Claude Code/provider path. Run the manual opt-in host workflow before treating a release as production-ready.

Requirements: Windows, PowerShell 7, and Claude Code `2.1.208` or newer. Older versions are rejected even if some capability probes appear to pass.

## Install

```powershell
pwsh -NoProfile -File Install.ps1
```

First install doesn't need `-Force`. Add `-Force` only to replace an existing installation; the script backs up the old skill directory first. Installation also runs idempotent schema-v2 state migration, creates a separate state backup when needed, and returns a `rollback_command`. Use `-SkipStateMigration` only when migration will be performed and reviewed separately; the installer never copies over the workforce state root.

After install you can create a private config at `~/.codex/claude-workforce.local.psd1`. The recommended active keys are:

```powershell
@{
    ClaudeExecutable   = "C:\path\to\claude.exe"
    ExpectedClaudeSha256 = "<64-char hex hash>"
    EnableToolSearch = $true
}
```

The legacy `AllowBroadWebFetch` key is still parsed so old private files do not break, but it grants no permission and should be removed when convenient.

Don't commit this file to a public repository. Precedence: CLI parameters > private file > environment variables > PATH.

`EnableToolSearch` only takes effect with `-ContextProfile full`, because the other profiles intentionally do not inherit MCP servers. `-NoTools` always keeps it disabled.

## Quick start

Verify the environment:

```powershell
$workforce = Join-Path $HOME '.codex\skills\claude-workforce\scripts\claude-workforce.ps1'
pwsh -NoProfile -File $workforce -Action capabilities
```

Use `run` for one-off work. Choose `-BudgetPolicy none`, `advisory` (default), or `hard`. A positive `-MaxTurns` is a requested turn boundary; `-MaxTurns 0` omits `--max-turns` entirely. The examples below use the bundled DeepSeek adapter; substitute your own model and budget policy as needed:

```powershell
# Text or numeric judgment: minimal context, no tools, no retained session after success
pwsh -NoProfile -File $workforce -Action run -Mode inspect -NoTools -Ephemeral `
  -ContextProfile minimal -MaxTurns 1 -ProviderBudgetCny 0.01 `
  -Model "deepseek-v4-flash[1m]" -Effort low `
  -Cwd "<project-path>" -Prompt "Return only the requested verdict"

# Public research: retain the session so a turn or budget error can be resumed
pwsh -NoProfile -File $workforce -Action run -Mode inspect `
  -ContextProfile project -MaxTurns 4 -ProviderBudgetCny 0.10 `
  -Model "deepseek-v4-flash[1m]" -Effort medium `
  -Cwd "<project-path>" -Prompt "Search public sources and return a short sourced conclusion"
```

Start a background worker only when the task must keep running or remain resumable over time:

```powershell
# Research mode, flash model, medium effort
pwsh -NoProfile -File $workforce -Action start -Mode inspect `
  -Model "deepseek-v4-flash[1m]" -Effort medium -Role researcher `
  -Cwd "<project-path>" -Prompt "Investigate root cause, list evidence, do not modify files"

# Implementation mode, pro model, high effort
pwsh -NoProfile -File $workforce -Action start -Mode write `
  -Model "deepseek-v4-pro[1m]" -Effort high -Role implementer `
  -Cwd "<git-project-path>" -Prompt "Implement the change and run targeted tests"

# Inherit MCP only when needed; probe Tool Search before forcing it through a custom proxy
pwsh -NoProfile -File $workforce -Action start -Mode inspect `
  -ContextProfile full -EnableToolSearch -Effort medium -Role researcher `
  -Cwd "<project-path>" -Prompt "Use the configured MCP tools and report evidence"
```

For status, log, reply, stop, and remove commands, see [SKILL.md](./claude-workforce/SKILL.md).

## Cost and context profiles

`auto` selects `minimal` for no-tool work and `project` otherwise. The same default applies to `reply`. `minimal` disables rules, skills, plugins, MCP, memory, and CLAUDE.md. `user` loads user configuration without MCP. `project` loads user and project rules without MCP. Only `full` inherits all configured MCP servers and local settings. Hooks are disabled in every profile by default; `-AllowHooks` removes only the session-level disable key and never weakens `-NoTools`.

A full tool environment can inject tens of thousands of tokens before the first task sentence. Use `full` only when the task actually needs MCP. With a custom `ANTHROPIC_BASE_URL`, Claude Code may not enable Tool Search automatically; set `EnableToolSearch = $true` only after a real MCP call succeeds. The wrapper also caps a single MCP result at 10,000 tokens by default.

Do not add supervisor and worker tokens or prices together when judging quota savings. First measure the supervisor context avoided by delegation, then subtract dispatch, polling, targeted review, and rework; report worker-provider spend separately. After CC returns, verify only the cited paths, lines, URLs, diff, and failures instead of rereading the same corpus. If a full reread is still required, treat the call as a second-opinion review, not a quota saving.

With a custom endpoint, the Claude Agent SDK may estimate `total_cost_usd` from Anthropic prices even when another provider handles the request. That number is not the provider bill, so the wrapper hides it by default; add `-IncludeSdkCostEstimate` only when diagnosing the compatibility layer. For a model with an audited rate adapter, normal output derives billing-token buckets, component costs, currency, and a provider estimate from returned `usage`. Unknown models remain usable, but no provider estimate is invented.

`BudgetPolicy none` reports usage without a budget decision. `advisory` may compare the completed run with `-ProviderBudget`/`-ProviderBudgetCny` and fresh audited pricing, but never interrupts the active invocation. `hard` requires `-MaxBudgetUsd` and passes the SDK-internal hard cap; with a custom provider it is not the provider invoice. Official background `--bg` supports neither per-run cap, so `start` does not claim one. Unknown or stale pricing produces an unavailable/indeterminate provider decision rather than an invented cost.

`reply` also requires explicit `-Model` and `-Effort` values for every resumed task. Native print-mode replies are inspect-only; use the Claude Code MCP path when a resumed task needs interactive write approval. After `start`, the wrapper checks the supervisor roster and returns `roster_verified`, `roster_state`, `roster_cwd_match`, and `roster_session_id`; a roster-query failure is reported without pretending verification succeeded.

When the worker provider is materially cheaper than scarce supervisor quota, delegate work that has a clear contract, can return a compressed result, and does not require dense sensitive approvals. Do not impose a mechanical minimum file or token count. Stop on scope drift, repeated reads, lack of progress, rework, or actual provider cost—not merely because raw token counts look large.

Do not discard paid work after a budget stop. Preserve the session and usage, diagnose whether context, cache, tool turns, or output caused the overrun, then give the same session a small evidence-based finalization budget with instructions to stop using tools and compress the existing result. Do not start a fresh reread.

Cache reuse is an optimization, not a reason to disable useful parallel work. Prefer the same chief/session for related follow-ups and keep its context profile, tool catalog, and skill set stable unless the task needs a change. Compare fresh and resumed sessions separately; if a provider omits cache-creation fields, report the cache-read share and the measurement limitation instead of inventing a reuse ratio.

## Model routing

Use a fast/low-cost model with low or medium effort for retrieval, extraction, formatting, smoke tests, and mechanical checks. Use a higher-capability model with high effort for design, complex debugging, compatibility decisions, security review, architecture, and final acceptance. Reserve max for high-risk multi-constraint tasks. Provider-specific model mappings belong in references, not the core workflow.

Route by error cost and expected rework, not only by input size. Higher effort spends more thinking tokens, so routine follow-up work should not inherit high/max from an earlier phase. Typical delivery estimates are 20–60 seconds for flash/low, 1–3 minutes for flash/medium, 3–8 minutes for pro/high, and 5–15 minutes for pro/max or multi-tool work. Check status near the expected milestone rather than polling continuously, except for permission requests or near-terminal work.

After a failed CC call, review model, effort, context scope, tool turns, budget, and final-output headroom separately. Do not default to Pro/max when a mechanical read exceeded its turn envelope; slice or compress the input and resume the same session first. A positive `MaxTurns` should cover the expected tool calls plus at least two finalization turns. `StartupTimeoutSeconds` covers launch-to-first-output, `IdleTimeoutSeconds` covers continuous inactivity after startup, and `HardTimeoutSeconds` is the absolute wall clock (`0` disables it). `ProcessTimeoutSeconds` is only a compatibility alias. Timeout preserves partial stdout/stderr, attempts one same-session no-tools finalize, and performs broker-verified cleanup.

## Permissions

`new-workforce-session-profile.ps1` builds temporary, session-scoped settings shared by the MCP and Agent View paths. It never writes to `~/.claude/settings.json`, so a normal interactive `claude` session keeps the user's own defaults.

`-TrustProfile` supports `strict`, `balanced` (default), and `delegated`. Strict keeps project writes and common commands reviewable. Balanced allows current-worktree writes plus bounded read-only Git/test commands. Delegated adds common formatter, type-check, and static-check commands. None of them broadly allow arbitrary Shell, sensitive reads, WebFetch, local-data egress, install, authentication, destructive commands, commit, push, publishing, or deployment.

All profiles emit `disableAllHooks: true` by default. `-AllowHooks` removes that session key but does not assert that inherited hooks are safe or override managed settings. `-NoTools` always disables hooks and tools. Sensitive-path Read, worktree-external writes, WebFetch targets, nested Agent/Task, and side-effecting MCP tools remain input-specific decisions; the project never uses bypass/skip-permission modes.

## Extending to a new provider

The wrapper accepts arbitrary model IDs via pattern validation and leaves the default model unset unless `WORKFORCE_DEFAULT_MODEL` is present. For a new provider, verify effort semantics and usage fields, then add audited pricing only if provider-cost estimates are needed. See `claude-workforce/references/portability.md` for the checklist and `claude-workforce/references/deepseek-provider.md` for one adapter example.

For non-Codex environments, set `WORKFORCE_NAMESPACE` to isolate workers across sessions. See `claude-workforce/references/portability.md` for OS-specific notes and extension points.

MCP calls leave top-level `allowedTools` and `disallowedTools` empty. The `xihuai18/claude-code-mcp` (npm: `@leo000001/claude-code-mcp`) permission proxy uses `claude_code` for session management and `claude_code_check` (supporting `poll` and `respond_permission` actions) to surface each unresolved action to the supervisor. Compatibility is verified through the Codex runtime MCP catalog and real permission probes; this public project does not install or pin the MCP version. Approvals are for the current request and are not written back as persistent Claude settings.

Agent is ask-by-default. `-AllowNestedAgents` promotes Agent to allow only inside the delegated session, so enable it when parallel work has a clear payoff and bounded scope.

The legacy `AllowBroadWebFetch` input is still accepted for compatibility, but it no longer bypasses per-target review. This profile does not use Claude Code's `auto` permission mode; custom-provider deployments may not satisfy that mode's requirements, and explicit per-action review is easier to audit across providers.

Treat `maxTurns` as a requested boundary that must be checked against the returned usage and status. This SDK/provider combination has exceeded the requested value in testing, so scope drift, repeated reads, progress, and actual provider cost remain the practical stop signals.

Every new persistent worker name includes a workforce-profile version and a fingerprint derived from its launch repository root, origin, branch, and commit. `start` returns the locally sanitized source fields to Codex, but sends only the source kind and irreversible fingerprint in the CC prompt. `reply` recomputes the fingerprint and stops on an old unversioned worker or a changed fork/branch/commit. After manual review, `-AllowLegacySession` can resume a pre-version worker and `-AllowProvenanceDrift` can accept an intentional Git change. Existing processes do not inherit a newly installed profile retroactively; start a new worker when the permission model changes.

## Resource lifecycle and connectivity

Schema-v2 Manifest files are the sole authoritative lifecycle state and are written only by the supervisor under a mutex, atomic replace, backup, revision CAS, and transition checks. Worker reports are untrusted audit input and cannot register resources or change ownership. Processes, ports, and MCP endpoints become trusted only through the capability-token broker; persisted records and leases use HMAC. The token is never persisted or returned.

Every dispatch runs reaper/reconcile before acquisition. Reaper idempotently converges terminal/stale workers and retries eligible cleanup. Reconcile prevents duplicate work, blocks corrupt or `cleanup-incomplete` state, checks provider/model circuit state, and applies soft concurrency ceilings:

| Level | Stable active | Burst | Nested agents |
|---|---:|---:|---:|
| low | 2 | 3 | 0 |
| medium | 4 | 6 | 2 |
| high | 6 | 10 | 4 |

`retain-session` plus `stop-on-complete` are the defaults: transcript metadata remains resumable, while temporary processes and ports are released. `-ResourcePolicy` accepts `cleanup`, `retain-session`, and `keep-resources`; `-SessionRetentionPolicy` accepts `stop-on-complete`, `remove-on-complete`, `idle-ttl`, and `manual`. Automatic removal fails closed unless the Agent View worker is terminal and its Git worktree is verified clean. Print-mode `run` sessions are retained for same-session recovery; use `-Ephemeral` when their transcript may be discarded.

```powershell
pwsh -NoProfile -File $workforce -Action reconcile -Cwd $project -Role researcher -Prompt '<task>'
pwsh -NoProfile -File $workforce -Action resources
pwsh -NoProfile -File $workforce -Action ports
pwsh -NoProfile -File $workforce -Action doctor -Cwd $project
pwsh -NoProfile -File $workforce -Action reap
pwsh -NoProfile -File $workforce -Action migrate
pwsh -NoProfile -File $workforce -Action daemon-restart-keep-workers
pwsh -NoProfile -File $workforce -Action stop -Id '<worker-id>' -GracefulShutdownSeconds 10 -PortReleaseTimeoutSeconds 15
```

Retryable provider failures perform at most one same-session recovery and retain partial output. Authentication, invalid-model, TLS-validation, DNS-configuration, and unsupported-endpoint failures never auto-retry. Circuit-open state freezes new dispatch. Cleanup never trusts a worker report or kills by name/port alone: force cleanup requires broker HMAC, safe key ACL, Manifest/session binding, PID/start-time/executable/descendant identity, and listener PID. Any failed proof remains `cleanup-incomplete`.

State lives under `~/.codex/claude-workforce/` by default. Every lifecycle result includes `cleanup_status`, owned process/port counts, retry/finalize and reuse decisions. Legacy state migrates with a rollback backup; `doctor` reports migration, state lock/corruption, broker key/ACL, stale/cleanup, port, pricing and environment status. See the focused references under `claude-workforce/references/`.

## Windows note

Native Windows doesn't provide a full OS sandbox for Claude Code. Session rules and MCP approval act at the tool level, not at the OS level. Don't rely on this for sandboxing.

## Remove a worker

```powershell
pwsh -NoProfile -File $workforce -Action remove -Id "<id>" `
  -ConfirmRemove -CheckedWorktree
```

`-ConfirmRemove` confirms the deletion. `-CheckedWorktree` confirms that you reviewed the worker status, logs, and associated worktree for uncommitted or unmerged changes. Both are required. Only terminal states (stopped, completed, failed, error, dead, cancelled, exited) can be removed; stop a running worker first.

## Project layout

```
claude-workforce/
  SKILL.md                 # Codex skill definition
  agents/openai.yaml       # OpenAI-compatible agent definition
  scripts/
    claude-workforce.ps1   # Core wrapper
    new-workforce-session-profile.ps1 # Session-only MCP/worker settings
    workforce-lifecycle.ps1 # Authoritative Manifest state machine
    workforce-state.ps1    # Mutex, atomic JSON, backup, CAS
    workforce-resource-broker.ps1 # Capability/HMAC resource broker
    workforce-reaper.ps1   # Terminal/stale postflight convergence
    workforce-timeouts.ps1 # Startup/idle/hard process monitor
  config/provider-pricing.psd1 # Audited provider rates
  references/              # Permissions, budgets/timeouts, lifecycle, recovery, operations
Install.ps1                # Install script
tests/
  Test-ClaudeWorkforce.ps1 # Portable fake-runtime suite
  Test-WorkforceRemediation.ps1 # Concurrency/security/timeout regression suite
  helpers/                 # Deterministic process/state fixtures
.github/workflows/
  test.yml                 # Windows unit/remediation CI
  host-integration.yml     # Manual opt-in real-host CI
README.md                  # This file
README.zh-CN.md            # Chinese translation
SECURITY.md                # Security policy
```

## Uninstall

```powershell
$target = Join-Path $HOME '.codex\skills\claude-workforce'
if ((Split-Path -Leaf $target) -eq 'claude-workforce' -and (Test-Path -LiteralPath $target)) {
    Remove-Item -LiteralPath $target -Recurse -Force
}
```

If the installer created a backup (at `~/.codex/backups/claude-workforce-<date>`), you can restore it directly.
