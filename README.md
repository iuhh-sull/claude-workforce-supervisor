# Claude Workforce

> Unofficial project. [中文说明](./README.zh-CN.md)

Claude Workforce lets Codex manage background Claude Code workers through the official `claude agents` supervisor. Codex dispatches work, checks status and logs, and reviews the result. If a task is interrupted, the supervisor can resume its conversation later.

This unofficial Codex skill wraps the official `agents` subcommand. It is intended for research, code review, and background work completed in stages.

## Install

```powershell
pwsh -NoProfile -File Install.ps1
```

First install doesn't need `-Force`. Add `-Force` only to overwrite an existing installation; the script backs up the old directory first.

After install you can create a private config at `~/.codex/claude-workforce.local.psd1`. It accepts exactly four keys:

```powershell
@{
    ClaudeExecutable   = "C:\path\to\claude.exe"
    ExpectedClaudeSha256 = "<64-char hex hash>"
    AllowBroadWebFetch = $true
    EnableToolSearch = $true
}
```

Don't commit this file to a public repository. Precedence: CLI parameters > private file > environment variables > PATH.

`EnableToolSearch` only takes effect with `-ContextProfile full`, because the other profiles intentionally do not inherit MCP servers. `-NoTools` always keeps it disabled.

## Quick start

Verify the environment:

```powershell
$workforce = Join-Path $HOME '.codex\skills\claude-workforce\scripts\claude-workforce.ps1'
pwsh -NoProfile -File $workforce -Action capabilities
```

Use `run` for one-off work. Track actual DeepSeek spend with the post-run `-ProviderBudgetCny` soft threshold and bound execution primarily with `-MaxTurns`:

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

Do not add Codex/GPT and DeepSeek/CC tokens or prices together when judging quota savings. First measure the Codex context avoided by delegation, then subtract Codex dispatch, polling, targeted review, and rework; report DeepSeek spend separately. After CC returns, Codex should verify only the cited paths, lines, URLs, diff, and failures instead of rereading the same corpus. If a full reread is still required, treat the call as a second-opinion review, not a Codex-quota saving.

With a custom DeepSeek endpoint, the Claude Agent SDK may estimate `total_cost_usd` from Anthropic model prices. That number is not the provider bill. From the selected model, returned `usage`, and audited DeepSeek rates, the wrapper derives `provider_billing_tokens` (cache miss/cache hit/output), `provider_cost_components_cny` (three component costs), and total `provider_cost_estimate_cny`. The local decimal calculation does not ask CC to reread the task. If usage is incomplete, it reports insufficient evidence instead of guessing.

`-ProviderBudgetCny` is a post-run soft threshold for accounting and alerts. `-MaxBudgetUsd` remains available as an SDK-internal hard stop, but it does not represent a DeepSeek CNY budget. Official background `--bg` supports neither limit, so `start` does not claim a hard cap. `run` and `reply` require finite `-MaxTurns` plus at least one of `-ProviderBudgetCny` or `-MaxBudgetUsd`. Allow at least four turns for typical public research so discovery, tool execution, and the final response can complete.

DeepSeek's low provider price lowers the practical delegation threshold: consider CC around 5k tokens, three or more files, two or more independent searches, or a single huge/minified/generated file. Codex should usually handle ordinary changes within two files and roughly 3k tokens to avoid dispatch and review overhead.

Do not discard paid work after a budget stop. Preserve the session and usage, diagnose whether context, cache, tool turns, or output caused the overrun, then give the same session a small evidence-based finalization budget with instructions to stop using tools and compress the existing result. Do not start a fresh reread.

## Model routing

Use flash + low/medium for retrieval, extraction, formatting, smoke tests, and mechanical checks. Use pro + high for design, complex debugging, code-change plans, compatibility decisions, security review, architecture, and final acceptance. If a wrong judgment would cause meaningful rework, do not stay on flash merely to save model cost. Reserve max for high-risk multi-constraint tasks.

Route by error cost and expected rework, not only by input size. Higher effort spends more thinking tokens, so routine follow-up work should not inherit high/max from an earlier phase. Typical delivery estimates are 20–60 seconds for flash/low, 1–3 minutes for flash/medium, 3–8 minutes for pro/high, and 5–15 minutes for pro/max or multi-tool work. Check status near the expected milestone rather than polling continuously, except for permission requests or near-terminal work.

## Permissions

Public search (WebSearch, Exa search, Tavily search/research) is allowed by default. No prompt.

URL fetching (WebFetch, Exa fetch, Tavily extract/crawl/map, context-mode fetch) prompts by default. Set `AllowBroadWebFetch = $true` in the private config to skip the prompt if you trust your environment.

Bash, Edit, Write, NotebookEdit always prompt.

Credential stores (.env, .ssh, .aws, auth files, private keys, .npmrc, .pypirc, .netrc, .docker/config.json, gh config, `*credentials.json`, `*secrets.yaml`, `*.pem`, `*.key`) are blocked from read, edit, and write.

Global config: workers can read but not modify. If they encounter secrets, they must not echo or transmit them.

Nested agents are denied by default. Pass `-AllowNestedAgents` to change to ask-per-use. Don't enable unless you need the parallelism.

## Windows note

Native Windows doesn't provide a full OS sandbox for Claude Code. Permission deny rules enforce at the tool level, not at the OS level. Don't rely on this for sandboxing.

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
