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

- Tools and actions that are pre-allowed, ask-on-use, or denied
- The dual-confirmation requirement for worker removal
- Private configuration that can relax default URL-fetch restrictions
- Windows sandbox limitations

## Threat model and known limits

The project assumes that repository files, web pages, prompts, MCP responses, and worker output may be untrusted. It aims to prevent an unreviewed worker from silently performing common write, publish, credential-read, or destructive operations through Claude Code tools.

The permission layer is not an operating-system sandbox. A compromised Claude Code executable, wrapper, MCP server, hook, or dependency may operate outside these tool rules. Broad URL fetching can also reach unintended targets if explicitly enabled. Users should pin and audit custom wrappers, keep private configuration out of repositories, review every permission request, and run untrusted code only inside a separate OS-level sandbox or disposable environment.
