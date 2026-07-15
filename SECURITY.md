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
- The lifecycle state and ownership module (`scripts/workforce-lifecycle.ps1`)
- The state transaction, resource broker, timeout, and reaper modules (`scripts/workforce-state.ps1`, `scripts/workforce-resource-broker.ps1`, `scripts/workforce-timeouts.ps1`, and `scripts/workforce-reaper.ps1`)
- The session profile generator and shipped provider-pricing metadata
- The install script (`Install.ps1`)
- The included deterministic test suites and CI workflows

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
- Strict/balanced/delegated trust profiles with hooks disabled by default
- None/advisory/hard budget policies, `MaxTurns=0` omission, and same-session limit finalization
- Wrapper-enforced startup/idle/hard process timeouts with partial-output preservation
- Profile-version and Git provenance checks for persistent-session resume
- Windows sandbox limitations
- Supervisor-only schema-v2 Manifests with locked atomic writes, revision CAS, backups, migration, and rollback
- Untrusted worker reports that cannot create ownership or trusted resources
- Capability-bound resource registration and HMAC-signed process, port, and MCP records
- Provider/endpoint-fingerprint/model circuit breakers
- Reaper convergence for terminal/stale workers and `cleanup-incomplete` blockers
- PID-reuse-safe cleanup requiring broker signature, safe key ACL, Manifest/session, PID/start time/executable/descendant identity, and listener PID

## Threat model and known limits

The project assumes that repository files, web pages, prompts, MCP responses, worker output, worker reports, and on-disk state may be untrusted. Only the supervisor may write authoritative Manifests. Worker reports are parsed through a small allowlist and never establish resource ownership, cleanup success, or a trusted terminal result by themselves. Trusted resources require broker registration during the bound session.

The permission layer is not an operating-system sandbox. A compromised Claude Code executable, wrapper, hook, MCP server, or dependency may operate outside these tool rules. Hooks are disabled in every generated session by default; `-AllowHooks` merely permits inherited hooks and must be used only after they are reviewed. Public WebFetch requests can still target an unintended host if the supervisor approves the wrong input. Users should pin and audit custom wrappers, keep private configuration out of repositories, review sensitive or side-effecting requests, and run untrusted code only inside a separate OS-level sandbox or disposable environment. The legacy `AllowBroadWebFetch` key is accepted only for compatibility and grants no permission.

Sensitive paths use ask-on-use rather than a permanent deny so an explicitly authorized task can still proceed. Approval may place read content in a persistent Claude transcript; supervisors must approve only the minimum necessary input and require redacted output. Nested Agent/Task calls are session-scoped but can multiply the cost and reach of an approved action.

Official background `--bg` sessions do not support `--max-budget-usd`; the wrapper reports this limitation and rejects hard-budget parameters on `start` instead of claiming enforcement. `BudgetPolicy advisory` never interrupts an active run, and stale/unknown provider pricing cannot support a definite cost decision. Use bounded `run`, `reply`, or a supervising MCP client when a hard limit is required.

For synchronous execution, the wrapper separately enforces startup, idle, and hard deadlines, preserves partial stdout/stderr, and attempts one same-session no-tools finalize. Cleanup acts only on broker-verified resources. A detached or unverifiable descendant can survive because fail-closed ownership is preferred over killing an unrelated process; operators must inspect `cleanup_status` before resuming or retrying.

Lifecycle cleanup never kills by process name, worker report, Manifest text, or port alone. Broker resources and port leases carry an HMAC derived from a local 32-byte `broker.key`; capability tokens are stored only as hashes and must never be logged or persisted. Force cleanup fails closed unless the broker signature, key ACL, Manifest/session binding, PID, process start time, executable, descendant chain, listener PID, and ownership fingerprint all match. An unsigned, tampered, legacy-unverified, listener-mismatched, or unleased resource is treated as unowned.

State files can be deleted, rolled back, or tampered with by the local user or malware. Atomic replace, `.bak` recovery, state locks, revision CAS, schema migration backups, HMAC, and doctor diagnostics reduce accidental corruption; they do not protect against an attacker who can modify both code and local secrets. Keep the state root private, do not sync `broker.key`, and stop dispatch when doctor reports unsafe ACLs, corruption, migration requirements, signature failures, or unresolved cleanup.

State under `~/.codex/claude-workforce/` contains fingerprints, worker/session identifiers, TTLs, and resource metadata. It must not contain secrets, raw prompts, or raw private endpoints. The `resources` action runs state through the output redaction pipeline, but operators must still avoid placing credentials in resource purpose or command-summary fields.

`EnableToolSearch` is opt-in because Claude Code may disable Tool Search behind a custom `ANTHROPIC_BASE_URL`, and an incompatible proxy can reject `tool_reference` blocks. Enable it only after a real MCP tool call succeeds through the current provider path, then repeat the probe after upgrading Claude Code, changing the provider, or replacing the proxy.
