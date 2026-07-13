# Claude Workforce

> Unofficial project. [中文说明](./README.zh-CN.md)

Claude Workforce lets Codex manage background Claude Code workers through the official `claude agents` supervisor. Codex dispatches work, checks status and logs, and reviews the result. If a task is interrupted, the supervisor can resume its conversation later.

This unofficial Codex skill wraps the official `agents` subcommand. It is intended for research, code review, and background work completed in stages.

## Install

```powershell
pwsh -NoProfile -File Install.ps1
```

First install doesn't need `-Force`. Add `-Force` only to overwrite an existing installation; the script backs up the old directory first.

After install you can create a private config at `~/.codex/claude-workforce.local.psd1`. It accepts exactly three keys:

```powershell
@{
    ClaudeExecutable   = "C:\path\to\claude.exe"
    ExpectedClaudeSha256 = "<64-char hex hash>"
    AllowBroadWebFetch = $true
}
```

Don't commit this file to a public repository. Precedence: CLI parameters > private file > environment variables > PATH.

## Quick start

Verify the environment:

```powershell
$workforce = Join-Path $HOME '.codex\skills\claude-workforce\scripts\claude-workforce.ps1'
pwsh -NoProfile -File $workforce -Action capabilities
```

Start a worker:

```powershell
# Research mode, flash model, medium effort
pwsh -NoProfile -File $workforce -Action start -Mode inspect `
  -Model "deepseek-v4-flash[1m]" -Effort medium -Role researcher `
  -Cwd "<project-path>" -Prompt "Investigate root cause, list evidence, do not modify files"

# Implementation mode, pro model, high effort
pwsh -NoProfile -File $workforce -Action start -Mode write `
  -Model "deepseek-v4-pro[1m]" -Effort high -Role implementer `
  -Cwd "<git-project-path>" -Prompt "Implement the change and run targeted tests"

# Smoke test (no tools, flash + low to save cost)
pwsh -NoProfile -File $workforce -Action start -Mode inspect `
  -NoTools -Effort low -Role smoke -Cwd "<project-path>" -Prompt "Reply only WORKFORCE_SMOKE_READY"
```

For status, log, reply, stop, and remove commands, see [SKILL.md](./claude-workforce/SKILL.md).

## Model routing

Use flash + medium for retrieval, screening, formatting, and smoke tests. Switch to pro + high for deeper diagnostics, security review, and architecture calls. Reserve max for high-risk multi-constraint tasks.

Flash is cheap and fast for exploration. Pro is slower but more reliable for judgment.

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
