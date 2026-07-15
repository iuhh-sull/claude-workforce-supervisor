[CmdletBinding()]
param(
    [switch]$SkipRuntime,
    [switch]$SkipHostRuntime,
    [switch]$TraceStages,
    [string]$TracePath,
    [string]$HostClaudeExecutable,
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$HostClaudeSha256
)

function Write-TestStage {
    param([Parameter(Mandatory = $true)][string]$Name)

    if ($TraceStages) {
        $line = "TEST_STAGE:$Name"
        Write-Host $line
        if (-not [string]::IsNullOrWhiteSpace($script:TraceFilePath)) {
            [IO.File]::AppendAllText($script:TraceFilePath, "$line$([Environment]::NewLine)", [Text.UTF8Encoding]::new($false))
        }
    }
}

$ErrorActionPreference = 'Stop'
$script:TraceFilePath = $null
if (-not [string]::IsNullOrWhiteSpace($TracePath)) {
    $script:TraceFilePath = [IO.Path]::GetFullPath($TracePath)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($script:TraceFilePath))
    [IO.File]::WriteAllText($script:TraceFilePath, '', [Text.UTF8Encoding]::new($false))
}
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'Tests require PowerShell 7 or higher.'
}

$scriptPath = Join-Path $PSScriptRoot '..\claude-workforce\scripts\claude-workforce.ps1'
$profilePath = Join-Path $PSScriptRoot '..\claude-workforce\scripts\new-workforce-session-profile.ps1'
$lifecyclePath = Join-Path $PSScriptRoot '..\claude-workforce\scripts\workforce-lifecycle.ps1'
$installPath = Join-Path $PSScriptRoot '..\Install.ps1'
foreach ($path in @($scriptPath, $profilePath, $lifecyclePath, $installPath)) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        throw "PowerShell parser found $($errors.Count) error(s) in ${path}: $($errors[0].Message)"
    }
}

