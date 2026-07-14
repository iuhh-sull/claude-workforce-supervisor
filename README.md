# Claude Workforce

> Unofficial project. [中文说明](./README.zh-CN.md)

Claude Workforce lets Codex manage background Claude Code workers through the official `claude agents` supervisor. Codex dispatches work, checks status and logs, and reviews the result. If a task is interrupted, the supervisor can resume its conversation later.

This unofficial Codex skill wraps the official `agents` subcommand. It is intended for research, code review, and background work completed in stages.

## Install

```powershell
pwsh -NoProfile -File Install.ps1
```

First install doesn't need `-Force`. Add `-Force` only to overwrite an existing installation; the script backs up the old directory first.

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

Use `run` for one-off work. Bound execution with `-MaxTurns` plus either an audited provider soft threshold (`-ProviderBudget`) or the SDK hard cap (`-MaxBudgetUsd`). The examples below use the bundled DeepSeek adapter; substitute your own model and budget policy as needed:

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

`auto` selects `minimal` for no-tool work and `project` otherwise. The same default applies to `reply`. `minimal` disables hooks, skills, plugins, MCP, memory, and CLAUDE.md. `user` loads user configuration without MCP. `project` loads user and project rules without MCP. Only `full` inherits all configured MCP servers and local settings.

A full tool environment can inject tens of thousands of tokens before the first task sentence. Use `full` only when the task actually needs MCP. With a custom `ANTHROPIC_BASE_URL`, Claude Code may not enable Tool Search automatically; set `EnableToolSearch = $true` only after a real MCP call succeeds. The wrapper also caps a single MCP result at 10,000 tokens by default.

Do not add supervisor and worker tokens or prices together when judging quota savings. First measure the supervisor context avoided by delegation, then subtract dispatch, polling, targeted review, and rework; report worker-provider spend separately. After CC returns, verify only the cited paths, lines, URLs, diff, and failures instead of rereading the same corpus. If a full reread is still required, treat the call as a second-opinion review, not a quota saving.

With a custom endpoint, the Claude Agent SDK may estimate `total_cost_usd` from Anthropic prices even when another provider handles the request. That number is not the provider bill, so the wrapper hides it by default; add `-IncludeSdkCostEstimate` only when diagnosing the compatibility layer. For a model with an audited rate adapter, normal output derives billing-token buckets, component costs, currency, and a provider estimate from returned `usage`. Unknown models remain usable, but no provider estimate is invented.

`-ProviderBudget` is a post-run soft threshold for accounting and alerts; `-ProviderBudgetCny` remains its backward-compatible name. `-MaxBudgetUsd` is an SDK-internal hard stop and may not match a custom provider's bill. Official background `--bg` supports neither limit, so `start` does not claim a hard cap. `run` and `reply` require finite `-MaxTurns` plus one budget boundary. A provider-only threshold requires an audited model rate unless `-AllowUnpricedModel` explicitly acknowledges that no provider estimate can be enforced.

`reply` also requires explicit `-Model` and `-Effort` values for every resumed task. Native print-mode replies are inspect-only; use the Claude Code MCP path when a resumed task needs interactive write approval. After `start`, the wrapper checks the supervisor roster and returns `roster_verified`, `roster_state`, `roster_cwd_match`, and `roster_session_id`; a roster-query failure is reported without pretending verification succeeded.

When the worker provider is materially cheaper than scarce supervisor quota, delegate work that has a clear contract, can return a compressed result, and does not require dense sensitive approvals. Do not impose a mechanical minimum file or token count. Stop on scope drift, repeated reads, lack of progress, rework, or actual provider cost—not merely because raw token counts look large.

Do not discard paid work after a budget stop. Preserve the session and usage, diagnose whether context, cache, tool turns, or output caused the overrun, then give the same session a small evidence-based finalization budget with instructions to stop using tools and compress the existing result. Do not start a fresh reread.

Cache reuse is an optimization, not a reason to disable useful parallel work. Prefer the same chief/session for related follow-ups and keep its context profile, tool catalog, and skill set stable unless the task needs a change. Compare fresh and resumed sessions separately; if a provider omits cache-creation fields, report the cache-read share and the measurement limitation instead of inventing a reuse ratio.

## Model routing

Use a fast/low-cost model with low or medium effort for retrieval, extraction, formatting, smoke tests, and mechanical checks. Use a higher-capability model with high effort for design, complex debugging, compatibility decisions, security review, architecture, and final acceptance. Reserve max for high-risk multi-constraint tasks. Provider-specific model mappings belong in references, not the core workflow.

Route by error cost and expected rework, not only by input size. Higher effort spends more thinking tokens, so routine follow-up work should not inherit high/max from an earlier phase. Typical delivery estimates are 20–60 seconds for flash/low, 1–3 minutes for flash/medium, 3–8 minutes for pro/high, and 5–15 minutes for pro/max or multi-tool work. Check status near the expected milestone rather than polling continuously, except for permission requests or near-terminal work.

