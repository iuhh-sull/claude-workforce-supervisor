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

Use a hard-capped `run` for one-off work:

```powershell
# Text or numeric judgment: minimal context, no tools, no retained session after success
pwsh -NoProfile -File $workforce -Action run -Mode inspect -NoTools -Ephemeral `
  -ContextProfile minimal -MaxTurns 1 -MaxBudgetUsd 1 `
  -Model "deepseek-v4-flash[1m]" -Effort low `
  -Cwd "<project-path>" -Prompt "Return only the requested verdict"

# Public research: retain the session so a turn or budget error can be resumed
pwsh -NoProfile -File $workforce -Action run -Mode inspect `
  -ContextProfile project -MaxTurns 4 -MaxBudgetUsd 2 `
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

Official background `--bg` does not support `--max-budget-usd`, so `start` does not pretend to enforce a hard cap. Use `run` or an MCP client with budget and permission handling when a hard limit matters. `reply` also requires explicit `-MaxTurns` and `-MaxBudgetUsd`. Allow at least four turns for a typical public search so tool discovery, tool execution, and the final answer can all complete.

## Model routing

Use flash + medium for retrieval, screening, formatting, and smoke tests. Switch to pro + high for deeper diagnostics, security review, and architecture calls. Reserve max for high-risk multi-constraint tasks.

Flash is cheap and fast for exploration. Pro is slower but more reliable for judgment. Higher effort also spends more thinking tokens, so routine follow-up work should not inherit high/max from an earlier phase.

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