$sourceText = Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8
$forbidden = @(
    'bypassPermissions',
    'acceptEdits',
    'dontAsk',
    'LaunchProvenance: remote=',
    ('C:' + [IO.Path]::DirectorySeparatorChar + 'Users' + [IO.Path]::DirectorySeparatorChar),
    ('D:' + [IO.Path]::DirectorySeparatorChar + 'Git' + [IO.Path]::DirectorySeparatorChar)
)
foreach ($marker in $forbidden) {
    if ($sourceText.Contains($marker, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Forbidden marker found in public script: $marker"
    }
}

$requiredMarkers = @(
    "'run'",
    'ContextProfile',
    'MaxTurns',
    'MaxBudgetUsd',
    'ProviderBudgetCny',
    'IncludeSdkCostEstimate',
    'MaxMcpOutputTokens',
    'ProcessTimeoutSeconds',
    'EnableToolSearch',
    '--max-turns',
    '--max-budget-usd',
    '--no-chrome',
    'total_cost_usd',
    'provider_cost_estimate_cny',
    'provider_cost_estimate',
    'provider_cost_currency',
    'provider_budget_limit',
    'provider_cost_exceeds_budget',
    'provider_billing_tokens',
    'provider_cost_components_cny',
    'result_subtype',
    'usage'
    "'reconcile'"
    'ResourcePolicy'
    'SessionRetentionPolicy'
    'InvocationLevel'
    'ConcurrencyPolicy'
    'ForceOwnedResources'
    'partial_output_recovered'
    'owned_processes_remaining'
    'owned_ports_remaining'
    'cleanup_status'
)
foreach ($marker in $requiredMarkers) {
    if (-not $sourceText.Contains($marker, [StringComparison]::Ordinal)) {
        throw "Required cost-control marker is missing: $marker"
    }
}

$result = [ordered]@{
    parser = $true
    no_machine_paths = $true
    installer_boundary = $false
    cost_controls = $true
    background_budget_guard = $false
    nonzero_usage_recovery = $false
    missing_usage_recovery = $false
    provider_cost_estimate = $false
    provider_soft_budget = $false
    reply_model_guard = $false
    reply_write_mode_guard = $false
    reply_effort_guard = $false
    reply_success_output = $false
    start_success_output = $false
    start_roster_verified = $false
    log_redaction_pem_block = $false
    log_redaction_github_token = $false
    log_redaction_aws_key = $false
    list_success_output = $false
    no_tools_project_forced_minimal = $false
    no_tools_full_forced_minimal = $false
    roster_empty_parsed = $false
    roster_compact_parsed = $false
    roster_log_prefix_compact_parsed = $false
    roster_log_prefix_pretty_parsed = $false
    roster_ansi_multi_bracket_parsed = $false
    roster_trailing_logs_rejected = $false
    result_multi_json_selected = $false
    max_turns_zero_omitted = $false
    capability_cache_ttl_hash = $false
    attach_canonical_id = $false
    timeout_same_session_finalize = $false
    mcp_profile = $false
    local_remote_redacted = $false
    credential_remote_redacted = $false
    posix_local_remote_redacted = $false
    unknown_model_not_rejected = $false
    unknown_model_pricing_null = $false
    unknown_model_soft_budget_guard = $false
    unknown_model_explicit_override = $false
    namespace_override = $false
    namespace_scope_filter = $false
    namespace_fallback = $false
    lifecycle_state = $false
    invocation_profiles = $false
    api_classification = $false
    mcp_classification = $false
    circuit_breaker = $false
    adaptive_concurrency = $false
    port_lease = $false
    unowned_port_preserved = $false
    pid_reuse_guard = $false
    ownership_fingerprint_guard = $false
    duplicate_dispatch_prevented = $false
    same_session_recovery = $false
    nonretryable_no_retry = $false
    partial_output_preserved = $false
    postflight_cleanup = $false
    mcp_same_session_recovery = $false
    verified_stop = $false
    retention_safety = $false
    profile_lifecycle = $false
    timeout_profile_linkage = $false
    lifecycle_references = $false
    public_lifecycle_docs = $false
    cmd_shim = -not $IsWindows
    runtime = -not $SkipRuntime
    host_runtime = -not $SkipHostRuntime
}

. $lifecyclePath
$stateRoot = Join-Path ([IO.Path]::GetTempPath()) "claude-workforce-state-$([guid]::NewGuid().ToString('N'))"
$previousStateRoot = $env:CLAUDE_WORKFORCE_STATE_ROOT
$env:CLAUDE_WORKFORCE_STATE_ROOT = $stateRoot
$paths = Initialize-WorkforceState -StateRoot $stateRoot
if (-not (Test-Path -LiteralPath $paths.port_leases -PathType Leaf) -or
    -not (Test-Path -LiteralPath $paths.circuit_breakers -PathType Leaf) -or
    -not (Test-Path -LiteralPath $paths.state_version -PathType Leaf) -or
    -not (Test-Path -LiteralPath $paths.manifests -PathType Container) -or
    -not (Test-Path -LiteralPath $paths.worker_reports -PathType Container) -or
    -not (Test-Path -LiteralPath $paths.broker_resources -PathType Container) -or
    (Test-Path -LiteralPath $paths.resource_index -PathType Leaf)) {
    throw 'Lifecycle state files were not initialized.'
}
if (@(Get-WorkforcePortLeases -StateRoot $stateRoot).Count -ne 0 -or @(Get-WorkforceManifests -StateRoot $stateRoot).Count -ne 0) {
    throw 'New lifecycle state must start with empty arrays.'
}
$result.lifecycle_state = $true

$lowProfile = Get-InvocationProfile -Level low
$mediumProfile = Get-InvocationProfile -Level medium
$highProfile = Get-InvocationProfile -Level high
if ($lowProfile.max_active_workers -ne 2 -or $lowProfile.burst_max_workers -ne 3 -or $lowProfile.max_nested_agents -ne 0 -or
    $mediumProfile.max_active_workers -ne 4 -or $mediumProfile.burst_max_workers -ne 6 -or $mediumProfile.max_nested_agents -ne 2 -or
    $highProfile.max_active_workers -ne 6 -or $highProfile.burst_max_workers -ne 10 -or $highProfile.max_nested_agents -ne 4) {
    throw 'Invocation profile concurrency defaults are incorrect.'
}
$result.invocation_profiles = $true

$retryableApi = Get-ApiFailureClassification -Text 'ECONNREFUSED 503'
$nonRetryableApi = Get-ApiFailureClassification -Text '401 invalid API key'
if (-not $retryableApi.retryable -or $nonRetryableApi.retryable -or $nonRetryableApi.category -ne 'configuration') {
    throw 'API failure classification is incorrect.'
}
$result.api_classification = $true
$httpMcp = Get-McpFailureClassification -Text 'MCP HTTP SSE endpoint connection failed'
$stdioMcp = Get-McpFailureClassification -Text 'MCP stdio child process exited'
if (-not $httpMcp.retryable -or $httpMcp.transport -ne 'http-sse' -or -not $stdioMcp.retryable -or $stdioMcp.transport -ne 'stdio') {
    throw 'MCP transport classification is incorrect.'
}
$result.mcp_classification = $true

$circuitKey = Get-ApiCircuitKey -Provider 'test' -Endpoint 'https://example.invalid' -Model 'model-test'
1..3 | ForEach-Object { Update-ApiCircuitState -StateRoot $stateRoot -CircuitKey $circuitKey -FailureText 'ECONNREFUSED' | Out-Null }
$openCircuit = Get-ApiCircuitState -StateRoot $stateRoot -CircuitKey $circuitKey
if ($openCircuit.state -ne 'open' -or (Get-AdaptiveWorkerLimit -InvocationProfile $highProfile -CircuitState $openCircuit) -ne 0) {
    throw 'Circuit breaker did not open and freeze dispatch after three failures.'
}
$result.circuit_breaker = $true
$result.adaptive_concurrency = $true

$lease = Add-WorkforcePortLease -StateRoot $stateRoot -Port 0 -SessionId 'lease-session' -WorkerId 'lease-worker' -Purpose 'test' -TtlSeconds 30 -OwnershipFingerprint 'lease-owner'
if ($lease.port -le 0 -or -not (Remove-WorkforcePortLease -StateRoot $stateRoot -LeaseId $lease.lease_id -RequireReleasedPort)) {
    throw 'Dynamic port lease acquire/release failed.'
}
$result.port_lease = $true

$unownedListener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$unownedPortRejected = $false
try {
    $unownedListener.Start()
    $unownedPort = ([Net.IPEndPoint]$unownedListener.LocalEndpoint).Port
    try {
        Add-WorkforcePortLease -StateRoot $stateRoot -Port $unownedPort -SessionId 'unowned-session' -WorkerId 'unowned-worker' -Purpose 'must-not-claim' -TtlSeconds 30 -OwnershipFingerprint 'unowned-owner' | Out-Null
    }
    catch {
        $unownedPortRejected = $_.Exception.Message -like '*unowned process*will not be terminated*'
    }
    if (-not $unownedPortRejected -or -not $unownedListener.Server.IsBound -or
        (Test-WorkforcePortListening -Port $unownedPort -Protocol tcp) -ne $true -or
        @(Get-WorkforcePortLeases -StateRoot $stateRoot | Where-Object { [int]$_.port -eq $unownedPort }).Count -ne 0) {
        throw 'An unowned listening port was claimed, released, or otherwise disturbed.'
    }
}
finally {
    $unownedListener.Stop()
}
$result.unowned_port_preserved = $true

$currentProcess = Get-Process -Id $PID
$pidReuseProbe = [pscustomobject]@{
    type = 'process'
    pid = $PID
    process_start_time = $currentProcess.StartTime.ToUniversalTime().AddHours(-1).ToString('o')
    executable = if ($currentProcess.Path) { [IO.Path]::GetFileName($currentProcess.Path) } else { "$($currentProcess.ProcessName).exe" }
    session_id = 'pid-reuse-session'
    ownership_fingerprint = 'pid-reuse-owner'
}
$ownership = Test-WorkforceProcessOwnership -Resource $pidReuseProbe -ExpectedSessionId 'pid-reuse-session' -ExpectedOwnershipFingerprint 'pid-reuse-owner'
if ($ownership.verified -or $ownership.reason -ne 'pid-reused' -or $null -eq (Get-Process -Id $PID -ErrorAction SilentlyContinue)) {
    throw 'PID reuse guard failed or affected the current process.'
}
$result.pid_reuse_guard = $true

$fingerprintProbe = [pscustomobject]@{
    type = 'process'
    pid = $PID
    process_start_time = $currentProcess.StartTime.ToUniversalTime().ToString('o')
    executable = if ($currentProcess.Path) { [IO.Path]::GetFileName($currentProcess.Path) } else { "$($currentProcess.ProcessName).exe" }
    session_id = 'fingerprint-session'
    ownership_fingerprint = 'wrong-manifest-id'
}
$fingerprintMismatch = Test-WorkforceProcessOwnership -Resource $fingerprintProbe -ExpectedSessionId 'fingerprint-session' -ExpectedOwnershipFingerprint 'expected-manifest-id'
if ($fingerprintMismatch.verified -or $fingerprintMismatch.reason -ne 'ownership-fingerprint-mismatch' -or $null -eq (Get-Process -Id $PID -ErrorAction SilentlyContinue)) {
    throw 'Ownership fingerprint mismatch was accepted or affected the current process.'
}
$fingerprintProbe.ownership_fingerprint = 'expected-manifest-id'
$fingerprintMatch = Test-WorkforceProcessOwnership -Resource $fingerprintProbe -ExpectedSessionId 'fingerprint-session' -ExpectedOwnershipFingerprint 'expected-manifest-id'
if (-not $fingerprintMatch.verified -or $fingerprintMatch.reason -ne 'matched') {
    throw 'Matching ownership fingerprint was not verified.'
}
$result.ownership_fingerprint_guard = $true

$duplicateFingerprint = Get-WorkforceTaskFingerprint -Namespace 'cx-test' -Cwd $PSScriptRoot -Role 'helper' -Prompt 'duplicate probe'
$duplicateManifest = New-WorkforceManifest -Namespace 'cx-test' -CwdFingerprint (Get-WorkforceHash -Text ([IO.Path]::GetFullPath($PSScriptRoot).ToLowerInvariant())).Substring(0, 24) -Role 'helper' -TaskFingerprint $duplicateFingerprint -WorkerId 'duplicate-worker' -WorkerName 'cx-test-helper' -SessionId 'duplicate-session'
$duplicateManifest.status = 'running'
Save-WorkforceManifest -StateRoot $stateRoot -Manifest $duplicateManifest | Out-Null
$closedCircuitKey = Get-ApiCircuitKey -Provider 'test' -Endpoint 'https://closed.invalid' -Model 'model-test'
$duplicateReconcile = Invoke-WorkforceReconcile -StateRoot $stateRoot -Namespace 'cx-test' -CwdFingerprint $duplicateManifest.cwd_fingerprint -TaskFingerprint $duplicateFingerprint -Workers @([pscustomobject]@{ id = 'duplicate-worker'; name = 'cx-test-helper'; state = 'working' }) -InvocationLevel medium -CircuitKey $closedCircuitKey
if (-not $duplicateReconcile.duplicate_task_found -or $duplicateReconcile.dispatch_allowed -or $duplicateReconcile.reused_worker.worker_id -ne 'duplicate-worker') {
    throw 'Duplicate task reconcile did not reuse the active worker.'
}
$result.duplicate_dispatch_prevented = $true

$referenceRoot = Join-Path $PSScriptRoot '..\claude-workforce\references'
foreach ($name in @('resource-lifecycle.md', 'connectivity.md', 'port-management.md', 'invocation-levels.md', 'operations.md', 'troubleshooting.md')) {
    $referencePath = Join-Path $referenceRoot $name
    if (-not (Test-Path -LiteralPath $referencePath -PathType Leaf)) {
        throw "Missing lifecycle reference: $name"
    }
}
$result.lifecycle_references = $true

$readmeText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\README.md') -Raw -Encoding UTF8
$readmeZhText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\README.zh-CN.md') -Raw -Encoding UTF8
$skillText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\claude-workforce\SKILL.md') -Raw -Encoding UTF8
$securityText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\SECURITY.md') -Raw -Encoding UTF8
foreach ($marker in @('reconcile', 'ResourcePolicy', 'SessionRetentionPolicy', 'cleanup_status', 'daemon-restart-keep-workers')) {
    if (-not $readmeText.Contains($marker, [StringComparison]::Ordinal) -or
        -not $readmeZhText.Contains($marker, [StringComparison]::Ordinal) -or
        -not $skillText.Contains($marker, [StringComparison]::Ordinal)) {
        throw "Public lifecycle documentation marker is missing: $marker"
    }
}
foreach ($marker in @('PID-reuse-safe', 'port alone', 'ownership fingerprint')) {
    if (-not $securityText.Contains($marker, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Security lifecycle marker is missing: $marker"
    }
}
$result.public_lifecycle_docs = $true

$boundaryRejected = $false
try {
    & $installPath -Destination $HOME -Force -WhatIf 6>$null | Out-Null
}
catch {
    if ($_.Exception.Message -like '*dedicated directory named claude-workforce*') {
        $boundaryRejected = $true
    }
    else {
        throw
    }
}
if (-not $boundaryRejected) {
    throw 'Installer did not reject a protected destination boundary.'
}
$result.installer_boundary = $true

$mcpProfile = & $profilePath -Output mcp -ContextProfile project -TrustProfile strict | ConvertFrom-Json -ErrorAction Stop
if ($mcpProfile.purpose -ne 'codex-claude-workforce-session-only' -or $mcpProfile.schema_version -ne 1) {
    throw 'MCP workforce profile identity is invalid.'
}
if (@($mcpProfile.advanced.settingSources) -join ',' -ne 'user,project' -or -not $mcpProfile.advanced.persistSession -or -not $mcpProfile.advanced.strictMcpConfig) {
    throw 'MCP project profile isolation fields are invalid.'
}
if ($mcpProfile.lifecycle.invocation_level -ne 'medium' -or
    $mcpProfile.lifecycle.resource_policy -ne 'retain-session' -or
    $mcpProfile.lifecycle.session_retention_policy -ne 'stop-on-complete' -or
    $mcpProfile.lifecycle.mcp_startup_timeout_seconds -ne 60 -or
    $mcpProfile.lifecycle.mcp_idle_timeout_seconds -ne 600 -or
    $mcpProfile.lifecycle.mcp_tool_timeout_seconds -ne 300) {
    throw 'MCP lifecycle policy or split timeout metadata is invalid.'
}
$result.profile_lifecycle = $true
if (@($mcpProfile.allowedTools).Count -ne 0 -or @($mcpProfile.disallowedTools).Count -ne 0 -or $mcpProfile.strictAllowedTools) {
    throw 'MCP profile must leave broad grants and hard denials empty so claude-code-mcp canUseTool can surface per-request approval.'
}
foreach ($tool in @('Read', 'Glob', 'Grep', 'WebSearch', 'Plan', 'EnterPlanMode', 'ExitPlanMode')) {
    if ($tool -notin @($mcpProfile.settings.permissions.allow)) {
        throw "MCP profile is missing expected low-risk allow rule: $tool"
    }
}
foreach ($tool in @('Bash', 'Edit', 'Write', 'NotebookEdit', 'WebFetch', 'Agent', 'Task')) {
    if ($tool -notin @($mcpProfile.settings.permissions.ask)) {
        throw "MCP profile is missing expected review rule: $tool"
    }
}
foreach ($tool in @('Bash', 'Edit', 'Write', 'NotebookEdit', 'WebFetch', 'Agent', 'Task')) {
    if ($tool -in @($mcpProfile.settings.permissions.allow)) {
        throw "Dangerous bare tool must not appear in allow of normal session profile: $tool"
    }
}
foreach ($rule in @('Read(**/.env)', 'Read(~/.codex/auth.json)', 'Read(~/.claude/settings.json)')) {
    if ($rule -notin @($mcpProfile.settings.permissions.ask)) {
        throw "MCP profile is missing sensitive-read review rule: $rule"
    }
}
$nestedProfile = & $profilePath -Output mcp -ContextProfile project -TrustProfile strict -AllowNestedAgents | ConvertFrom-Json -ErrorAction Stop
if ('Agent' -notin @($nestedProfile.settings.permissions.allow) -or 'Agent' -in @($nestedProfile.settings.permissions.ask) -or
    'Task' -notin @($nestedProfile.settings.permissions.allow) -or 'Task' -in @($nestedProfile.settings.permissions.ask)) {
    throw 'Explicit nested-agent authorization was not scoped into the MCP session profile.'
}
foreach ($tool in @('Bash', 'Edit', 'Write', 'NotebookEdit', 'WebFetch')) {
    if ($tool -in @($nestedProfile.settings.permissions.allow)) {
        throw "AllowNestedAgents must not move dangerous tool into allow: $tool"
    }
}
$result.mcp_profile = $true

if (-not $SkipRuntime) {
    $fakeClaude = Join-Path ([IO.Path]::GetTempPath()) "claude-workforce-fake-$([guid]::NewGuid().ToString('N')).ps1"
    $fakeCmd = $null
$fakeSource = @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Remaining)
$rosterFile = Join-Path ([IO.Path]::GetTempPath()) ((Split-Path -LeafBase $PSCommandPath) + '-roster.json')
$timeoutSessionFile = "$rosterFile.timeout-session"
if ('--version' -in $Remaining) {
    '2.1.208 (Claude Code)'
    exit 0
}
if ($Remaining.Count -ge 2 -and $Remaining[0] -eq 'agents' -and $Remaining[1] -eq '--help') {
    'Manage background agents --json --permission-mode'
    exit 0
}
if ('--help' -in $Remaining) {
    '--output-format --max-budget-usd'
    exit 0
}
if ($Remaining.Count -ge 2 -and $Remaining[0] -eq 'daemon') {
    if ($Remaining[1] -eq 'status') { 'DAEMON_OK'; exit 0 }
    if ($Remaining[1] -eq 'stop') { 'DAEMON_STOPPED'; exit 0 }
}
if ($Remaining.Count -ge 1 -and $Remaining[0] -eq 'stop') {
    'WORKER_STOPPED'
    exit 0
}
if ($Remaining.Count -ge 1 -and $Remaining[0] -eq 'attach') {
    if (-not [string]::IsNullOrWhiteSpace($env:CF_TEST_ATTACH_MARKER)) {
        $Remaining[1] | Set-Content -LiteralPath $env:CF_TEST_ATTACH_MARKER -Encoding UTF8
    }
    'WORKER_ATTACHED'
    exit 0
}
if ($Remaining.Count -ge 1 -and $Remaining[0] -eq 'rm') {
    if (-not [string]::IsNullOrWhiteSpace($env:CF_TEST_RM_MARKER)) {
        $Remaining[1] | Set-Content -LiteralPath $env:CF_TEST_RM_MARKER -Encoding UTF8
    }
    'WORKER_REMOVED'
    exit 0
}
if ($Remaining.Count -ge 2 -and $Remaining[0] -eq 'agents' -and $Remaining[1] -eq '--json') {
    $rosterFormat = $env:CF_TEST_ROSTER_FORMAT
    if ($rosterFormat -eq 'empty') {
        '[]'
        exit 0
    }
    $escapedCwd = (Get-Location).Path.Replace('\', '\\')
    if ($rosterFormat -eq 'compact') {
        '[{"id":"compact-a","name":"compact-test","sessionId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","cwd":"' + $escapedCwd + '","state":"done"}]'
        exit 0
    }
    if ($rosterFormat -eq 'log-prefix-compact') {
        '[2026-07-14 12:00:00] daemon started' + [Environment]::NewLine + '[{"id":"prefixed-a","name":"prefixed-test","sessionId":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","cwd":"' + $escapedCwd + '","state":"done"}]'
        exit 0
    }
    if ($rosterFormat -eq 'log-prefix-pretty') {
        '[2026-07-14 12:00:00] daemon started' + [Environment]::NewLine + '[' + [Environment]::NewLine + '  {"id":"pretty-a","name":"pretty-test","sessionId":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","cwd":"' + $escapedCwd + '","state":"done"}' + [Environment]::NewLine + ']'
        exit 0
    }
    if ($rosterFormat -eq 'ansi-multi-bracket') {
        $escape = [char]27
        "$escape[32mdaemon log$escape[0m"
        '{"event":"daemon","message":"prefix object"}'
        '[{"id":"complex-a","name":"bracket ] worker","sessionId":"abababab-abab-4bab-8bab-abababababab","cwd":"' + $escapedCwd + '","state":"done"}]'
        exit 0
    }
    if ($rosterFormat -eq 'trailing-logs') {
        '[{"id":"trailing-a","name":"trailing-test","sessionId":"bcbcbcbc-bcbc-4cbc-8cbc-bcbcbcbcbcbc","cwd":"' + $escapedCwd + '","state":"done"}]'
        'unexpected trailing log'
        exit 0
    }
    if ($rosterFormat -eq 'namespace') {
        '[{"id":"owned-a","name":"cx-testns42-owned","sessionId":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","cwd":"' + $escapedCwd + '","state":"done"},{"id":"foreign-a","name":"cx-foreign-owned","sessionId":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee","cwd":"' + $escapedCwd + '","state":"done"}]'
        exit 0
    }
    if ($rosterFormat -eq 'retention') {
        $retentionWorker = [ordered]@{
            id = 'worker-retention'
            name = 'cx-retention-test'
            sessionId = '12121212-1212-4212-8212-121212121212'
            cwd = [string]$env:CF_TEST_ROSTER_CWD
            state = 'done'
        }
        ConvertTo-Json -InputObject @([pscustomobject]$retentionWorker) -Depth 4
        exit 0
    }
    $workers = @([ordered]@{
        id = 'worker-reply'
        name = 'cx-manual-reply-test'
        sessionId = '44444444-4444-4444-8444-444444444444'
        cwd = (Get-Location).Path
        state = 'done'
    })
    if (Test-Path -LiteralPath $rosterFile -PathType Leaf) {
        $launched = Get-Content -LiteralPath $rosterFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $workers += [ordered]@{
            id = 'worker-start'
            name = [string]$launched.name
            sessionId = '55555555-5555-4555-8555-555555555555'
            cwd = [string]$launched.cwd
            state = 'working'
            status = 'waiting'
            pid = '99999'
        }
    }
    ,$workers | ConvertTo-Json -Depth 4
    exit 0
}
if ('--bg' -in $Remaining) {
    $nameIndex = [Array]::IndexOf($Remaining, '--name')
    if ($nameIndex -ge 0 -and ($nameIndex + 1) -lt $Remaining.Count) {
        [ordered]@{
            name = $Remaining[$nameIndex + 1]
            cwd = (Get-Location).Path
        } | ConvertTo-Json -Compress | Set-Content -LiteralPath $rosterFile -Encoding UTF8
    }
    'STARTED'
    '-----BEGIN RSA PRIVATE ' + 'KEY-----'
    'MIIE-fake-test-material'
    '-----END RSA PRIVATE ' + 'KEY-----'
    'github_token: ' + ('ghp_' + ('A1' * 20))
    'AWS_ACCESS_KEY_ID=' + ('AK' + 'IA' + 'IOSFODNN7EXAMPLE')
    'ordinary-output-kept'
    exit 0
}
if ($env:CF_TEST_MCP_MODE -eq 'stdio') {
    if ('--resume' -in $Remaining) {
        '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"session_id":"66666666-6666-4666-8666-666666666666","total_cost_usd":0.02,"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5},"result":"MCP_RECOVERED"}'
        exit 0
    }
    '{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":1,"session_id":"66666666-6666-4666-8666-666666666666","total_cost_usd":0.01,"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5},"result":"MCP stdio child process exited after partial output"}'
    exit 1
}
if ($env:CF_TEST_API_MODE -eq 'retryable') {
    if ('--resume' -in $Remaining) {
        '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"session_id":"77777777-7777-4777-8777-777777777777","total_cost_usd":0.02,"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5},"result":"RECOVERED"}'
        exit 0
    }
    '{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":1,"session_id":"77777777-7777-4777-8777-777777777777","total_cost_usd":0.01,"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5},"result":"ECONNREFUSED partial output"}'
    exit 1
}
if ($env:CF_TEST_API_MODE -eq 'nonretryable') {
    '{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":1,"session_id":"88888888-8888-4888-8888-888888888888","total_cost_usd":0.01,"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5},"result":"401 invalid API key"}'
    exit 1
}
$joinedArguments = $Remaining -join ' '
if ($joinedArguments -like '*timeout monitored probe*') {
    $sessionIdIndex = [Array]::IndexOf($Remaining, '--session-id')
    if ($sessionIdIndex -lt 0 -or ($sessionIdIndex + 1) -ge $Remaining.Count) {
        throw 'timeout probe requires a preallocated session ID'
    }
    $Remaining[$sessionIdIndex + 1] | Set-Content -LiteralPath $timeoutSessionFile -Encoding UTF8
    'PARTIAL_BEFORE_TIMEOUT'
    [Console]::Out.Flush()
    Start-Sleep -Seconds 10
    exit 0
}
$resumeIndex = [Array]::IndexOf($Remaining, '--resume')
if ($resumeIndex -ge 0 -and ($resumeIndex + 1) -lt $Remaining.Count -and (Test-Path -LiteralPath $timeoutSessionFile -PathType Leaf)) {
    $timeoutSessionId = (Get-Content -LiteralPath $timeoutSessionFile -Raw -Encoding UTF8).Trim()
    if ($Remaining[$resumeIndex + 1] -eq $timeoutSessionId) {
        '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"session_id":"' + $timeoutSessionId + '","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":5,"output_tokens":3},"result":"FINALIZED_AFTER_TIMEOUT"}'
        exit 0
    }
}
if ($resumeIndex -ge 0 -and ($resumeIndex + 1) -lt $Remaining.Count -and $Remaining[$resumeIndex + 1] -eq '11111111-1111-4111-8111-111111111111') {
    '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"session_id":"11111111-1111-4111-8111-111111111111","total_cost_usd":0.01,"usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":20,"output_tokens":10},"result":"FINALIZED_FROM_EXISTING_CONTEXT"}'
    exit 0
}
if ('--resume' -in $Remaining) {
    '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"session_id":"44444444-4444-4444-8444-444444444444","total_cost_usd":0.25,"usage":{"input_tokens":100,"cache_creation_input_tokens":20,"cache_read_input_tokens":30,"output_tokens":40},"result":"REPLY_OK"}'
    exit 0
}
if (($Remaining -join ' ') -like '*null usage probe*') {
    '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"session_id":"22222222-2222-4222-8222-222222222222","total_cost_usd":0.01,"result":"OK"}'
    exit 0
}
if (($Remaining -join ' ') -like '*NoTools isolation probe*') {
    $hasSafeMode = '--safe-mode' -in $Remaining
    [ordered]@{
        type = 'result'
        subtype = 'success'
        is_error = $false
        num_turns = 1
        session_id = '99999999-9999-4999-8999-999999999999'
        total_cost_usd = 0
        usage = [ordered]@{input_tokens=1;cache_creation_input_tokens=0;cache_read_input_tokens=0;output_tokens=1}
        result = "HAS_SAFE_MODE=$hasSafeMode"
    } | ConvertTo-Json -Compress
    exit 0
}
if (($Remaining -join ' ') -like '*max turns zero probe*') {
    $hasMaxTurns = '--max-turns' -in $Remaining
    [ordered]@{
        type = 'result'
        subtype = 'success'
        is_error = $false
        num_turns = 1
        session_id = '81818181-8181-4181-8181-818181818181'
        usage = [ordered]@{input_tokens=1;cache_creation_input_tokens=0;cache_read_input_tokens=0;output_tokens=1}
        result = "MAX_TURNS_PRESENT=$hasMaxTurns"
    } | ConvertTo-Json -Compress
    exit 0
}
if (($Remaining -join ' ') -like '*multi result probe*') {
    $escape = [char]27
    "$escape[33mresult prefix$escape[0m"
    '{"event":"diagnostic","message":"ignore me"}'
    '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"session_id":"82828282-8282-4282-8282-828282828282","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1},"result":"SELECTED_RESULT"}'
    exit 0
}
if (($Remaining -join ' ') -like '*provider soft budget probe*') {
    $hasSdkBudget = '--max-budget-usd' -in $Remaining
    $separatorIndex = [Array]::IndexOf($Remaining, '--')
    $promptFollowsSeparator = $separatorIndex -ge 0 -and ($separatorIndex + 1) -lt $Remaining.Count -and $Remaining[$separatorIndex + 1] -like '*provider soft budget probe*' -and $Remaining[$separatorIndex + 1] -notmatch '[\r\n]'
    [ordered]@{
        type = 'result'
        subtype = 'success'
        is_error = $false
        num_turns = 1
        session_id = '33333333-3333-4333-8333-333333333333'
        total_cost_usd = 0.25
        usage = [ordered]@{
            input_tokens = 100
            cache_creation_input_tokens = 20
            cache_read_input_tokens = 30
            output_tokens = 40
        }
        result = "SDK_BUDGET_PRESENT=$hasSdkBudget;PROMPT_AFTER_SEPARATOR=$promptFollowsSeparator;TOOL_SEARCH=$env:ENABLE_TOOL_SEARCH"
    } | ConvertTo-Json -Compress
    exit 0
}
'{"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":2,"session_id":"11111111-1111-4111-8111-111111111111","total_cost_usd":0.25,"usage":{"input_tokens":100,"cache_creation_input_tokens":20,"cache_read_input_tokens":30,"output_tokens":40},"result":null}'
exit 1
'@
    [IO.File]::WriteAllText($fakeClaude, $fakeSource, [Text.UTF8Encoding]::new($false))
    Write-TestStage -Name 'fake-runtime-start'
    $localOriginRepo = $null
    try {
        $fakeHash = (Get-FileHash -LiteralPath $fakeClaude -Algorithm SHA256).Hash
        $highCapabilities = (& $scriptPath -Action capabilities -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -InvocationLevel high | ConvertFrom-Json)
        if ($highCapabilities.startup_timeout_seconds -ne 180 -or $highCapabilities.idle_timeout_seconds -ne 900 -or
            $highCapabilities.mcp_startup_timeout_seconds -ne 60 -or $highCapabilities.mcp_idle_timeout_seconds -ne 600 -or $highCapabilities.mcp_tool_timeout_seconds -ne 300) {
            throw 'Invocation-level or MCP timeout linkage is incorrect.'
        }
        $result.timeout_profile_linkage = $true
        $capabilityCachePath = (Get-WorkforceStatePaths -StateRoot $stateRoot).capability_cache
        $cachedState = Read-WorkforceState -Path $capabilityCachePath -DefaultValue $null -RestoreFromBackup
        $cachedEntry = @($cachedState.entries | Select-Object -First 1)[0]
        $cachedEntry.version = '9.9.9'
        $cachedEntry.expires_at = [DateTimeOffset]::UtcNow.AddHours(1).ToString('o')
        Write-WorkforceState -Path $capabilityCachePath -Value ([pscustomobject]@{ schema_version = 2; entries = @($cachedEntry) })
        $cacheHit = (& $scriptPath -Action capabilities -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash | ConvertFrom-Json)
        $cachedEntry.version = '0.0.1'
        $cachedEntry.executable_sha256 = '0' * 64
        Write-WorkforceState -Path $capabilityCachePath -Value ([pscustomobject]@{ schema_version = 2; entries = @($cachedEntry) })
        $hashRefresh = (& $scriptPath -Action capabilities -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash | ConvertFrom-Json)
        $refreshedState = Read-WorkforceState -Path $capabilityCachePath -DefaultValue $null -RestoreFromBackup
        $expiredEntry = @($refreshedState.entries | Select-Object -First 1)[0]
        $expiredEntry.version = '0.0.1'
        $expiredEntry.expires_at = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')
        Write-WorkforceState -Path $capabilityCachePath -Value ([pscustomobject]@{ schema_version = 2; entries = @($expiredEntry) })
        $ttlRefresh = (& $scriptPath -Action capabilities -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash | ConvertFrom-Json)
        $validEntry = @((Read-WorkforceState -Path $capabilityCachePath -DefaultValue $null -RestoreFromBackup).entries | Select-Object -First 1)[0]
        $validEntry.version = '9.9.9'
        $validEntry.expires_at = [DateTimeOffset]::UtcNow.AddHours(1).ToString('o')
        Write-WorkforceState -Path $capabilityCachePath -Value ([pscustomobject]@{ schema_version = 2; entries = @($validEntry) })
        $forcedRefresh = (& $scriptPath -Action capabilities -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -RefreshCapabilities | ConvertFrom-Json)
        if ($cacheHit.claude_version -ne '9.9.9' -or $hashRefresh.claude_version -ne '2.1.208' -or $ttlRefresh.claude_version -ne '2.1.208' -or $forcedRefresh.claude_version -ne '2.1.208') {
            throw 'Capability cache did not honor hit, executable hash, TTL, and explicit refresh boundaries.'
        }
        $result.capability_cache_ttl_hash = $true
        $backgroundBudgetRejected = $false
        try {
            & $scriptPath -Action start -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -Cwd (Split-Path -Parent $PSScriptRoot) -Prompt 'guard probe' -MaxTurns 1 -MaxBudgetUsd 1 | Out-Null
        }
        catch {
            $expectedMessage = 'Start background mode does not support per-run turn or hard SDK budget caps. Advisory provider budgets may be evaluated at later reply/finalization boundaries.'
            if ($_.Exception.Message -ceq $expectedMessage) {
                $backgroundBudgetRejected = $true
            }
            else {
                throw
            }
        }
        if (-not $backgroundBudgetRejected) {
            throw 'Background start accepted unsupported hard-budget parameters.'
        }
        $result.background_budget_guard = $true

        $startResult = (& $scriptPath -Action start -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -Cwd (Split-Path -Parent $PSScriptRoot) -Prompt 'start success probe' -NoTools | ConvertFrom-Json)
        if ($startResult.launch -notmatch 'STARTED' -or $startResult.launch -notmatch 'ordinary-output-kept' -or $startResult.mode -ne 'inspect' -or -not $startResult.no_tools) {
            throw 'Successful background start output was not returned.'
        }
        if ($startResult.workforce_profile_version -ne 2 -or $startResult.worker_name -notmatch '-w2-p[0-9a-f]{10}$' -or [string]::IsNullOrWhiteSpace([string]$startResult.launch_provenance.fingerprint)) {
            throw 'Background start did not record workforce profile and launch provenance.'
        }
        if ([string]::IsNullOrWhiteSpace([string]$startResult.session_id) -or [string]::IsNullOrWhiteSpace([string]$startResult.worker_id)) {
            throw 'Background start did not return canonical worker_id or session_id.'
        }
        $result.start_success_output = $true
        if (-not $startResult.roster_entry_found -or -not $startResult.roster_verified -or -not $startResult.roster_cwd_match -or
            $startResult.roster_state -ne 'working' -or
            $startResult.roster_session_id -ne '55555555-5555-4555-8555-555555555555' -or
            $startResult.roster_worker_id -ne 'worker-start') {
            throw 'Background start did not verify the launched worker against the roster with correct fields.'
        }
        $result.start_roster_verified = $true

        # NoTools + ContextProfile project → forced minimal (+ --safe-mode)
        $noToolsProjectResult = (& $scriptPath -Action run -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -Cwd (Split-Path -Parent $PSScriptRoot) -Prompt 'NoTools isolation probe' -NoTools -ContextProfile project -MaxTurns 1 -MaxBudgetUsd 1 -IncludeSdkCostEstimate -ForceNewDispatch | ConvertFrom-Json)
        if ($noToolsProjectResult.context_profile -ne 'minimal') {
            throw "NoTools + ContextProfile project did not force minimal profile (got: $($noToolsProjectResult.context_profile))."
        }
        if ($noToolsProjectResult.result -notmatch 'HAS_SAFE_MODE=True') {
            throw 'NoTools + ContextProfile project did not include --safe-mode in CLI arguments.'
        }
        $result.no_tools_project_forced_minimal = $true

        # NoTools + ContextProfile full → forced minimal
        $noToolsFullResult = (& $scriptPath -Action run -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -Cwd (Split-Path -Parent $PSScriptRoot) -Prompt 'NoTools isolation probe' -NoTools -ContextProfile full -MaxTurns 1 -MaxBudgetUsd 1 -IncludeSdkCostEstimate -ForceNewDispatch | ConvertFrom-Json)
        if ($noToolsFullResult.context_profile -ne 'minimal') {
            throw "NoTools + ContextProfile full did not force minimal profile (got: $noToolsFullResult.context_profile)."
        }
        $result.no_tools_full_forced_minimal = $true

        $zeroTurnsResult = (& $scriptPath -Action run -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -Cwd (Split-Path -Parent $PSScriptRoot) -Prompt 'max turns zero probe' -NoTools -MaxTurns 0 -ProviderBudgetCny ([decimal]'0.01') -Model 'deepseek-v4-flash[1m]' -ForceNewDispatch | ConvertFrom-Json)
        if ($zeroTurnsResult.result -ne 'MAX_TURNS_PRESENT=False') {
            throw 'MaxTurns=0 was forwarded to Claude Code instead of being omitted.'
        }
        $result.max_turns_zero_omitted = $true

        $multiResult = (& $scriptPath -Action run -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -Cwd (Split-Path -Parent $PSScriptRoot) -Prompt 'multi result probe' -NoTools -MaxTurns 1 -ProviderBudgetCny ([decimal]'0.01') -Model 'deepseek-v4-flash[1m]' -ForceNewDispatch | ConvertFrom-Json)
        if ($multiResult.result -ne 'SELECTED_RESULT' -or $multiResult.session_id -ne '82828282-8282-4282-8282-828282828282') {
            throw 'Result parser selected a diagnostic JSON object instead of the terminal result.'
        }
        $result.result_multi_json_selected = $true

        $unredactedProbePattern = 'BEGIN.*PRIVATE.*KEY|MIIE-fake|ghp_|' + [regex]::Escape(('AK' + 'IAIOSFODNN7EXAMPLE'))
        if ($startResult.launch -match $unredactedProbePattern) {
            throw 'Sensitive-format launch output survived the unified redaction pipeline.'
        }
        if ($startResult.launch -notmatch '<redacted-pem-block>') {
            throw 'PEM private key block was not redacted.'
        }
        $result.log_redaction_pem_block = $true
        if ($startResult.launch -notmatch '<redacted-github-token>|github_token:\s*<redacted>') {
            throw 'GitHub token format was not redacted.'
        }
        $result.log_redaction_github_token = $true
        if ($startResult.launch -notmatch '<redacted-aws-access-key>|AWS_ACCESS_KEY_ID=<redacted>') {
            throw 'AWS access key format was not redacted.'
        }
        $result.log_redaction_aws_key = $true

        $git = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $localOriginRepo = Join-Path ([IO.Path]::GetTempPath()) "claude-workforce-origin-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $localOriginRepo -Force | Out-Null
        & $git.Source -C $localOriginRepo init --quiet
        if ($LASTEXITCODE -ne 0) { throw 'Unable to create local-origin provenance test repository.' }
        & $git.Source -C $localOriginRepo remote add origin 'C:\private\secret-origin\repo.git'
        if ($LASTEXITCODE -ne 0) { throw 'Unable to add local-origin provenance test remote.' }
        $localOriginStart = (& $scriptPath -Action start -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -Cwd $localOriginRepo -Prompt 'local origin redaction probe' -NoTools | ConvertFrom-Json)
        if ($localOriginStart.launch_provenance.remote -ne '[local-or-private-remote]') {
            throw 'Windows local Git origin leaked through launch provenance.'
        }
        $result.local_remote_redacted = $true
        & $git.Source -C $localOriginRepo remote set-url origin 'https://oauth2:example-secret@github.com/example/repo.git'
        if ($LASTEXITCODE -ne 0) { throw 'Unable to replace provenance test remote.' }
        $credentialOriginStart = (& $scriptPath -Action start -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -Cwd $localOriginRepo -Prompt 'credential origin redaction probe' -NoTools | ConvertFrom-Json)
        if ($credentialOriginStart.launch_provenance.remote -ne 'github.com/example/repo.git' -or [string]$credentialOriginStart.launch_provenance.remote -match 'oauth2|example-secret') {
            throw 'Credential-bearing Git origin was not redacted from launch provenance.'
        }
        $result.credential_remote_redacted = $true

        # POSIX absolute-path remote redaction
        & $git.Source -C $localOriginRepo remote set-url origin '/home/user/private/repo.git'
        if ($LASTEXITCODE -ne 0) { throw 'Unable to set POSIX-path provenance test remote.' }
        $posixOriginStart = (& $scriptPath -Action start -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -Cwd $localOriginRepo -Prompt 'posix local origin redaction probe' -NoTools | ConvertFrom-Json)
        if ($posixOriginStart.launch_provenance.remote -ne '[local-or-private-remote]') {
            throw 'POSIX local Git origin path was not redacted from launch provenance.'
        }
        $result.posix_local_remote_redacted = $true

        $previousRosterFormat = $env:CF_TEST_ROSTER_FORMAT
        $previousRosterCwd = $env:CF_TEST_ROSTER_CWD
        $previousRmMarker = $env:CF_TEST_RM_MARKER
        $previousRetentionStateRoot = $env:CLAUDE_WORKFORCE_STATE_ROOT
        $retentionStateRoot = Join-Path ([IO.Path]::GetTempPath()) "claude-workforce-retention-$([guid]::NewGuid().ToString('N'))"
        $nonGitCwd = Join-Path ([IO.Path]::GetTempPath()) "claude-workforce-nongit-$([guid]::NewGuid().ToString('N'))"
        $rmMarker = Join-Path ([IO.Path]::GetTempPath()) "claude-workforce-rm-$([guid]::NewGuid().ToString('N')).txt"
        try {
            New-Item -ItemType Directory -Path $nonGitCwd -Force | Out-Null
            $env:CF_TEST_ROSTER_FORMAT = 'retention'
            $env:CF_TEST_RM_MARKER = $rmMarker
            $env:CLAUDE_WORKFORCE_STATE_ROOT = $retentionStateRoot

            $unverifiedManifest = New-WorkforceManifest -Namespace 'retention-test' -CwdFingerprint 'unverified-cwd' -Role 'helper' -TaskFingerprint 'unverified-task' -ResourcePolicy 'retain-session' -SessionRetentionPolicy 'remove-on-complete' -WorkerId 'worker-retention' -WorkerName 'cx-retention-test' -SessionId '12121212-1212-4212-8212-121212121212'
            $unverifiedManifest.status = 'completed'
            Save-WorkforceManifest -StateRoot $retentionStateRoot -Manifest $unverifiedManifest | Out-Null
            $env:CF_TEST_ROSTER_CWD = $nonGitCwd
            $unverifiedCleanup = (& $scriptPath -Action cleanup -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -AllThreads -Id 'worker-retention' -GracefulShutdownSeconds 0 -PortReleaseTimeoutSeconds 0 | ConvertFrom-Json)
            if ($unverifiedCleanup.results[0].retention.status -ne 'worktree-unverified' -or $unverifiedCleanup.results[0].retention.session_removed -or (Test-Path -LiteralPath $rmMarker)) {
                $actualRetention = $unverifiedCleanup.results[0].retention | ConvertTo-Json -Compress -Depth 4
                throw "remove-on-complete did not fail closed for an unverified worktree. retention=$actualRetention; rm_marker=$(Test-Path -LiteralPath $rmMarker)"
            }

            Remove-Item -LiteralPath $retentionStateRoot -Recurse -Force
            $futureManifest = New-WorkforceManifest -Namespace 'retention-test' -CwdFingerprint 'future-ttl-cwd' -Role 'helper' -TaskFingerprint 'future-ttl-task' -ResourcePolicy 'retain-session' -SessionRetentionPolicy 'idle-ttl' -IdleTtlSeconds 3600 -WorkerId 'worker-retention' -WorkerName 'cx-retention-test' -SessionId '12121212-1212-4212-8212-121212121212'
            $futureManifest.status = 'completed'
            Save-WorkforceManifest -StateRoot $retentionStateRoot -Manifest $futureManifest | Out-Null
            $env:CF_TEST_ROSTER_CWD = $localOriginRepo
            $futureCleanup = (& $scriptPath -Action cleanup -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -AllThreads -Id 'worker-retention' -GracefulShutdownSeconds 0 -PortReleaseTimeoutSeconds 0 | ConvertFrom-Json)
            if ($futureCleanup.results[0].retention.status -ne 'retained-until-ttl' -or $futureCleanup.results[0].retention.session_removed -or (Test-Path -LiteralPath $rmMarker)) {
                throw 'idle-ttl removed a clean terminal session before its expiry.'
            }

            Remove-Item -LiteralPath $retentionStateRoot -Recurse -Force
            $expiredManifest = New-WorkforceManifest -Namespace 'retention-test' -CwdFingerprint 'expired-ttl-cwd' -Role 'helper' -TaskFingerprint 'expired-ttl-task' -ResourcePolicy 'retain-session' -SessionRetentionPolicy 'idle-ttl' -IdleTtlSeconds 1 -WorkerId 'worker-retention' -WorkerName 'cx-retention-test' -SessionId '12121212-1212-4212-8212-121212121212'
            $expiredManifest.status = 'completed'
            $expiredManifest.idle_expires_at = [DateTimeOffset]::UtcNow.AddSeconds(-1).ToString('o')
            Save-WorkforceManifest -StateRoot $retentionStateRoot -Manifest $expiredManifest | Out-Null
            $expiredCleanup = (& $scriptPath -Action cleanup -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -AllThreads -Id 'worker-retention' -GracefulShutdownSeconds 0 -PortReleaseTimeoutSeconds 0 | ConvertFrom-Json)
            if ($expiredCleanup.results[0].retention.status -ne 'removed' -or -not $expiredCleanup.results[0].retention.session_removed -or
                -not (Test-Path -LiteralPath $rmMarker -PathType Leaf) -or (Get-Content -LiteralPath $rmMarker -Raw -Encoding UTF8).Trim() -ne 'worker-retention') {
                throw 'Expired idle-ttl did not remove a verified terminal worker with a clean worktree.'
            }
            $result.retention_safety = $true
        }
        finally {
            $env:CF_TEST_ROSTER_FORMAT = $previousRosterFormat
            $env:CF_TEST_ROSTER_CWD = $previousRosterCwd
            $env:CF_TEST_RM_MARKER = $previousRmMarker
            $env:CLAUDE_WORKFORCE_STATE_ROOT = $previousRetentionStateRoot
            foreach ($path in @($retentionStateRoot, $nonGitCwd, $rmMarker)) {
                if (Test-Path -LiteralPath $path) {
                    Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }

        Write-TestStage -Name 'retention-complete'
        # Unknown model not rejected by parameter binding (model validation is pattern-based)
        $unknownModelRejected = $false
        try {
            & $scriptPath -Action run -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -Cwd (Split-Path -Parent $PSScriptRoot) -Prompt 'unknown model probe' -NoTools -MaxTurns 1 -MaxBudgetUsd 1 -Model 'claude-sonnet-4-20250514' -IncludeSdkCostEstimate | Out-Null
        }
        catch {
            $unknownModelRejected = $_.Exception.Message -match 'Cannot validate|ValidateSet|parameter'
        }
        if ($unknownModelRejected) {
            throw 'Arbitrary provider model ID was rejected by parameter validation.'
        }
        $result.unknown_model_not_rejected = $true

        # Unknown model pricing returns null/unavailable
        $unknownPricingResult = (& $scriptPath -Action run -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -Cwd (Split-Path -Parent $PSScriptRoot) -Prompt 'unknown model pricing probe' -NoTools -MaxTurns 1 -MaxBudgetUsd 1 -Model 'gpt-5' -IncludeSdkCostEstimate | ConvertFrom-Json)
        if ($null -ne $unknownPricingResult.provider_cost_estimate -or $null -ne $unknownPricingResult.provider_cost_currency) {
            throw 'Unknown model must return null provider cost, not a fabricated estimate.'
        }
        if ($null -eq $unknownPricingResult.provider_cost_note -or $unknownPricingResult.provider_cost_note -notmatch 'No audited') {
            throw 'Unknown model must report unavailable pricing in provider_cost_note.'
        }
        $result.unknown_model_pricing_null = $true

        # Advisory budgets remain non-blocking when pricing is unavailable, but must report no conclusion.
        $unpricedSoftBudgetResult = (& $scriptPath -Action run -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -Cwd (Split-Path -Parent $PSScriptRoot) -Prompt 'unknown model soft budget probe' -NoTools -MaxTurns 1 -ProviderBudget 1 -Model 'gpt-5' | ConvertFrom-Json)
        if ($null -ne $unpricedSoftBudgetResult.provider_cost_estimate -or $null -ne $unpricedSoftBudgetResult.provider_cost_exceeds_budget -or $unpricedSoftBudgetResult.provider_cost_note -notmatch 'No audited') {
            throw 'Unknown-model advisory budget reported a fabricated estimate or enforcement conclusion.'
        }
        $result.unknown_model_soft_budget_guard = $true

        $unpricedOverrideResult = (& $scriptPath -Action run -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -Cwd (Split-Path -Parent $PSScriptRoot) -Prompt 'unknown model override probe' -NoTools -MaxTurns 1 -ProviderBudget 1 -Model 'gpt-5' -AllowUnpricedModel | ConvertFrom-Json)
        if ($null -ne $unpricedOverrideResult.provider_cost_estimate -or $unpricedOverrideResult.provider_cost_note -notmatch 'No audited') {
            throw 'Explicit unpriced-model override must preserve unavailable provider pricing.'
        }
        $result.unknown_model_explicit_override = $true

        Write-TestStage -Name 'pricing-complete'
        # Namespace override via WORKFORCE_NAMESPACE env var
        $previousNamespace = $env:WORKFORCE_NAMESPACE
        try {
            $env:WORKFORCE_NAMESPACE = 'test-ns-42'
            $capNs = (& $scriptPath -Action capabilities -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash | ConvertFrom-Json)
            if (-not $capNs.namespace_configurable) {
                throw 'Capabilities must report namespace_configurable=$true.'
            }
            # Verify the namespace affects the owner prefix in capabilities output does NOT
            # assert the exact prefix since capabilities output does not include the live prefix.
            $env:CF_TEST_ROSTER_FORMAT = 'namespace'
            $scopedList = (& $scriptPath -Action list -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -All | ConvertFrom-Json)
            if ($scopedList.count -ne 1 -or $scopedList.workers[0].id -ne 'owned-a') {
                throw 'WORKFORCE_NAMESPACE did not isolate the default worker list.'
            }
            $result.namespace_scope_filter = $true

            $env:WORKFORCE_NAMESPACE = '---'
            $env:CF_TEST_ROSTER_FORMAT = $null
            $fallbackList = (& $scriptPath -Action list -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -All | ConvertFrom-Json)
            $fallbackWorkers = @($fallbackList.workers)
            $foreignFallbackWorkers = @($fallbackWorkers | Where-Object { [string]$_.name -notlike 'cx-manual-*' })
            if ($fallbackList.owner -ne 'cx-manual' -or $fallbackList.count -lt 1 -or $foreignFallbackWorkers.Count -gt 0) {
                throw 'An all-punctuation namespace did not fall back to cx-manual safely.'
            }
            $result.namespace_fallback = $true
        }
        finally {
            $env:WORKFORCE_NAMESPACE = $previousNamespace
            $env:CF_TEST_ROSTER_FORMAT = $null
        }
        $result.namespace_override = $true

        if ($IsWindows) {
            $fakeCmd = Join-Path ([IO.Path]::GetTempPath()) "claude-workforce-fake-$([guid]::NewGuid().ToString('N')).cmd"
            $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
            $cmdSource = "@echo off`r`n`"$pwshPath`" -NoProfile -File `"$fakeClaude`" %*`r`n"
            [IO.File]::WriteAllText($fakeCmd, $cmdSource, [Text.UTF8Encoding]::new($false))
            $fakeCmdHash = (Get-FileHash -LiteralPath $fakeCmd -Algorithm SHA256).Hash
            $cmdCapabilities = (& $scriptPath -Action capabilities -ClaudeExecutable $fakeCmd -ExpectedClaudeSha256 $fakeCmdHash | ConvertFrom-Json)
            if (-not $cmdCapabilities.version_supported) {
                throw 'Windows .cmd Claude executable shim did not run through the unified process path.'
            }
            $result.cmd_shim = $true
        }

        Write-TestStage -Name 'namespace-and-shim-complete'
        $listResult = (& $scriptPath -Action list -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -All -AllThreads | ConvertFrom-Json)
        if ($listResult.count -lt 1 -or 'worker-reply' -notin @($listResult.workers.id)) {
            throw 'Successful worker list output was not returned.'
        }
        $result.list_success_output = $true

        # Convert-WorkersFromJson edge cases
        $previousRosterFormat = $env:CF_TEST_ROSTER_FORMAT
        try {
            # Empty roster []
            $env:CF_TEST_ROSTER_FORMAT = 'empty'
            $emptyList = & $scriptPath -Action list -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -All -AllThreads | ConvertFrom-Json
            if ($emptyList.count -ne 0) {
                throw 'Empty roster [] was not parsed as zero workers.'
            }
            $result.roster_empty_parsed = $true

            # Compact single-entry array [{"id":"a"}]
            $env:CF_TEST_ROSTER_FORMAT = 'compact'
            $compactList = & $scriptPath -Action list -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -All -AllThreads | ConvertFrom-Json
            if ($compactList.count -ne 1 -or $compactList.workers[0].id -ne 'compact-a') {
                throw 'Compact single-entry roster was not parsed correctly.'
            }
            $result.roster_compact_parsed = $true

            # Log prefix + compact JSON
            $env:CF_TEST_ROSTER_FORMAT = 'log-prefix-compact'
            $prefixedCompactList = & $scriptPath -Action list -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -All -AllThreads | ConvertFrom-Json
            if ($prefixedCompactList.count -ne 1 -or $prefixedCompactList.workers[0].id -ne 'prefixed-a') {
                throw 'Log-prefixed compact roster was not parsed correctly.'
            }
            $result.roster_log_prefix_compact_parsed = $true

            # Log prefix + pretty JSON
            $env:CF_TEST_ROSTER_FORMAT = 'log-prefix-pretty'
            $prefixedPrettyList = & $scriptPath -Action list -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -All -AllThreads | ConvertFrom-Json
            if ($prefixedPrettyList.count -ne 1 -or $prefixedPrettyList.workers[0].id -ne 'pretty-a') {
                throw 'Log-prefixed pretty roster was not parsed correctly.'
            }
            $result.roster_log_prefix_pretty_parsed = $true

            $env:CF_TEST_ROSTER_FORMAT = 'ansi-multi-bracket'
            $complexList = & $scriptPath -Action list -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -All -AllThreads | ConvertFrom-Json
            if ($complexList.count -ne 1 -or $complexList.workers[0].id -ne 'complex-a' -or $complexList.workers[0].name -ne 'bracket ] worker') {
                throw 'ANSI/multi-JSON roster with a closing bracket inside a string was not parsed correctly.'
            }
            $result.roster_ansi_multi_bracket_parsed = $true

            $env:CF_TEST_ROSTER_FORMAT = 'trailing-logs'
            $trailingRejected = $false
            try {
                & $scriptPath -Action list -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -All -AllThreads | Out-Null
            }
            catch {
                $trailingRejected = $_.Exception.Message -match 'worker roster JSON could not be parsed'
            }
            if (-not $trailingRejected) {
                throw 'Roster parser accepted non-empty trailing logs after the JSON array.'
            }
            $result.roster_trailing_logs_rejected = $true
        }
        finally {
            $env:CF_TEST_ROSTER_FORMAT = $previousRosterFormat
        }

        Write-TestStage -Name 'roster-parser-complete'
        $previousAttachMarker = $env:CF_TEST_ATTACH_MARKER
        $attachMarker = Join-Path ([IO.Path]::GetTempPath()) "claude-workforce-attach-$([guid]::NewGuid().ToString('N')).txt"
        try {
            $env:CF_TEST_ATTACH_MARKER = $attachMarker
            & $scriptPath -Action attach -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -Id 'cx-manual-reply-test' -AllThreads | Out-Null
            if (-not (Test-Path -LiteralPath $attachMarker -PathType Leaf) -or (Get-Content -LiteralPath $attachMarker -Raw -Encoding UTF8).Trim() -ne 'worker-reply') {
                throw 'Attach did not invoke Claude Code with the canonical roster worker ID.'
            }
            $result.attach_canonical_id = $true
        }
        finally {
            $env:CF_TEST_ATTACH_MARKER = $previousAttachMarker
            Remove-Item -LiteralPath $attachMarker -Force -ErrorAction SilentlyContinue
        }
        $replyMetadataManifest = New-WorkforceManifest -Namespace 'cx-manual' -CwdFingerprint 'reply-metadata-cwd' -Role worker -TaskFingerprint 'reply-metadata-task' -WorkerId 'worker-reply' -WorkerName 'cx-manual-reply-test' -SessionId '44444444-4444-4444-8444-444444444444'
        $replyMetadataManifest.status = 'completed'
        $replyMetadataManifest.cleanup_status = 'complete'
        $replyMetadataManifest.result = [pscustomobject]@{ is_error = $false }
        foreach ($entry in @{ model = 'deepseek-v4-flash[1m]'; effort = 'low'; context_profile = 'minimal'; trust_profile = 'strict'; budget_policy = 'advisory' }.GetEnumerator()) {
            Set-WorkforceObjectProperty -InputObject $replyMetadataManifest -Name $entry.Key -Value $entry.Value
        }
        Save-WorkforceManifest -StateRoot $stateRoot -Manifest $replyMetadataManifest | Out-Null
        $inheritedReply = (& $scriptPath -Action reply -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -Id 'worker-reply' -AllThreads -Prompt 'metadata inheritance probe' -NoTools -MaxTurns 1 -ProviderBudgetCny ([decimal]'0.01') -AllowLegacySession | ConvertFrom-Json)
        if ($inheritedReply.model -ne 'deepseek-v4-flash[1m]' -or $inheritedReply.effort -ne 'low' -or $inheritedReply.trust_profile -ne 'strict' -or $inheritedReply.budget_policy -ne 'advisory') {
            throw 'Reply did not inherit saved model, effort, trust, and budget metadata.'
        }
        $result.reply_model_guard = $true
        $result.reply_effort_guard = $true

        $replyWriteModeRejected = $false
        try {
            & $scriptPath -Action reply -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -Id 'worker-reply' -AllThreads -Mode write -Prompt 'write mode guard probe' -MaxTurns 1 -ProviderBudgetCny ([decimal]'0.01') -Model 'deepseek-v4-flash[1m]' | Out-Null
        }
        catch {
            if ($_.Exception.Message -ceq 'Native print-mode reply cannot perform interactive writes. Use Claude Code MCP for writes that require interactive permission handling.') {
                $replyWriteModeRejected = $true
            }
            else {
                throw
            }
        }
        if (-not $replyWriteModeRejected) {
            throw 'Reply accepted write mode without a permission-handling path.'
        }
        $result.reply_write_mode_guard = $true

        $legacyRejected = $false
        try {
            & $scriptPath -Action reply -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -Id 'worker-reply' -AllThreads -Prompt 'legacy provenance probe' -NoTools -MaxTurns 1 -MaxBudgetUsd 1 -Model 'deepseek-v4-flash[1m]' -Effort low | Out-Null
        }
        catch {
            $legacyRejected = $_.Exception.Message -match 'predates workforce provenance tracking'
            if (-not $legacyRejected) {
                throw
            }
        }
        if (-not $legacyRejected) {
            throw 'Legacy worker resumed without an explicit provenance override.'
        }

        $replyResult = (& $scriptPath -Action reply -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -Id 'worker-reply' -AllThreads -Prompt 'reply success probe' -NoTools -MaxTurns 1 -MaxBudgetUsd 1 -IncludeSdkCostEstimate -Model 'deepseek-v4-flash[1m]' -Effort low -AllowLegacySession | ConvertFrom-Json)
        if ($replyResult.action -ne 'reply' -or $replyResult.result -ne 'REPLY_OK' -or $replyResult.session_id -ne '44444444-4444-4444-8444-444444444444' -or $replyResult.session_provenance_status -ne 'legacy-override') {
            throw 'Successful reply output was not returned as one structured object.'
        }
        if ($replyResult.total_cost_usd -ne 0.25 -or $replyResult.sdk_total_cost_usd -ne 0.25 -or $replyResult.provider_cost_estimate_cny -ne [decimal]'0.000201') {
            throw 'Successful reply diagnostic and provider-cost fields were not preserved.'
        }
        $result.reply_success_output = $true

        $timeoutResult = (& $scriptPath -Action run -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -Cwd (Split-Path -Parent $PSScriptRoot) -Prompt 'timeout monitored probe' -NoTools -MaxTurns 0 -ProviderBudgetCny ([decimal]'0.05') -Model 'deepseek-v4-flash[1m]' -HardTimeoutSeconds 1 -StartupTimeoutSeconds 10 -IdleTimeoutSeconds 3 -ProcessTimeoutSeconds 15 -ForceNewDispatch | ConvertFrom-Json)
        $timeoutSessionGuid = [guid]::Empty
        if ($timeoutResult.original_result_subtype -ne 'workforce-timeout-hard' -or -not $timeoutResult.auto_finalize_attempted -or -not $timeoutResult.resume_used -or -not [guid]::TryParse([string]$timeoutResult.session_id, [ref]$timeoutSessionGuid) -or $timeoutResult.result -ne 'FINALIZED_AFTER_TIMEOUT') {
            throw 'A monitored timeout with a recoverable session did not use same-session finalize.'
        }
        $result.timeout_same_session_finalize = $true

        Write-TestStage -Name 'reply-guards-complete'
        $errorResult = (& $scriptPath -Action run -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -Cwd (Split-Path -Parent $PSScriptRoot) -Prompt 'error recovery probe' -NoTools -MaxTurns 2 -MaxBudgetUsd 1 -Model 'deepseek-v4-flash[1m]' -IncludeSdkCostEstimate | ConvertFrom-Json)
        if ($errorResult.original_process_exit_code -ne 1 -or $errorResult.original_result_subtype -ne 'error_max_turns' -or -not $errorResult.original_is_error -or
            $errorResult.process_exit_code -ne 0 -or $errorResult.result_subtype -ne 'success' -or $errorResult.is_error -or -not $errorResult.auto_finalize_attempted -or -not $errorResult.resume_used -or $errorResult.session_id -ne '11111111-1111-4111-8111-111111111111') {
            throw 'Limit failure evidence or same-session finalize result was not preserved.'
        }
        if ($errorResult.original_usage.input_tokens -ne 100 -or $errorResult.original_usage.cache_read_input_tokens -ne 30 -or $errorResult.result -ne 'FINALIZED_FROM_EXISTING_CONTEXT') {
            throw 'Original limit usage or finalized output was not preserved.'
        }
        if ($errorResult.sdk_total_cost_usd -ne 0.01 -or [decimal]$errorResult.provider_cost_estimate_cny -ne [decimal]'0.00002') {
            throw 'Provider-aware cost fields were not calculated from usage correctly.'
        }
        if ($errorResult.provider_pricing.currency -ne 'CNY' -or $errorResult.provider_pricing.cache_miss_per_million -ne 1) {
            throw 'Provider pricing metadata is missing or incorrect.'
        }
        if ($errorResult.provider_billing_tokens.cache_miss -ne 0 -or $errorResult.provider_billing_tokens.cache_hit -ne 20 -or $errorResult.provider_billing_tokens.output -ne 10) {
            throw 'Provider billing token buckets were not derived correctly.'
        }
        if ([decimal]$errorResult.provider_cost_components_cny.cache_miss -ne 0 -or [decimal]$errorResult.provider_cost_components_cny.cache_hit -ne [decimal]'0.0000004' -or [decimal]$errorResult.provider_cost_components_cny.output -ne [decimal]'0.00002') {
            throw 'Provider cost components were not calculated correctly.'
        }
        $result.provider_cost_estimate = $true
        $result.nonzero_usage_recovery = $true

        $previousToolSearch = $env:ENABLE_TOOL_SEARCH
        $env:ENABLE_TOOL_SEARCH = 'true'
        try {
            $providerBudgetResult = (& $scriptPath -Action run -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -Cwd (Split-Path -Parent $PSScriptRoot) -Prompt 'provider soft budget probe' -NoTools -MaxTurns 1 -ProviderBudgetCny ([decimal]'0.0001') -Model 'deepseek-v4-flash[1m]' | ConvertFrom-Json)
        }
        finally {
            $env:ENABLE_TOOL_SEARCH = $previousToolSearch
        }
        if ($providerBudgetResult.result -ne 'SDK_BUDGET_PRESENT=False;PROMPT_AFTER_SEPARATOR=True;TOOL_SEARCH=' -or $providerBudgetResult.sdk_budget_enabled) {
            throw 'Provider-only budget enabled the SDK budget or the current prompt was not isolated after the option terminator.'
        }
        if ($null -ne $providerBudgetResult.PSObject.Properties['total_cost_usd'] -or $null -ne $providerBudgetResult.PSObject.Properties['sdk_total_cost_usd'] -or $null -ne $providerBudgetResult.PSObject.Properties['sdk_cost_note']) {
            throw 'Default provider output exposed the misleading SDK cost estimate.'
        }
        if (-not $providerBudgetResult.provider_cost_exceeds_budget -or $providerBudgetResult.provider_budget_cny -ne [decimal]'0.0001') {
            throw 'Provider soft-budget status was not reported correctly.'
        }
        $result.provider_soft_budget = $true

        $missingUsageResult = (& $scriptPath -Action run -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -Cwd (Split-Path -Parent $PSScriptRoot) -Prompt 'null usage probe' -NoTools -MaxTurns 1 -MaxBudgetUsd 1 | ConvertFrom-Json)
        if ($missingUsageResult.result_subtype -ne 'success' -or $missingUsageResult.result -ne 'OK') {
            throw 'Claude result without usage metadata was not preserved.'
        }
        if ($null -ne $missingUsageResult.usage.input_tokens -or $null -ne $missingUsageResult.usage.output_tokens) {
            throw 'Missing Claude usage metadata must remain explicitly null.'
        }
        $result.missing_usage_recovery = $true

        $previousApiMode = $env:CF_TEST_API_MODE
        try {
            $env:CF_TEST_API_MODE = 'retryable'
            $recoveredRun = (& $scriptPath -Action run -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -Cwd (Split-Path -Parent $PSScriptRoot) -Prompt 'retryable same session probe' -NoTools -MaxTurns 2 -MaxBudgetUsd 1 -Model 'deepseek-v4-flash[1m]' -ForceNewDispatch | ConvertFrom-Json)
            if ($recoveredRun.result -ne 'RECOVERED' -or $recoveredRun.session_id -ne '77777777-7777-4777-8777-777777777777' -or
                $recoveredRun.api_retry_count -ne 1 -or -not $recoveredRun.resume_used -or -not $recoveredRun.partial_output_recovered -or
                $recoveredRun.new_session_created -ne $true) {
                throw 'Retryable API failure did not recover exactly once in the same session.'
            }
            if (-not $recoveredRun.postflight_completed -or $recoveredRun.cleanup_status -ne 'complete' -or
                @($recoveredRun.resources_left_running).Count -ne 0) {
                throw 'Recovered run did not complete postflight cleanup.'
            }
            $result.same_session_recovery = $true
            $result.partial_output_preserved = $true
            $result.postflight_cleanup = $true

            $env:CF_TEST_API_MODE = 'nonretryable'
            $nonRetryableRun = (& $scriptPath -Action run -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -Cwd (Split-Path -Parent $PSScriptRoot) -Prompt 'nonretryable configuration probe' -NoTools -MaxTurns 2 -MaxBudgetUsd 1 -Model 'deepseek-v4-flash[1m]' -ForceNewDispatch | ConvertFrom-Json)
            if (-not $nonRetryableRun.is_error -or $nonRetryableRun.api_retry_count -ne 0 -or $nonRetryableRun.resume_used -or
                $nonRetryableRun.api_errors[0].category -ne 'configuration') {
                throw 'Non-retryable API failure was retried or misclassified.'
            }
            $result.nonretryable_no_retry = $true
        }
        finally {
            $env:CF_TEST_API_MODE = $previousApiMode
        }

        $previousMcpMode = $env:CF_TEST_MCP_MODE
        try {
            $env:CF_TEST_MCP_MODE = 'stdio'
            $mcpRecoveredRun = (& $scriptPath -Action run -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -Cwd (Split-Path -Parent $PSScriptRoot) -Prompt 'stdio MCP same session probe' -NoTools -MaxTurns 2 -MaxBudgetUsd 1 -Model 'deepseek-v4-flash[1m]' -ForceNewDispatch | ConvertFrom-Json)
            if ($mcpRecoveredRun.result -ne 'MCP_RECOVERED' -or $mcpRecoveredRun.mcp_retry_count -ne 1 -or $mcpRecoveredRun.api_retry_count -ne 0 -or
                $mcpRecoveredRun.mcp_errors[0].transport -ne 'stdio' -or -not $mcpRecoveredRun.mcp_errors[0].recovered) {
                throw 'stdio MCP failure did not recover once in the same session.'
            }
            $result.mcp_same_session_recovery = $true
        }
        finally {
            $env:CF_TEST_MCP_MODE = $previousMcpMode
        }

        Write-TestStage -Name 'recovery-complete'
        $stopResult = (& $scriptPath -Action stop -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -Id 'worker-reply' -AllThreads -GracefulShutdownSeconds 0 -PortReleaseTimeoutSeconds 0 | ConvertFrom-Json)
        if (-not $stopResult.terminal_state_verified -or -not $stopResult.worker_stopped -or
            $stopResult.owned_processes_remaining -ne 0 -or $stopResult.owned_ports_remaining -ne 0 -or
            $stopResult.cleanup_status -ne 'complete') {
            throw 'Stop did not verify terminal state and owned resource cleanup.'
        }
        $result.verified_stop = $true
        Write-TestStage -Name 'fake-runtime-complete'
    }
    finally {
        $fakeRoster = Join-Path ([IO.Path]::GetTempPath()) ((Split-Path -LeafBase $fakeClaude) + '-roster.json')
        Remove-Item -LiteralPath $fakeRoster -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "$fakeRoster.timeout-session" -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $fakeClaude -Force -ErrorAction SilentlyContinue
        if ($fakeCmd) {
            Remove-Item -LiteralPath $fakeCmd -Force -ErrorAction SilentlyContinue
        }
        if ($localOriginRepo -and (Test-Path -LiteralPath $localOriginRepo -PathType Container)) {
            Remove-Item -LiteralPath $localOriginRepo -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not $SkipHostRuntime) {
    if ([string]::IsNullOrWhiteSpace($HostClaudeExecutable) -xor [string]::IsNullOrWhiteSpace($HostClaudeSha256)) {
        throw 'HostClaudeExecutable and HostClaudeSha256 must be provided together.'
    }
    $hostCapabilityParameters = @{ Action = 'capabilities' }
    if (-not [string]::IsNullOrWhiteSpace($HostClaudeExecutable)) {
        $hostCapabilityParameters.ClaudeExecutable = $HostClaudeExecutable
        $hostCapabilityParameters.ExpectedClaudeSha256 = $HostClaudeSha256
    }
    $capabilities = (& $scriptPath @hostCapabilityParameters | ConvertFrom-Json)
    if (-not $capabilities.version_supported -or $capabilities.version_degraded -or -not $capabilities.has_background -or -not $capabilities.has_json_list -or -not $capabilities.has_output_format) {
        throw 'Claude Code runtime does not satisfy workforce requirements.'
    }
    if ($capabilities.minimum_supported -ne '2.1.208' -or $capabilities.degraded_range -ne '2.1.200–2.1.207') {
        throw 'Version support metadata does not reflect the documented supported and degraded ranges.'
    }
    if ($capabilities.bypass_allowed) {
        throw 'bypass_allowed must remain false.'
    }
    if ($capabilities.background_hard_budget_supported) {
        throw 'Background agents must not claim support for --max-budget-usd.'
    }
    if (-not $capabilities.bounded_run_supported -or -not $capabilities.reply_budget_supported) {
        throw 'Bounded run and reply budget support must be reported.'
    }
    if (-not $capabilities.provider_cost_estimation_supported -or -not $capabilities.provider_budget_is_soft -or $capabilities.sdk_budget_uses_provider_pricing) {
        throw 'Provider-aware cost capability metadata is incorrect.'
    }
    if ('deepseek-v4-flash[1m]' -notin @($capabilities.provider_pricing_models) -or 'deepseek-v4-pro[1m]' -notin @($capabilities.provider_pricing_models)) {
        throw 'Provider pricing model capability metadata is incomplete.'
    }
    if (-not $capabilities.sdk_cost_estimate_optional -or $capabilities.sdk_cost_estimate_included_by_default) {
        throw 'SDK cost estimate visibility defaults are unsafe or undocumented.'
    }
    if (-not $capabilities.provider_cost_currency_supported -or -not $capabilities.namespace_configurable -or $capabilities.model_validation -ne 'pattern') {
        throw 'Provider-agnostic or namespace capability metadata is missing or incorrect.'
    }
    if ($capabilities.default_context_profile -ne 'auto' -or $capabilities.default_mcp_output_tokens -ne 10000 -or $capabilities.process_timeout_seconds -ne 1800) {
        throw 'Cost-control defaults drifted from the documented profile.'
    }
    foreach ($argument in @('--no-chrome', '--safe-mode', '--strict-mcp-config', '--tools', '--disable-slash-commands')) {
        if ($argument -notin @($capabilities.no_tools_isolation)) {
            throw "No-tools isolation capability is missing argument: $argument"
        }
    }
    foreach ($tool in @('Read', 'Glob', 'Grep', 'WebSearch', 'Plan', 'EnterPlanMode', 'ExitPlanMode')) {
        if ($tool -notin @($capabilities.effective_allow_tools)) {
            throw "Expected planning tool is not allowed: $tool"
        }
    }
    foreach ($tool in @('Bash', 'Edit', 'Write', 'NotebookEdit', 'WebFetch', 'Agent')) {
        if ($tool -notin @($capabilities.effective_ask_tools)) {
            throw "Expected fail-safe tool is not in ask: $tool"
        }
    }
    if (@($capabilities.effective_deny_tools).Count -ne 0) {
        throw 'Normal workforce permissions should ask rather than permanently deny task-relevant tools.'
    }
    foreach ($rule in @('Read(**/.env)', 'Read(~/.codex/auth.json)', 'Read(~/.claude/settings.json)')) {
        if ($rule -notin @($capabilities.effective_ask_tools)) {
            throw "Credential review rule is missing: $rule"
        }
    }
    $result.executable_hash_pinned = [bool]$capabilities.executable_hash_pinned
    if ($capabilities.broad_web_fetch_allowed -or -not $capabilities.public_web_fetch_reviewed_by_supervisor) {
        throw 'Broad fetch compatibility flag must not bypass per-target supervisor review.'
    }
    $result.broad_web_fetch_allowed = [bool]$capabilities.broad_web_fetch_allowed
    }
}

$env:CLAUDE_WORKFORCE_STATE_ROOT = $previousStateRoot
if (Test-Path -LiteralPath $stateRoot -PathType Container) {
    Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
}

[pscustomobject]$result | ConvertTo-Json -Depth 4
