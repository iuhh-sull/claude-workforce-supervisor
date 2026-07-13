# Claude Workforce

> Unofficial project. [中文说明](./README.zh-CN.md)

Manage persistent background Claude Code workers via the official `claude agents` supervisor. Each worker is an independent Claude Code conversation, and Codex (the supervisor) dispatches tasks, checks status, reclaims conversations, and verifies results.

## What problem does it solve

Many Codex-to-Claude integrations are one-shot calls. Once the command ends, the supervisor has no consistent status, log, and resume interface.

Workforce gives Codex a resumable background-session interface. You can inspect logs, stop or restart a worker, and continue the same conversation later. The underlying process does not have to stay alive permanently; the supervisor preserves recoverable state.

## Quick start

```powershell
# Install to ~/.codex/skills/claude-workforce
pwsh -NoProfile -File Install.ps1

# Use -Force only to back up and replace an existing installation
```

On first install, the script verifies PowerShell 7, checks required package files, and backs up any existing installation before overwriting.

After installation, you can create a private config at `~/.codex/claude-workforce.local.psd1`. It accepts exactly three keys:

```powershell
@{
    ClaudeExecutable   = "C:\path\to\claude.exe"
    ExpectedClaudeSha256 = "<64-char hex hash>"
    AllowBroadWebFetch = $true
}
```

Don't commit this file to a public repository. Precedence: CLI parameters > private file > environment variables > PATH.

## Usage

Check that your environment is ready:

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

# Smoke test (no tools, flash + low)
pwsh -NoProfile -File $workforce -Action start -Mode inspect `
  -NoTools -Effort low -Role smoke -Cwd "<project-path>" -Prompt "Reply only WORKFORCE_SMOKE_READY"
```

For status, logs, reply, attach, stop, and remove commands, see the full reference in [SKILL.md](./claude-workforce/SKILL.md).

### Model routing

Use `flash` + `medium` for retrieval, screening, formatting, smoke tests, and mechanical checks. Switch to `pro` + `high` for deeper diagnostics, security review, architecture decisions, and final acceptance. Reserve `max` for high-risk, multi-constraint tasks.

Choosing the right model isn't just a name swap — flash is cheaper and faster for bulk exploration; pro is slower but more reliable for judgment calls.

### Permission model

**Public search (allow by default):** `WebSearch`, Exa search, Tavily search/research. No confirmation needed.

**URL fetching (ask by default):** `WebFetch`, Exa fetch, Tavily extract/crawl/map, context-mode fetch. Each request goes through you. If you trust your environment, set `AllowBroadWebFetch = $true` in the private config to move these from ask to allow.

**Side-effecting tools (ask):** `Bash`, `Edit`, `Write`, `NotebookEdit` always prompt for confirmation.

**Credential stores (deny):** `.env`, `.ssh`, `.aws`, auth files, private keys, `.npmrc`, `.pypirc`, `.netrc`, `.docker/config.json`, `gh` config, and any `*credentials.json` / `*secrets.yaml` / `*.pem` / `*.key` — workers are blocked from reading, editing, or writing these paths.

**Global configuration:** Workers may read but must not modify the user's global configuration. If they encounter secret values, they must not echo or transmit them.

**Nested agents (deny → ask):** `Agent` is denied by default. Pass `-AllowNestedAgents` to move it from deny to ask — each nested agent request then prompts you. Don't enable this unless you have explicitly approved the additional parallelism and cost.

### Windows security note

Native Windows does not provide a full OS sandbox for Claude Code. Permission deny rules enforce constraints at the tool level, but they don't prevent file reads or process execution at the OS level. Don't rely on this as a security sandbox.

### Remove requires dual confirmation

```powershell
pwsh -NoProfile -File $workforce -Action remove -Id "<id>" `
  -ConfirmRemove -CheckedWorktree
```

`-ConfirmRemove` confirms you intend to delete. `-CheckedWorktree` confirms you've reviewed the worker status, logs, and any associated worktree for uncommitted changes. Both are required.

Only workers in terminal states (`stopped`, `completed`, `failed`, `error`, `dead`, `cancelled`, `exited`) can be removed. Stop a running worker first.

## Project layout

```
claude-workforce/
  SKILL.md                 # Codex skill definition, full reference
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

## How it differs

This is not a one-shot `claude -p` invocation: worker conversations remain resumable even when a process exits. It is an unofficial Codex skill around the official `agents` subcommand, not an MCP proxy or standalone CI/CD runner. Codex still dispatches tasks and verifies results.

## Uninstall

```powershell
$target = Join-Path $HOME '.codex\skills\claude-workforce'
if ((Split-Path -Leaf $target) -eq 'claude-workforce' -and (Test-Path -LiteralPath $target)) {
    Remove-Item -LiteralPath $target -Recurse -Force
}
```

If the installer created a backup (at `~/.codex/backups/claude-workforce-<date>`), you can restore it directly.
