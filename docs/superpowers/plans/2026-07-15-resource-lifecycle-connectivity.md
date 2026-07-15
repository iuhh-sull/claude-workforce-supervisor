# Resource Lifecycle and Connectivity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a fail-safe lifecycle controller that reconciles workers before dispatch, tracks owned resources and port leases, recovers retryable API failures in the same session, and verifies cleanup after terminal states.

**Architecture:** Keep `claude-workforce.ps1` as the public command surface and move deterministic state, ownership, circuit-breaker, concurrency, and cleanup primitives into `workforce-lifecycle.ps1`. Persist only redacted fingerprints and resource metadata under `~/.codex/claude-workforce`; all destructive cleanup requires PID/start-time/session ownership agreement. Synchronous `run`/`reply` execute postflight immediately, while background workers are reconciled by `reconcile`, `cleanup`, `stop`, and `doctor`.

**Tech Stack:** PowerShell 7, Claude Code CLI 2.1.207+, JSON state files, the existing fake-Claude integration test harness, GitHub Actions.

## Global Constraints

- Stable active worker defaults are exactly low=2, medium=4, high=6.
- Burst limits are exactly low=3, medium=6, high=10 and are soft ceilings, never startup targets.
- Nested-agent limits are exactly low=0, medium=2, high=4.
- `ResourcePolicy` accepts `cleanup`, `retain-session`, and `keep-resources`; default is `retain-session`.
- `SessionRetentionPolicy` accepts `stop-on-complete`, `remove-on-complete`, `idle-ttl`, and `manual`; default is `stop-on-complete`.
- `ConcurrencyPolicy` accepts `fixed` and `adaptive`; default is `adaptive`.
- Retryable API failures recover at most once with the same session; 400/401/403/404, authentication, invalid-model, TLS-validation, DNS-configuration, and unsupported-endpoint failures never auto-retry.
- Force cleanup requires PID, process start time, executable, and session ownership to match; process-name-wide and port-only killing are forbidden.
- State and output never expose raw provider endpoints, prompts, credentials, or user-home paths.

---

### Task 1: Lifecycle State Primitives

**Files:**
- Create: `claude-workforce/scripts/workforce-lifecycle.ps1`
- Modify: `tests/Test-ClaudeWorkforce.ps1`

**Interfaces:**
- Consumes: `StateRoot`, namespace, cwd/endpoint fingerprints, worker/session identifiers, resource records.
- Produces: `Initialize-WorkforceState`, `Read-WorkforceState`, `Write-WorkforceState`, `Get-InvocationProfile`, `Get-WorkforceTaskFingerprint`, `Get-ApiFailureClassification`, `Get-ApiCircuitState`, `Update-ApiCircuitState`, `Test-WorkforceProcessOwnership`, `Invoke-WorkforceResourceCleanup`, and port-lease helpers.

- [ ] **Step 1: Add failing parser and state-contract assertions**

```powershell
$lifecyclePath = Join-Path $PSScriptRoot '..\claude-workforce\scripts\workforce-lifecycle.ps1'
[void][Management.Automation.Language.Parser]::ParseFile($lifecyclePath, [ref]$tokens, [ref]$errors)
$profile = Get-InvocationProfile -Level high
if ($profile.max_active_workers -ne 6 -or $profile.burst_max_workers -ne 10 -or $profile.max_nested_agents -ne 4) { throw 'High profile drifted.' }
```

- [ ] **Step 2: Run the test and confirm the module/function failure**

Run: `pwsh -NoProfile -File tests/Test-ClaudeWorkforce.ps1 -SkipHostRuntime`

Expected: FAIL because `workforce-lifecycle.ps1` or `Get-InvocationProfile` does not exist.

- [ ] **Step 3: Implement atomic JSON state and pure policy functions**

```powershell
function Get-InvocationProfile {
    param([ValidateSet('low','medium','high')][string]$Level)
    switch ($Level) {
        low { [pscustomobject]@{ max_active_workers = 2; burst_max_workers = 3; max_nested_agents = 0; startup_timeout_seconds = 120; idle_timeout_seconds = 300 } }
        medium { [pscustomobject]@{ max_active_workers = 4; burst_max_workers = 6; max_nested_agents = 2; startup_timeout_seconds = 120; idle_timeout_seconds = 600 } }
        high { [pscustomobject]@{ max_active_workers = 6; burst_max_workers = 10; max_nested_agents = 4; startup_timeout_seconds = 180; idle_timeout_seconds = 900 } }
    }
}
```

- [ ] **Step 4: Verify state, circuit, lease, and PID-reuse tests pass**

Run: `pwsh -NoProfile -File tests/Test-ClaudeWorkforce.ps1 -SkipHostRuntime`

Expected: PASS with `lifecycle_state`, `invocation_profiles`, `api_classification`, `port_lease`, and `pid_reuse_guard` set to `true`.

- [ ] **Step 5: Commit the independently testable state layer**

```bash
git add claude-workforce/scripts/workforce-lifecycle.ps1 tests/Test-ClaudeWorkforce.ps1
git commit -m "feat: add workforce lifecycle state primitives"
```

