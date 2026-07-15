# Claude Workforce Supervisor Full Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the remaining ownership, state-concurrency, background-finalization, permission, budget, timeout, parser, installer, and CI release blockers described in `claude-workforce-supervisor-full-remediation-plan.md`.

**Architecture:** Keep `claude-workforce.ps1` as the public CLI, split durable state transactions into `workforce-state.ps1`, broker-verified resources into `workforce-resource-broker.ps1`, process timeout monitoring into `workforce-timeouts.ps1`, and idempotent background finalization into `workforce-reaper.ps1`. Per-manifest JSON files become authoritative; all shared read-modify-write operations use named mutex transactions, and destructive cleanup requires a valid broker signature plus live process identity checks.

**Tech Stack:** PowerShell 7, JSON state schema v2, Windows named mutexes, SHA-256/HMAC-SHA256, the existing fake-Claude integration harness, GitHub Actions.

## Global Constraints

- `manifests/*.json` is the only authoritative manifest store; `resource-index.json` is migration input only.
- Every shared JSON read-modify-write uses a bounded cross-process lock and atomic replacement with one `.bak` generation.
- Worker reports are untrusted; only the supervisor resource broker writes trusted process, port, and MCP ownership records.
- Force cleanup requires a valid broker signature, matching manifest/session/worker, PID start time, and executable hash.
- `MaxTurns=0` means omit `--max-turns`; only `BudgetPolicy=hard` requires and forwards `MaxBudgetUsd`.
- Hooks are disabled by default for every context profile; `AllowHooks` removes the override instead of writing `false`.
- The minimum fully supported Claude Code version is `2.1.208`.
- Real host-runtime tests remain opt-in because they can touch user Claude state, create sessions, use the network, and incur provider cost.

---

### Task 1: Transactional State and Manifest Schema

**Files:**
- Create: `claude-workforce/scripts/workforce-state.ps1`
- Modify: `claude-workforce/scripts/workforce-lifecycle.ps1`
- Modify: `tests/Test-ClaudeWorkforce.ps1`

**Interfaces:**
- Produces: `Enter-WorkforceStateLock`, `Exit-WorkforceStateLock`, `Invoke-WorkforceStateTransaction`, `Read-WorkforceState`, `Write-WorkforceState`, `Update-WorkforceState`, `Invoke-WorkforceStateMigration`.
- Produces: schema-v2 manifests with `revision`, legal state transitions, compare-and-swap saves, and filesystem enumeration as the source of truth.

- [ ] **Step 1: Add failing lock, CAS, source-of-truth, and migration tests**

Create isolated state roots, run eight `pwsh` processes that update shared arrays/counters, and assert no lost records, valid JSON, one winner for same-revision CAS, index deletion tolerance, illegal-transition rejection, and v1 ownership migration to `legacy-unverified`.

- [ ] **Step 2: Run the focused suite and confirm missing state APIs**

Run: `pwsh -NoProfile -File tests/Test-ClaudeWorkforce.ps1 -SkipHostRuntime`

Expected: FAIL on the first missing transaction or schema-v2 assertion.

- [ ] **Step 3: Implement locked atomic state primitives**

Use `Local\ClaudeWorkforce-<state-hash>-<lock-hash>` mutex names, a 15-second default wait, same-thread reentrancy accounting, `AbandonedMutexException` recovery, UTF-8 atomic replacement, and a single `.bak` before replacement.

- [ ] **Step 4: Move manifests to filesystem authority**

`Get-WorkforceManifests` enumerates and validates `manifests/*.json`; `Save-WorkforceManifest` locks `manifest-<id>`, verifies `ExpectedRevision`, validates the state transition, increments `revision`, and writes only the manifest file.

- [ ] **Step 5: Re-run focused tests**

Run: `pwsh -NoProfile -File tests/Test-ClaudeWorkforce.ps1 -SkipHostRuntime`

Expected: state lock, manifest authority, CAS, migration, and concurrency fields are `true`.

### Task 2: Trusted Resource Broker and Port Binding

**Files:**
- Create: `claude-workforce/scripts/workforce-resource-broker.ps1`
- Modify: `claude-workforce/scripts/workforce-lifecycle.ps1`
- Modify: `claude-workforce/scripts/claude-workforce.ps1`
- Modify: `tests/Test-ClaudeWorkforce.ps1`

