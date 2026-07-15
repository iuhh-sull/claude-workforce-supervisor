# Workforce permission profiles

`scripts/new-workforce-session-profile.ps1` generates settings for one delegated
Claude Code session. It does not write to `~/.claude/settings.json` and it never
enables bypass, auto-approval, or `dontAsk` modes.

## Trust profiles

`-TrustProfile` accepts `strict`, `balanced`, or `delegated`; the default is
`balanced`.

| Capability | strict | balanced | delegated |
|---|---|---|---|
| Read, Glob, Grep, WebSearch, Plan | allow | allow | allow |
| Sensitive reads (`.env`, auth/settings files, private keys) | ask | ask | ask |
| Edit/Write/NotebookEdit under the session CWD | ask | allow | allow |
| Edit/Write outside the session CWD | ask | ask/default decision | ask/default decision |
| Git status/diff/log/show and file enumeration | ask | allow | allow |
| Common test/lint/build commands | ask | allow | allow |
| Additional type-check/format/static-check commands | ask | ask/default decision | allow |
| Package installation or destructive commands | ask | ask | ask |
| Commit, push, PR/release creation, publish, or deploy | ask | ask | ask |
| WebFetch | ask | ask | ask |
| Nested Agent/Task | ask | ask | ask |

The worktree grant uses `Edit(./**)`, `Write(./**)`, and
`NotebookEdit(./**)`, relative to the delegated session CWD. Paths through
`../` or `~/` are explicitly reviewable. Other unmatched paths and commands
fall back to Claude Code's permission-mode decision and the MCP
`canUseTool`/`respond_permission` flow.

The balanced and delegated Bash allowlists intentionally contain bounded native
Claude Code command patterns instead of a broad `Bash` allow. A broad grant
would also authorize shell-based writes outside the worktree on systems without
a complete OS sandbox. Delegated adds common type-check, formatter, and static
analysis commands; arbitrary project scripts and temporary servers remain
reviewable until the supervisor can verify their sandbox and resource-broker
registration.

`WebFetch` remains reviewable in every profile. Static permission settings
cannot reliably classify every public URL while excluding loopback, private,
credential-bearing, or local-data-exfiltration targets. The supervisor may
approve a specific public target for the current request, but must not persist
that decision.

## Hooks

All context profiles (`minimal`, `user`, `project`, and `full`) emit
`disableAllHooks: true` by default. `-AllowHooks` removes that key entirely; it
does not write `false`, so higher-priority managed settings are not overridden.
`full` means configuration and MCP inheritance, not hook approval.

`-NoTools` is enforced by the wrapper and still forces the minimal safe-mode
path, which disables hooks and removes tools regardless of the selected trust
profile. `-AllowHooks` must not be used to weaken `-NoTools`.

## Nested agents and high-risk boundaries

Agent and Task remain in `ask` for all three profiles. Passing
`-AllowNestedAgents` removes only those two rules from `ask` and adds them to
`allow`; it does not broaden Bash, writes, network access, credentials, install,
publish, or deploy permissions.

The profile keeps top-level MCP `allowedTools` and `disallowedTools` empty so
unresolved actions reach the supervisor. Sensitive access, external writes,
installation, destructive commands, Git push, publishing, and deployment
require an input-specific decision. Approval must be limited to the current
request and must not be written back to persistent user settings.