After a failed CC call, review model, effort, context scope, tool turns, budget, and final-output headroom separately. Do not default to Pro/max when a mechanical read exceeded its turn envelope; slice or compress the input and resume the same session first. `MaxTurns` should cover the expected tool calls plus at least two finalization turns; multi-file evidence gathering commonly starts at 8–20 turns, with 1.5–2× that allowance during testing. For explicitly approved, non-sensitive summaries, usage data, error-log excerpts, and project files, context-mode may be temporarily allowed by exact tool name and path, but that grant does not extend to credentials, drive-wide scans, arbitrary commands, writes, or exfiltration. Synchronous native CLI capture accepts `-ProcessTimeoutSeconds` from 15 to 3600 seconds (default 1800) and requests termination of only the process tree it started. A detached descendant may survive, so check process and provider state before retrying.

## Permissions

`new-workforce-session-profile.ps1` builds temporary, session-scoped settings shared by the MCP and Agent View paths. It never writes to `~/.claude/settings.json`, so a normal interactive `claude` session keeps the user's own model and permission defaults.

**Permission layers in this profile:**

| Layer | Meaning | Example |
|-------|---------|---------|
| **tools** | Capability exists in the runtime. | `Read`, `Bash`, `Agent` are all present. |
| **allow** | Pre-authorized — runs without per-invocation approval. | `Read`, `Glob`, `Grep`, `WebSearch`, `Plan`. |
| **ask** | Per-invocation review via `canUseTool` → Codex. | `Bash`, `Edit`, `Write`, `WebFetch`, `Agent`, `Task`. |
| **deny** | Hard block — cannot be used regardless of other rules. | Kept empty; truly unacceptable actions are refused by Codex. |

Sensitive-path Read rules (`.env`, `auth.json`, `settings.json`, private keys) are placed in **ask** with higher priority than the broad `Read` **allow**, so they still trigger per-invocation review even though `Read` is pre-authorized.

This profile does not use `bypassPermissions`, `acceptEdits`, `dontAsk`, or any form of skip-permissions. Every write, shell command, web fetch target, and nested agent remains reviewable.

Read, Glob, Grep, WebSearch, and Plan are pre-authorized. Shell commands, Edit, Write, NotebookEdit, each WebFetch target, Agent, and side-effecting MCP tools are surfaced through the permission proxy. Codex may approve a public URL or a clearly read-only shell/Git inspection directly; writes, outbound local data, authentication, installation, publishing, and deployment require an input-specific decision.

## Extending to a new provider

The wrapper accepts arbitrary model IDs via pattern validation and leaves the default model unset unless `WORKFORCE_DEFAULT_MODEL` is present. For a new provider, verify effort semantics and usage fields, then add audited pricing only if provider-cost estimates are needed. See `claude-workforce/references/portability.md` for the checklist and `claude-workforce/references/deepseek-provider.md` for one adapter example.

For non-Codex environments, set `WORKFORCE_NAMESPACE` to isolate workers across sessions. See `claude-workforce/references/portability.md` for OS-specific notes and extension points.

MCP calls leave top-level `allowedTools` and `disallowedTools` empty. The `xihuai18/claude-code-mcp` (npm: `@leo000001/claude-code-mcp`) permission proxy uses `claude_code` for session management and `claude_code_check` (supporting `poll` and `respond_permission` actions) to surface each unresolved action to the supervisor. Compatibility is verified through the Codex runtime MCP catalog and real permission probes; this public project does not install or pin the MCP version. Approvals are for the current request and are not written back as persistent Claude settings.

Agent is ask-by-default. `-AllowNestedAgents` promotes Agent to allow only inside the delegated session, so enable it when parallel work has a clear payoff and bounded scope.

The legacy `AllowBroadWebFetch` input is still accepted for compatibility, but it no longer bypasses per-target review. This profile does not use Claude Code's `auto` permission mode; custom-provider deployments may not satisfy that mode's requirements, and explicit per-action review is easier to audit across providers.

Treat `maxTurns` as a requested boundary that must be checked against the returned usage and status. This SDK/provider combination has exceeded the requested value in testing, so scope drift, repeated reads, progress, and actual provider cost remain the practical stop signals.

Every new persistent worker name includes a workforce-profile version and a fingerprint derived from its launch repository root, origin, branch, and commit. `start` returns the locally sanitized source fields to Codex, but sends only the source kind and irreversible fingerprint in the CC prompt. `reply` recomputes the fingerprint and stops on an old unversioned worker or a changed fork/branch/commit. After manual review, `-AllowLegacySession` can resume a pre-version worker and `-AllowProvenanceDrift` can accept an intentional Git change. Existing processes do not inherit a newly installed profile retroactively; start a new worker when the permission model changes.

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
Install.ps1                # Install script
tests/
  Test-ClaudeWorkforce.ps1 # Parse check + runtime permission probe
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