**Interfaces:**
- Produces: `New-WorkforceResourceCapability`, `Register-WorkforceProcess`, `Register-WorkforcePort`, `Register-WorkforceMcpEndpoint`, `Unregister-WorkforceResource`, `Get-WorkforceOwnedResources`, `Test-WorkforceResourceOwnership`, `Stop-WorkforceOwnedResource`.
- Consumes: state transactions and manifest/session/worker identity.

- [ ] **Step 1: Add forgery and cleanup-negative tests**

Assert rejection for token mismatch, signature tampering, session mismatch, PID reuse, executable mismatch, missing broker key, non-descendant process, and a port owned by another process.

- [ ] **Step 2: Implement broker key and capability handling**

Generate 32 random bytes, store the broker key outside manifests, restrict and verify Windows ACLs where supported, keep only token SHA-256 in state, inject raw capability tokens only into the launched process environment, and redact tokens/keys from all outputs.

- [ ] **Step 3: Implement signed resource registration**

Canonicalize the signed fields, HMAC them, verify descendant or explicitly controlled ownership, persist one broker resource per file, and expose wrapper actions `register-process`, `register-port`, `register-mcp`, and `unregister-resource`.

- [ ] **Step 4: Replace manifest self-registration and port-only trust**

Prompts point workers to the broker/report contract instead of editing authoritative manifests. Leases use `requested/reserved/bound/released/expired/conflict`, and only a verified broker resource may transition a lease to `bound`.

- [ ] **Step 5: Verify cleanup fails closed**

Run: `pwsh -NoProfile -File tests/Test-ClaudeWorkforce.ps1 -SkipHostRuntime`

Expected: broker forgery tests pass and unrelated Node/Python/listener probes remain alive.

### Task 3: Reconcile, Reaper, Cleanup, and Retention

**Files:**
- Create: `claude-workforce/scripts/workforce-reaper.ps1`
- Modify: `claude-workforce/scripts/workforce-lifecycle.ps1`
- Modify: `claude-workforce/scripts/claude-workforce.ps1`
- Modify: `tests/Test-ClaudeWorkforce.ps1`

**Interfaces:**
- Produces: `ConvertTo-WorkforceWorkerState`, success/failure/stale/corrupt reconcile classes, idempotent postflight, and `Invoke-WorkforceReaper`.
- Consumes: broker cleanup and schema-v2 manifest CAS.

- [ ] **Step 1: Add failed-cache and stale-cross-check tests**

Cover failed/cancelled/error results, completed results with `is_error=true`, cleanup blockers, missing roster workers, roster-only workers, terminal workers with running manifests, and unknown worker states.

- [ ] **Step 2: Implement explicit reconcile categories**

Return `successful_manifest`, `recovery_manifest`, `previous_failure`, and `cleanup_blocker`; only a clean successful completion is reusable, while a recoverable failed session is resumable but never returned as cached success.

- [ ] **Step 3: Implement idempotent reaper flow**

Acquire a global reaper mutex, consume only roster plus manifest/report summaries, move terminal or absent workers to `finalizing`, invoke broker cleanup, verify resources/ports, apply retention only after cleanup, and persist the terminal state once.

- [ ] **Step 4: Implement real strategy-driven cleanup**

Honor registered `stdin-close`, `ctrl-break`, `command`, `http-shutdown`, `process-handle`, `job-object`, and broker-verified `kill-tree` strategies in order; return per-resource graceful/force/verification fields.

- [ ] **Step 5: Verify background convergence**

Run: `pwsh -NoProfile -File tests/Test-ClaudeWorkforce.ps1 -SkipHostRuntime`

Expected: failed cache, stale reconciliation, reaper idempotency, terminal postflight, and retention-after-cleanup fields are `true`.

### Task 4: Permissions, Budgets, Timeouts, Metadata, and Parsers

**Files:**
- Create: `claude-workforce/scripts/workforce-timeouts.ps1`
- Create: `claude-workforce/config/provider-pricing.psd1`
- Modify: `claude-workforce/scripts/new-workforce-session-profile.ps1`
- Modify: `claude-workforce/scripts/claude-workforce.ps1`
- Modify: `tests/Test-ClaudeWorkforce.ps1`

**Interfaces:**
- Produces: `TrustProfile`, `AllowHooks`, `BudgetPolicy`, auto-finalize metadata, startup/idle/hard timeout enforcement, reply metadata inheritance, cached capability probes, stale pricing output, and robust JSON candidate parsing.

