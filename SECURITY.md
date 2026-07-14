# Security Policy

## Supported Versions

This is an unofficial, community-maintained project. Security fixes are provided for the latest release only.

## Reporting a Vulnerability

**Please do not report security vulnerabilities via public GitHub issues.**

If you discover a security issue, report it through one of these channels:

1. **GitHub Private Vulnerability Reporting** — navigate to the repository's "Security" tab and use the "Report a vulnerability" button. This is the preferred method.

2. **Private contact** — if private reporting is unavailable, contact a maintainer through an established non-public channel. If none is listed, open a minimal public issue asking for private contact details without including vulnerability details, secrets, exploit code, or sensitive logs.

### What to include

- A clear description of the vulnerability
- Steps to reproduce (proof of concept, if available)
- Affected versions
- Any potential impact or exploit scenario

## Scope

This policy covers:

- The `claude-workforce` wrapper script (`scripts/claude-workforce.ps1`)
- The install script (`Install.ps1`)
- The included test script

The following are **out of scope**:

- Claude Code itself — report issues to Anthropic via their official security channel
- PowerShell 7 or the .NET runtime
- Third-party MCP servers integrated through configuration
- User-specific private configuration files (`.codex/claude-workforce.local.psd1`) — these are outside the project's control by design

## Security-relevant design properties

This project uses a layered permission model, not an OS sandbox. See the project README and SKILL.md for detailed documentation of the permission system, including:

- Tools and actions that are pre-allowed or surfaced for input-specific review
- The dual-confirmation requirement for worker removal
- Session-only settings that do not change the user's interactive Claude defaults
- MCP `canUseTool` permission review with no broad top-level allow or deny list
- Context profiles that keep MCP and local settings disabled unless explicitly requested
- Hard budget and usage reporting for synchronous `run`/`reply` calls
- Profile-version and Git provenance checks for persistent-session resume
- Windows sandbox limitations

## Threat model and known limits

The project assumes that repository files, web pages, prompts, MCP responses, and worker output may be untrusted. It aims to surface writes, publishing, sensitive reads, outbound local data, and destructive operations for a Codex supervisor to review through Claude Code settings and the maintained MCP permission proxy.

The permission layer is not an operating-system sandbox. A compromised Claude Code executable, wrapper, MCP server, or dependency may operate outside these tool rules. Public WebFetch requests can still target an unintended host if the supervisor approves the wrong input. Users should pin and audit custom wrappers, keep private configuration out of repositories, review sensitive or side-effecting requests, and run untrusted code only inside a separate OS-level sandbox or disposable environment. The legacy `AllowBroadWebFetch` key is accepted only for compatibility and grants no permission.

Sensitive paths use ask-on-use rather than a permanent deny so an explicitly authorized task can still proceed. Approval may place read content in a persistent Claude transcript; supervisors must approve only the minimum necessary input and require redacted output. Nested Agent/Task calls are session-scoped but can multiply the cost and reach of an approved action.

Official background `--bg` sessions do not support `--max-budget-usd`; the wrapper reports this limitation and rejects hard-budget parameters on `start` instead of claiming enforcement. Use bounded `run`, `reply`, or a supervising MCP client when a hard limit is required.

On synchronous timeout, the wrapper requests termination only for the process tree it started. A detached descendant can survive that best-effort cleanup, so operators should check process and provider state before resuming or retrying.

`EnableToolSearch` is opt-in because Claude Code may disable Tool Search behind a custom `ANTHROPIC_BASE_URL`, and an incompatible proxy can reject `tool_reference` blocks. Enable it only after a real MCP tool call succeeds through the current provider path, then repeat the probe after upgrading Claude Code, changing the provider, or replacing the proxy.