### Task 2: Reconcile and Concurrency Admission

**Files:**
- Modify: `claude-workforce/scripts/claude-workforce.ps1`
- Modify: `tests/Test-ClaudeWorkforce.ps1`

**Interfaces:**
- Consumes: Task 1 state helpers, Claude `agents --json --all`, `InvocationLevel`, `ConcurrencyPolicy`, task fingerprint.
- Produces: `Invoke-WorkforceReconcile` result with `reused_worker`, `duplicate_task_found`, cleanup counters, slots, circuit state, and `dispatch_allowed`; `reconcile`, `ports`, and `resources` actions.

- [ ] **Step 1: Add failing action and admission assertions**

```powershell
$reconcile = & $scriptPath -Action reconcile -StateRoot $stateRoot -InvocationLevel medium -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -Cwd $repoRoot -Prompt 'same task' -Role helper | ConvertFrom-Json
if ($reconcile.max_active_workers -ne 4 -or $reconcile.burst_max_workers -ne 6) { throw 'Medium limits are wrong.' }
if (-not $reconcile.reconcile_performed) { throw 'Reconcile audit flag is missing.' }
```

- [ ] **Step 2: Run and confirm `reconcile` is rejected by `ValidateSet`**

Run: `pwsh -NoProfile -File tests/Test-ClaudeWorkforce.ps1 -SkipHostRuntime`

Expected: FAIL with an invalid `Action` value or missing reconcile fields.

- [ ] **Step 3: Wire task fingerprints, duplicate prevention, and soft slots**

```powershell
$reconcile = Invoke-WorkforceReconcile -StateRoot $StateRoot -Namespace (Get-ThreadPrefix) -Cwd $resolvedCwd -Role $Role -TaskFingerprint $taskFingerprint -Workers $workers -InvocationLevel $InvocationLevel -ConcurrencyPolicy $ConcurrencyPolicy -CircuitKey $circuitKey
if (-not $reconcile.dispatch_allowed) { throw "Dispatch blocked: $($reconcile.dispatch_reason)" }
```

- [ ] **Step 4: Verify duplicate working tasks reuse the existing worker and circuit-open admission returns zero slots**

Run: `pwsh -NoProfile -File tests/Test-ClaudeWorkforce.ps1 -SkipHostRuntime`

Expected: PASS with `duplicate_dispatch_prevented`, `session_reused`, `adaptive_concurrency`, and `circuit_dispatch_blocked` true.

- [ ] **Step 5: Commit reconcile and admission control**

```bash
git add claude-workforce/scripts/claude-workforce.ps1 tests/Test-ClaudeWorkforce.ps1
git commit -m "feat: reconcile workers before dispatch"
```

### Task 3: Recovery, Postflight, and Verified Stop

**Files:**
- Modify: `claude-workforce/scripts/claude-workforce.ps1`
- Modify: `tests/Test-ClaudeWorkforce.ps1`

**Interfaces:**
- Consumes: Task 1 API classification/circuit/resource helpers and Task 2 reconcile result.
- Produces: same-session single recovery, result manifests, cleanup summaries, verified `stop`, `cleanup`, `doctor`, and daemon actions.

- [ ] **Step 1: Add failing retry/stop/postflight tests to fake Claude**

```powershell
if ($env:CF_TEST_API_MODE -eq 'retryable' -and '--resume' -notin $Remaining) { '{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"77777777-7777-4777-8777-777777777777","result":"ECONNREFUSED partial"}'; exit 1 }
if ($env:CF_TEST_API_MODE -eq 'retryable' -and '--resume' -in $Remaining) { '{"type":"result","subtype":"success","is_error":false,"session_id":"77777777-7777-4777-8777-777777777777","result":"RECOVERED"}'; exit 0 }
```

- [ ] **Step 2: Run and confirm no same-session recovery or verified cleanup exists**

Run: `pwsh -NoProfile -File tests/Test-ClaudeWorkforce.ps1 -SkipHostRuntime`

Expected: FAIL because `resume_used`, `postflight_completed`, and verified stop fields are absent.

- [ ] **Step 3: Implement one recovery attempt and fail-safe resource verification**

```powershell
$classification = Get-ApiFailureClassification -Text $firstResultText
if ($classification.retryable -and $sessionId -and -not $recoveryAttempted) {
    $recoveryAttempted = $true
    $arguments = New-SameSessionRecoveryArguments -SessionId $sessionId -Prompt 'Stop new tools; finalize from existing partial output.'
}
```

- [ ] **Step 4: Verify retryable errors resume once, 401/TLS never retry, partial output is retained, and stop never kills mismatched ownership**

Run: `pwsh -NoProfile -File tests/Test-ClaudeWorkforce.ps1 -SkipHostRuntime`

Expected: PASS with `same_session_recovery`, `nonretryable_no_retry`, `partial_output_preserved`, `postflight_cleanup`, `verified_stop`, and `ownership_mismatch_preserved` true.

- [ ] **Step 5: Commit recovery and cleanup behavior**

```bash
git add claude-workforce/scripts/claude-workforce.ps1 tests/Test-ClaudeWorkforce.ps1
git commit -m "feat: recover sessions and verify cleanup"
```