- [ ] **Step 1: Add argument/profile/parser/timeout tests**

Assert hooks default off, trust-profile permission matrices, `MaxTurns=0` omission, hard-budget validation, advisory non-blocking behavior, single same-session finalize, startup/idle/hard timeout classification, metadata inheritance, pricing staleness, canonical attach ID, and JSON with prefixes/trailing logs/embedded brackets.

- [ ] **Step 2: Generate trust-profile settings**

`strict` keeps writes/shell/fetch reviewable; `balanced` allows worktree editing and bounded read-only/test commands while preserving external/sensitive/publish boundaries; `delegated` allows sandboxed worktree execution but still blocks or asks for install, credentials, external writes, push, deploy, and destructive actions.

- [ ] **Step 3: Implement budget and finalize semantics**

Only append `--max-turns` when positive; enforce `MaxBudgetUsd` only for hard policy; treat provider budgets as advisory; after limit/timeout/context termination, attempt one `NoTools` same-session finalization with at most `FinalizeMaxTurns` and record the attempt.

- [ ] **Step 4: Enforce process timeouts and preserve partial output**

Use asynchronous output events to track process start, first output, last output, and hard deadline; stop the owned process tree on timeout, preserve bounded output, and report whether each timeout is configured, enforced, or report-only.

- [ ] **Step 5: Cache capabilities and harden JSON parsing**

Key capability cache by executable path hash, executable SHA-256, and version with a 24-hour TTL; parse complete JSON candidates without bracket slicing and reject non-whitespace trailing content except recognized log lines.

### Task 5: Packaging, Documentation, CI, and Release Validation

**Files:**
- Modify: `Install.ps1`
- Modify: `.github/workflows/test.yml`
- Create: `.github/workflows/host-integration.yml`
- Modify: `claude-workforce/SKILL.md`
- Create/Modify: `claude-workforce/references/*.md`
- Modify: `README.md`
- Modify: `README.zh-CN.md`
- Modify: `SECURITY.md`
- Modify: `tests/Test-ClaudeWorkforce.ps1`

**Interfaces:**
- Produces: complete install/rollback validation, portable CI, manual self-hosted host integration, concise SKILL routing, and synchronized public/security contracts.

- [ ] **Step 1: Update installer and CI coverage**

Require every new script/config/reference, include `Install.ps1` in workflow path filters, parse every `.ps1`, run fake-runtime plus concurrency tests, set least-privilege workflow permissions, upload test results, and keep real Claude integration manual/self-hosted.

- [ ] **Step 2: Split long-form guidance from SKILL**

Keep the core SKILL within 120-180 lines and route detailed permissions, lifecycle, ports, connectivity, budget/timeouts, operations, troubleshooting, and security guidance to references.

- [ ] **Step 3: Synchronize README and SECURITY**

Document Beta/RC status truthfully, broker trust boundaries, state schema/migration, hooks, trust profiles, budget semantics, timeout enforcement, reaper operation, cleanup failure modes, and real-host test risks.

- [ ] **Step 4: Run portable validation**

Run: `pwsh -NoProfile -File tests/Test-ClaudeWorkforce.ps1 -SkipHostRuntime`

Run: parse every repository `.ps1` with `System.Management.Automation.Language.Parser`.

Run: `git -c safe.directory=D:/Git/claude-workforce-supervisor -C D:/Git/claude-workforce-supervisor diff --check`

Expected: all commands succeed; no secrets, user paths, cache files, generated state, or large artifacts appear in the diff.

- [ ] **Step 5: Leave real-host validation opt-in**

Do not run the real host runtime without explicit user confirmation after explaining that it can read/write Claude user state, create real sessions/workers, access the network, and incur provider cost.

## Self-Review

- Spec coverage: Tasks 1-3 cover every P0 state, ownership, background, cleanup, port, and concurrency blocker; Task 4 covers the P1 runtime contract; Task 5 covers P2 packaging, documentation, CI, and host validation boundaries.
- Placeholder scan: every step names the concrete functions, state transitions, test cases, files, commands, and expected result; no deferred implementation placeholders remain.
- Type consistency: schema version, revision, manifest states, trust profiles, budget policies, timeout names, broker identifiers, and reconcile output fields use the same names throughout all tasks.