### Task 4: Session Profile and Operational Contracts

**Files:**
- Modify: `claude-workforce/scripts/new-workforce-session-profile.ps1`
- Modify: `claude-workforce/SKILL.md`
- Create: `claude-workforce/references/resource-lifecycle.md`
- Create: `claude-workforce/references/connectivity.md`
- Create: `claude-workforce/references/port-management.md`
- Create: `claude-workforce/references/invocation-levels.md`
- Create: `claude-workforce/references/operations.md`
- Create: `claude-workforce/references/troubleshooting.md`
- Modify: `tests/Test-ClaudeWorkforce.ps1`

**Interfaces:**
- Consumes: public parameters/actions from Tasks 1-3.
- Produces: session-only lifecycle metadata, MCP timeout separation, worker resource-manifest contract, operator runbooks.

- [ ] **Step 1: Add failing documentation marker and profile metadata assertions**

```powershell
foreach ($name in @('resource-lifecycle.md','connectivity.md','port-management.md','invocation-levels.md','operations.md','troubleshooting.md')) {
    if (-not (Test-Path (Join-Path $referencesPath $name))) { throw "Missing reference: $name" }
}
if ($mcpProfile.lifecycle.mcp_startup_timeout_seconds -le 0) { throw 'MCP startup timeout missing.' }
```

- [ ] **Step 2: Run and confirm reference/profile failures**

Run: `pwsh -NoProfile -File tests/Test-ClaudeWorkforce.ps1 -SkipHostRuntime`

Expected: FAIL on the first missing reference or lifecycle field.

- [ ] **Step 3: Add exact operational contracts and timeout metadata**

```powershell
lifecycle = [ordered]@{
    resource_policy = $ResourcePolicy
    session_retention_policy = $SessionRetentionPolicy
    mcp_startup_timeout_seconds = $McpStartupTimeoutSeconds
    mcp_idle_timeout_seconds = $McpIdleTimeoutSeconds
    mcp_tool_timeout_seconds = $McpToolTimeoutSeconds
}
```

- [ ] **Step 4: Verify all reference files, SKILL routing, and MCP timeout separation**

Run: `pwsh -NoProfile -File tests/Test-ClaudeWorkforce.ps1 -SkipHostRuntime`

Expected: PASS with `lifecycle_references`, `profile_lifecycle`, and `mcp_timeout_separation` true.

- [ ] **Step 5: Commit the profile and operator documentation**

```bash
git add claude-workforce/scripts/new-workforce-session-profile.ps1 claude-workforce/SKILL.md claude-workforce/references tests/Test-ClaudeWorkforce.ps1
git commit -m "docs: add workforce lifecycle operations"
```

### Task 5: Public Documentation and Release Validation

**Files:**
- Modify: `README.md`
- Modify: `README.zh-CN.md`
- Modify: `SECURITY.md`
- Modify: `tests/Test-ClaudeWorkforce.ps1`

**Interfaces:**
- Consumes: completed CLI and lifecycle behavior.
- Produces: bilingual usage examples, security ownership guarantees, complete fake-runtime and host-runtime verification.

- [ ] **Step 1: Add failing public-document marker assertions**

```powershell
foreach ($marker in @('reconcile','ResourcePolicy','SessionRetentionPolicy','daemon-restart-keep-workers','cleanup_status')) {
    if (-not $readmeText.Contains($marker, [StringComparison]::Ordinal)) { throw "README marker missing: $marker" }
}
```

- [ ] **Step 2: Run and confirm public docs are incomplete**

Run: `pwsh -NoProfile -File tests/Test-ClaudeWorkforce.ps1 -SkipHostRuntime`

Expected: FAIL on a missing CLI/policy marker.

- [ ] **Step 3: Document safe defaults, examples, and Windows ownership limits**

```text
retain-session preserves transcript metadata but releases temporary processes and ports.
Force cleanup requires matching PID, start time, executable, and session ownership; the wrapper never kills by process name or port alone.
```

- [ ] **Step 4: Run targeted and host validation**

Run: `pwsh -NoProfile -File tests/Test-ClaudeWorkforce.ps1 -SkipHostRuntime`

Expected: PASS and every result field true.

Run: `pwsh -NoProfile -File tests/Test-ClaudeWorkforce.ps1`

Expected: PASS when the installed Claude runtime satisfies version and capability requirements.

Run: `git diff --check`

Expected: no output and exit code 0.

- [ ] **Step 5: Commit the validated public contract**

```bash
git add README.md README.zh-CN.md SECURITY.md tests/Test-ClaudeWorkforce.ps1
git commit -m "docs: publish lifecycle and recovery contract"
```

## Self-Review

- Spec coverage: Tasks 1-3 cover P0, Tasks 2-4 cover P1, and state TTL/burst/audit/UI JSON in Tasks 1-3 cover P2.
- Placeholder scan: no implementation step contains TBD, TODO, “similar to”, or unspecified error handling.
- Type consistency: `InvocationLevel`, `ResourcePolicy`, `SessionRetentionPolicy`, circuit states, manifest fields, and audit fields use the exact names consumed by later tasks.
