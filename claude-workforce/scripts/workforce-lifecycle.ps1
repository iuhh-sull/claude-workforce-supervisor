function Get-WorkforceHash {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $hash = [Security.Cryptography.SHA256]::HashData($bytes)
    return ([Convert]::ToHexString($hash)).ToLowerInvariant()
}

function Get-WorkforceUtcNow {
    return [DateTimeOffset]::UtcNow
}

function Get-WorkforceStatePaths {
    param([Parameter(Mandatory = $true)][string]$StateRoot)

    $resolvedRoot = [IO.Path]::GetFullPath($StateRoot)
    return [pscustomobject]@{
        root = $resolvedRoot
        port_leases = Join-Path $resolvedRoot 'port-leases.json'
        circuit_breakers = Join-Path $resolvedRoot 'circuit-breakers.json'
        resource_index = Join-Path $resolvedRoot 'resource-index.json'
        capability_cache = Join-Path $resolvedRoot 'capability-cache.json'
        metrics = Join-Path $resolvedRoot 'metrics.json'
        manifests = Join-Path $resolvedRoot 'manifests'
        results = Join-Path $resolvedRoot 'results'
    }
}

function Write-WorkforceJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowNull()]$Value
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
    $json = ConvertTo-Json -InputObject $Value -Depth 20
    $temporaryPath = Join-Path $directory ".$(Split-Path -Leaf $Path).$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporaryPath, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporaryPath, $Path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Read-WorkforceJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowNull()]$DefaultValue
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $DefaultValue
    }
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $DefaultValue
    }
    try {
        return $text | ConvertFrom-Json -Depth 20 -ErrorAction Stop
    }
    catch {
        throw "Workforce state JSON is invalid: $Path"
    }
}

function Initialize-WorkforceState {
    param([Parameter(Mandatory = $true)][string]$StateRoot)

    $paths = Get-WorkforceStatePaths -StateRoot $StateRoot
    foreach ($directory in @($paths.root, $paths.manifests, $paths.results)) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $directory -Force)
        }
    }
    foreach ($file in @($paths.port_leases, $paths.circuit_breakers, $paths.resource_index)) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            Write-WorkforceJson -Path $file -Value @()
        }
    }
    if (-not (Test-Path -LiteralPath $paths.capability_cache -PathType Leaf)) {
        Write-WorkforceJson -Path $paths.capability_cache -Value ([ordered]@{ schema_version = 1; entries = @() })
    }
    if (-not (Test-Path -LiteralPath $paths.metrics -PathType Leaf)) {
        Write-WorkforceJson -Path $paths.metrics -Value ([ordered]@{
            schema_version = 1
            active_worker_peak = 0
            burst_worker_peak = 0
            stale_workers_found = 0
            stale_workers_cleaned = 0
            owned_processes_started = 0
            owned_processes_stopped = 0
            owned_processes_leaked = 0
            ports_acquired = 0
            ports_released = 0
            ports_leaked = 0
            duplicate_dispatches_prevented = 0
            sessions_reused = 0
            new_sessions_created = 0
            api_connection_failures = 0
            api_same_session_recoveries = 0
            circuit_open_count = 0
            mcp_restarts = 0
            daemon_restarts = 0
            cleanup_incomplete_count = 0
            updated_at = (Get-WorkforceUtcNow).ToString('o')
        })
    }
    return $paths
}

function Get-InvocationProfile {
    param([Parameter(Mandatory = $true)][ValidateSet('low', 'medium', 'high')][string]$Level)

    switch ($Level) {
        'low' {
            return [pscustomobject]@{
                invocation_level = 'low'
                max_active_workers = 2
                burst_max_workers = 3
                max_nested_agents = 0
                startup_timeout_seconds = 120
                idle_timeout_seconds = 300
            }
        }
        'medium' {
            return [pscustomobject]@{
                invocation_level = 'medium'
                max_active_workers = 4
                burst_max_workers = 6
                max_nested_agents = 2
                startup_timeout_seconds = 120
                idle_timeout_seconds = 600
            }
        }
        'high' {
            return [pscustomobject]@{
                invocation_level = 'high'
                max_active_workers = 6
                burst_max_workers = 10
                max_nested_agents = 4
                startup_timeout_seconds = 180
                idle_timeout_seconds = 900
            }
        }
    }
}

function Get-WorkforceTaskFingerprint {
    param(
        [Parameter(Mandatory = $true)][string]$Namespace,
        [Parameter(Mandatory = $true)][string]$Cwd,
        [Parameter(Mandatory = $true)][string]$Role,
        [AllowEmptyString()][string]$Prompt
    )

    $resolvedCwd = [IO.Path]::GetFullPath($Cwd).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ($IsWindows) {
        $resolvedCwd = $resolvedCwd.ToLowerInvariant()
    }
    $normalizedPrompt = [regex]::Replace([string]$Prompt, '\s+', ' ').Trim()
    $identity = @($Namespace.ToLowerInvariant(), $resolvedCwd, $Role.ToLowerInvariant(), $normalizedPrompt) -join "`n"
    return (Get-WorkforceHash -Text $identity).Substring(0, 24)
}

function Get-WorkforceEnvironmentFingerprint {
    param([string]$ClaudeVersion)

    $names = @('ANTHROPIC_BASE_URL', 'ANTHROPIC_API_KEY', 'PATH', 'HTTPS_PROXY', 'HTTP_PROXY', 'NO_PROXY')
    $parts = foreach ($name in $names) {
        $value = [Environment]::GetEnvironmentVariable($name)
        "$name=$(Get-WorkforceHash -Text ([string]$value))"
    }
    $parts += "CLAUDE_VERSION=$ClaudeVersion"
    return (Get-WorkforceHash -Text ($parts -join "`n")).Substring(0, 24)
}

function Get-ApiFailureClassification {
    param([AllowEmptyString()][string]$Text)

    $value = [string]$Text
    $nonRetryablePattern = '(?i)(?:\b(?:400|401|403|404)\b|invalid\s+api\s*key|missing\s+authentication|invalid\s+model|tls\s+(?:validation|certificate)|certificate\s+(?:verify|validation)|dns\s+(?:configuration|resolution)|unsupported\s+endpoint)'
    $retryablePattern = '(?i)(?:ECONNREFUSED|ECONNRESET|ETIMEDOUT|connection\s+closed|\b(?:408|429|500|502|503|504|529)\b|request\s+timed?\s*out|timeout)'
    if ($value -match $nonRetryablePattern) {
        return [pscustomobject]@{ category = 'configuration'; retryable = $false; circuit_failure = $false }
    }
    if ($value -match $retryablePattern) {
        $category = if ($value -match '(?i)\b429\b') { 'rate-limit' } elseif ($value -match '(?i)\b(?:500|502|503|504|529)\b') { 'server' } else { 'connection' }
        return [pscustomobject]@{ category = $category; retryable = $true; circuit_failure = $true }
    }
    return [pscustomobject]@{ category = 'other'; retryable = $false; circuit_failure = $false }
}

function Get-McpFailureClassification {
    param([AllowEmptyString()][string]$Text)

    $value = [string]$Text
    if ($value -notmatch '(?i)\bMCP\b') {
        return [pscustomobject]@{ detected = $false; transport = 'unknown'; retryable = $false; strategy = 'none' }
    }
    if ($value -match '(?i)(?:HTTP|SSE|endpoint|connection)') {
        return [pscustomobject]@{
            detected = $true
            transport = 'http-sse'
            retryable = $true
            strategy = 'wait-for-internal-reconnect-verify-endpoint-and-lease-restart-confirmed-dead-service-once'
        }
    }
    if ($value -match '(?i)(?:stdio|child\s+process|process\s+exited|broken\s+pipe)') {
        return [pscustomobject]@{
            detected = $true
            transport = 'stdio'
            retryable = $true
            strategy = 'verify-owned-child-exit-and-restart-once'
        }
    }
    return [pscustomobject]@{ detected = $true; transport = 'unknown'; retryable = $false; strategy = 'inspect-without-automatic-restart' }
}

function Get-ApiCircuitKey {
    param(
        [AllowEmptyString()][string]$Provider,
        [AllowEmptyString()][string]$Endpoint,
        [AllowEmptyString()][string]$Model
    )

    $providerName = if ([string]::IsNullOrWhiteSpace($Provider)) { 'unknown' } else { $Provider.ToLowerInvariant() }
    $endpointFingerprint = (Get-WorkforceHash -Text ([string]$Endpoint)).Substring(0, 16)
    $modelName = if ([string]::IsNullOrWhiteSpace($Model)) { 'unknown' } else { $Model.ToLowerInvariant() }
    return [pscustomobject]@{
        key = (Get-WorkforceHash -Text "$providerName`n$endpointFingerprint`n$modelName").Substring(0, 24)
        provider = $providerName
        endpoint_fingerprint = $endpointFingerprint
        model = $modelName
    }
}

function Get-ApiCircuitState {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)]$CircuitKey,
        [int]$OpenSeconds = 60
    )

    $paths = Initialize-WorkforceState -StateRoot $StateRoot
    $records = @(Read-WorkforceJson -Path $paths.circuit_breakers -DefaultValue @())
    $record = @($records | Where-Object { [string]$_.key -eq [string]$CircuitKey.key }) | Select-Object -First 1
    if ($null -eq $record) {
        return [pscustomobject]@{
            key = $CircuitKey.key
            provider = $CircuitKey.provider
            endpoint_fingerprint = $CircuitKey.endpoint_fingerprint
            model = $CircuitKey.model
            state = 'closed'
            failure_count = 0
            failure_timestamps = @()
            opened_at = $null
            updated_at = (Get-WorkforceUtcNow).ToString('o')
        }
    }
    if ([string]$record.state -eq 'open' -and -not [string]::IsNullOrWhiteSpace([string]$record.opened_at)) {
        $openedAt = [DateTimeOffset]::Parse([string]$record.opened_at)
        if ((Get-WorkforceUtcNow) -ge $openedAt.AddSeconds($OpenSeconds)) {
            $record.state = 'half-open'
            $record.updated_at = (Get-WorkforceUtcNow).ToString('o')
            $updated = @($records | Where-Object { [string]$_.key -ne [string]$CircuitKey.key }) + @($record)
            Write-WorkforceJson -Path $paths.circuit_breakers -Value $updated
        }
    }
    return $record
}

function Update-ApiCircuitState {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)]$CircuitKey,
        [switch]$Success,
        [AllowEmptyString()][string]$FailureText,
        [int]$FailureThreshold = 3,
        [int]$FailureWindowSeconds = 300
    )

    $paths = Initialize-WorkforceState -StateRoot $StateRoot
    $records = @(Read-WorkforceJson -Path $paths.circuit_breakers -DefaultValue @())
    $record = Get-ApiCircuitState -StateRoot $StateRoot -CircuitKey $CircuitKey
    $previousState = [string]$record.state
    $now = Get-WorkforceUtcNow
    if ($Success) {
        $record.state = 'closed'
        $record.failure_count = 0
        $record.failure_timestamps = @()
        $record.opened_at = $null
    }
    else {
        $classification = Get-ApiFailureClassification -Text $FailureText
        if ($classification.circuit_failure) {
            $cutoff = $now.AddSeconds(-$FailureWindowSeconds)
            $timestamps = @($record.failure_timestamps | Where-Object {
                try { [DateTimeOffset]::Parse([string]$_) -ge $cutoff } catch { $false }
            })
            $timestamps += $now.ToString('o')
            $record.failure_timestamps = @($timestamps)
            $record.failure_count = $timestamps.Count
            if ($record.state -eq 'half-open' -or $record.failure_count -ge $FailureThreshold) {
                $record.state = 'open'
                $record.opened_at = $now.ToString('o')
            }
        }
    }
    $record.updated_at = $now.ToString('o')
    $updated = @($records | Where-Object { [string]$_.key -ne [string]$CircuitKey.key }) + @($record)
    Write-WorkforceJson -Path $paths.circuit_breakers -Value $updated
    if (-not $Success -and (Get-ApiFailureClassification -Text $FailureText).circuit_failure) {
        $changes = @{ api_connection_failures = 1 }
        if ($previousState -ne 'open' -and [string]$record.state -eq 'open') {
            $changes.circuit_open_count = 1
        }
        Update-WorkforceMetrics -StateRoot $StateRoot -Changes $changes | Out-Null
    }
    return $record
}

function Get-AdaptiveWorkerLimit {
    param(
        [Parameter(Mandatory = $true)]$InvocationProfile,
        [Parameter(Mandatory = $true)]$CircuitState,
        [ValidateSet('fixed', 'adaptive')][string]$ConcurrencyPolicy = 'adaptive'
    )

    if ([string]$CircuitState.state -eq 'open') {
        return 0
    }
    if ([string]$CircuitState.state -eq 'half-open') {
        return 1
    }
    if ($ConcurrencyPolicy -eq 'fixed') {
        return [int]$InvocationProfile.max_active_workers
    }
    $failures = [int]$CircuitState.failure_count
    if ($failures -le 0) {
        return [int]$InvocationProfile.max_active_workers
    }
    switch ([string]$InvocationProfile.invocation_level) {
        'low' { return $(if ($failures -eq 1) { 1 } else { 0 }) }
        'medium' { return $(if ($failures -eq 1) { 2 } else { 1 }) }
        'high' { return $(if ($failures -eq 1) { 3 } else { 1 }) }
    }
}

function Get-WorkforceManifests {
    param([Parameter(Mandatory = $true)][string]$StateRoot)

    $paths = Initialize-WorkforceState -StateRoot $StateRoot
    return @(Read-WorkforceJson -Path $paths.resource_index -DefaultValue @())
}

function Save-WorkforceManifest {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)]$Manifest
    )

    $paths = Initialize-WorkforceState -StateRoot $StateRoot
    if ([string]::IsNullOrWhiteSpace([string]$Manifest.manifest_id)) {
        throw 'Resource manifest requires manifest_id.'
    }
    $Manifest.updated_at = (Get-WorkforceUtcNow).ToString('o')
    $records = @(Read-WorkforceJson -Path $paths.resource_index -DefaultValue @())
    $updated = @($records | Where-Object { [string]$_.manifest_id -ne [string]$Manifest.manifest_id }) + @($Manifest)
    Write-WorkforceJson -Path $paths.resource_index -Value $updated
    $manifestPath = Join-Path $paths.manifests "$($Manifest.manifest_id).json"
    Write-WorkforceJson -Path $manifestPath -Value $Manifest
    return $Manifest
}

function New-WorkforceManifest {
    param(
        [Parameter(Mandatory = $true)][string]$Namespace,
        [Parameter(Mandatory = $true)][string]$CwdFingerprint,
        [Parameter(Mandatory = $true)][string]$Role,
        [Parameter(Mandatory = $true)][string]$TaskFingerprint,
        [ValidateSet('cleanup', 'retain-session', 'keep-resources')][string]$ResourcePolicy = 'retain-session',
        [ValidateSet('stop-on-complete', 'remove-on-complete', 'idle-ttl', 'manual')][string]$SessionRetentionPolicy = 'stop-on-complete',
        [int]$IdleTtlSeconds = 3600,
        [string]$WorkerId,
        [string]$WorkerName,
        [string]$SessionId
    )

    $now = Get-WorkforceUtcNow
    $identity = @($Namespace, $TaskFingerprint, $WorkerId, $WorkerName, $SessionId, $now.ToUnixTimeMilliseconds()) -join "`n"
    return [pscustomobject][ordered]@{
        schema_version = 1
        manifest_id = (Get-WorkforceHash -Text $identity).Substring(0, 24)
        namespace = $Namespace
        cwd_fingerprint = $CwdFingerprint
        role = $Role
        task_fingerprint = $TaskFingerprint
        worker_id = $WorkerId
        worker_name = $WorkerName
        session_id = $SessionId
        status = 'acquired'
        resource_policy = $ResourcePolicy
        session_retention_policy = $SessionRetentionPolicy
        idle_expires_at = $(if ($SessionRetentionPolicy -eq 'idle-ttl') { $now.AddSeconds($IdleTtlSeconds).ToString('o') } else { $null })
        resources = @()
        resources_stopped = @()
        resources_left_running = @()
        ports_acquired = @()
        ports_released = @()
        api_errors = @()
        mcp_errors = @()
        cleanup_status = 'pending'
        result = $null
        created_at = $now.ToString('o')
        updated_at = $now.ToString('o')
        completed_at = $null
    }
}

function Get-WorkforcePortLeases {
    param([Parameter(Mandatory = $true)][string]$StateRoot)

    $paths = Initialize-WorkforceState -StateRoot $StateRoot
    return @(Read-WorkforceJson -Path $paths.port_leases -DefaultValue @())
}

function Test-WorkforcePortListening {
    param(
        [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$Port,
        [ValidateSet('tcp', 'udp')][string]$Protocol = 'tcp'
    )

    try {
        $properties = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
        $endpoints = if ($Protocol -eq 'tcp') { $properties.GetActiveTcpListeners() } else { $properties.GetActiveUdpListeners() }
        return @($endpoints | Where-Object { $_.Port -eq $Port }).Count -gt 0
    }
    catch {
        return $null
    }
}

function Get-WorkforceDynamicTcpPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    }
    finally {
        $listener.Stop()
    }
}

function Add-WorkforcePortLease {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [ValidateRange(0, 65535)][int]$Port,
        [ValidateSet('tcp', 'udp')][string]$Protocol = 'tcp',
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$WorkerId,
        [string]$Purpose = 'workforce-resource',
        [int]$ProcessId = 0,
        [string]$ProcessStartTime,
        [switch]$Persistent,
        [ValidateRange(1, 604800)][int]$TtlSeconds = 3600,
        [string]$OwnershipFingerprint
    )

    $paths = Initialize-WorkforceState -StateRoot $StateRoot
    if ($Port -eq 0) {
        if ($Protocol -ne 'tcp') {
            throw 'Dynamic port selection currently supports TCP only.'
        }
        $Port = Get-WorkforceDynamicTcpPort
    }
    $leases = @(Read-WorkforceJson -Path $paths.port_leases -DefaultValue @())
    $now = Get-WorkforceUtcNow
    $active = @($leases | Where-Object {
        [int]$_.port -eq $Port -and [string]$_.protocol -eq $Protocol -and
        ([string]::IsNullOrWhiteSpace([string]$_.expires_at) -or [DateTimeOffset]::Parse([string]$_.expires_at) -gt $now)
    })
    $sameOwner = @($active | Where-Object { [string]$_.session_id -eq $SessionId -and [string]$_.worker_id -eq $WorkerId }) | Select-Object -First 1
    if ($sameOwner) {
        return $sameOwner
    }
    if ($active.Count -gt 0) {
        throw "Port $Port/$Protocol is leased by another workforce session."
    }
    $listening = Test-WorkforcePortListening -Port $Port -Protocol $Protocol
    if ($listening -eq $true) {
        throw "Port $Port/$Protocol is already used by an unowned process; it will not be terminated."
    }
    $lease = [pscustomobject][ordered]@{
        schema_version = 1
        lease_id = (Get-WorkforceHash -Text "$SessionId`n$WorkerId`n$Protocol`n$Port").Substring(0, 24)
        port = $Port
        protocol = $Protocol
        session_id = $SessionId
        worker_id = $WorkerId
        pid = $(if ($ProcessId -gt 0) { $ProcessId } else { $null })
        process_start_time = $ProcessStartTime
        purpose = $Purpose
        persistent = [bool]$Persistent
        ownership_fingerprint = $OwnershipFingerprint
        created_at = $now.ToString('o')
        expires_at = $now.AddSeconds($TtlSeconds).ToString('o')
    }
    Write-WorkforceJson -Path $paths.port_leases -Value (@($leases) + @($lease))
    Update-WorkforceMetrics -StateRoot $StateRoot -Changes @{ ports_acquired = 1 } | Out-Null
    return $lease
}

function Remove-WorkforcePortLease {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$LeaseId,
        [switch]$RequireReleasedPort
    )

    $paths = Initialize-WorkforceState -StateRoot $StateRoot
    $leases = @(Read-WorkforceJson -Path $paths.port_leases -DefaultValue @())
    $lease = @($leases | Where-Object { [string]$_.lease_id -eq $LeaseId }) | Select-Object -First 1
    if ($null -eq $lease) {
        return $false
    }
    if ($RequireReleasedPort -and (Test-WorkforcePortListening -Port ([int]$lease.port) -Protocol ([string]$lease.protocol)) -eq $true) {
        return $false
    }
    Write-WorkforceJson -Path $paths.port_leases -Value @($leases | Where-Object { [string]$_.lease_id -ne $LeaseId })
    Update-WorkforceMetrics -StateRoot $StateRoot -Changes @{ ports_released = 1 } | Out-Null
    return $true
}

function Test-WorkforceProcessOwnership {
    param(
        [Parameter(Mandatory = $true)]$Resource,
        [string]$ExpectedSessionId,
        [string]$ExpectedOwnershipFingerprint
    )

    if ([int]$Resource.pid -le 0) {
        return [pscustomobject]@{ verified = $false; running = $false; reason = 'missing-pid'; process = $null }
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSessionId) -and [string]$Resource.session_id -ne $ExpectedSessionId) {
        return [pscustomobject]@{ verified = $false; running = $true; reason = 'session-mismatch'; process = $null }
    }
    $process = Get-Process -Id ([int]$Resource.pid) -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        return [pscustomobject]@{ verified = $true; running = $false; reason = 'not-running'; process = $null }
    }
    if ([string]::IsNullOrWhiteSpace([string]$Resource.process_start_time)) {
        return [pscustomobject]@{ verified = $false; running = $true; reason = 'missing-start-time'; process = $process }
    }
    try {
        $expectedStart = [DateTimeOffset]::Parse([string]$Resource.process_start_time).UtcDateTime
        $actualStart = $process.StartTime.ToUniversalTime()
    }
    catch {
        return [pscustomobject]@{ verified = $false; running = $true; reason = 'start-time-unavailable'; process = $process }
    }
    if ([math]::Abs(($actualStart - $expectedStart).TotalSeconds) -gt 1) {
        return [pscustomobject]@{ verified = $false; running = $true; reason = 'pid-reused'; process = $process }
    }
    if ([string]::IsNullOrWhiteSpace([string]$Resource.executable)) {
        return [pscustomobject]@{ verified = $false; running = $true; reason = 'missing-executable'; process = $process }
    }
    $expectedExecutable = [IO.Path]::GetFileName([string]$Resource.executable)
    try {
        $processPath = [string]$process.Path
    }
    catch {
        $processPath = $null
    }
    $actualExecutable = if (-not [string]::IsNullOrWhiteSpace($processPath)) { [IO.Path]::GetFileName($processPath) } else { "$($process.ProcessName).exe" }
    if (-not $actualExecutable.Equals($expectedExecutable, [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ verified = $false; running = $true; reason = 'executable-mismatch'; process = $process }
    }
    if ([string]::IsNullOrWhiteSpace([string]$Resource.ownership_fingerprint)) {
        return [pscustomobject]@{ verified = $false; running = $true; reason = 'missing-ownership-fingerprint'; process = $process }
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedOwnershipFingerprint)) {
        return [pscustomobject]@{ verified = $false; running = $true; reason = 'ownership-fingerprint-unavailable'; process = $process }
    }
    if (-not ([string]$Resource.ownership_fingerprint).Equals($ExpectedOwnershipFingerprint, [StringComparison]::Ordinal)) {
        return [pscustomobject]@{ verified = $false; running = $true; reason = 'ownership-fingerprint-mismatch'; process = $process }
    }
    return [pscustomobject]@{ verified = $true; running = $true; reason = 'matched'; process = $process }
}

function Invoke-WorkforceResourceCleanup {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)]$Manifest,
        [ValidateRange(0, 300)][int]$GracefulShutdownSeconds = 10,
        [ValidateRange(0, 300)][int]$PortReleaseTimeoutSeconds = 15,
        [switch]$ForceOwnedResources
    )

    $stopped = [Collections.Generic.List[object]]::new()
    $leftRunning = [Collections.Generic.List[object]]::new()
    $releasedPorts = [Collections.Generic.List[object]]::new()
    $now = Get-WorkforceUtcNow
    foreach ($resource in @($Manifest.resources)) {
        $expired = -not [string]::IsNullOrWhiteSpace([string]$resource.expires_at) -and [DateTimeOffset]::Parse([string]$resource.expires_at) -le $now
        if ([bool]$resource.persistent -and -not $expired) {
            [void]$leftRunning.Add($resource)
            continue
        }
        if ([string]$resource.type -eq 'process') {
            $ownership = Test-WorkforceProcessOwnership -Resource $resource -ExpectedSessionId ([string]$Manifest.session_id) -ExpectedOwnershipFingerprint ([string]$Manifest.manifest_id)
            if (-not $ownership.running) {
                [void]$stopped.Add($resource)
                continue
            }
            if (-not $ownership.verified) {
                [void]$leftRunning.Add([pscustomobject]@{ resource = $resource; cleanup_error = $ownership.reason })
                continue
            }
            $process = $ownership.process
            try {
                [void]$process.CloseMainWindow()
                if ($GracefulShutdownSeconds -gt 0) {
                    [void]$process.WaitForExit($GracefulShutdownSeconds * 1000)
                }
                if (-not $process.HasExited -and $ForceOwnedResources) {
                    $process.Kill($true)
                    [void]$process.WaitForExit(5000)
                }
                if ($process.HasExited) {
                    [void]$stopped.Add($resource)
                }
                else {
                    [void]$leftRunning.Add([pscustomobject]@{ resource = $resource; cleanup_error = 'graceful-timeout' })
                }
            }
            catch {
                [void]$leftRunning.Add([pscustomobject]@{ resource = $resource; cleanup_error = 'process-stop-failed' })
            }
            finally {
                $process.Dispose()
            }
        }
    }

    $workerLeases = @(Get-WorkforcePortLeases -StateRoot $StateRoot | Where-Object {
        ([string]::IsNullOrWhiteSpace([string]$Manifest.worker_id) -or [string]$_.worker_id -eq [string]$Manifest.worker_id) -and
        ([string]::IsNullOrWhiteSpace([string]$Manifest.session_id) -or [string]$_.session_id -eq [string]$Manifest.session_id)
    })
    foreach ($lease in $workerLeases) {
        $deadline = (Get-WorkforceUtcNow).AddSeconds($PortReleaseTimeoutSeconds)
        while ((Test-WorkforcePortListening -Port ([int]$lease.port) -Protocol ([string]$lease.protocol)) -eq $true -and (Get-WorkforceUtcNow) -lt $deadline) {
            Start-Sleep -Milliseconds 100
        }
        if (Remove-WorkforcePortLease -StateRoot $StateRoot -LeaseId ([string]$lease.lease_id) -RequireReleasedPort) {
            [void]$releasedPorts.Add($lease)
        }
        else {
            [void]$leftRunning.Add([pscustomobject]@{ resource = $lease; cleanup_error = 'port-release-timeout' })
        }
    }

    $cleanupStatus = if ($leftRunning.Count -eq 0) { 'complete' } else { 'incomplete' }
    Update-WorkforceMetrics -StateRoot $StateRoot -Changes @{
        owned_processes_stopped = @($stopped | Where-Object { [string]$_.type -eq 'process' }).Count
        owned_processes_leaked = @($leftRunning | Where-Object { [string]$_.resource.type -eq 'process' }).Count
        ports_leaked = @($leftRunning | Where-Object { $null -ne $_.resource.port }).Count
        cleanup_incomplete_count = $(if ($cleanupStatus -eq 'incomplete') { 1 } else { 0 })
    } | Out-Null
    return [pscustomobject]@{
        postflight_completed = $true
        resources_stopped = @($stopped)
        resources_left_running = @($leftRunning)
        ports_released = @($releasedPorts)
        temporary_processes_stopped = @($stopped | Where-Object { [string]$_.type -eq 'process' }).Count
        temporary_ports_released = $releasedPorts.Count
        owned_processes_remaining = @($leftRunning | Where-Object { [string]$_.resource.type -eq 'process' }).Count
        owned_ports_remaining = @($leftRunning | Where-Object { $null -ne $_.resource.port }).Count
        cleanup_status = $cleanupStatus
    }
}

function Update-WorkforceMetrics {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][hashtable]$Changes
    )

    $paths = Initialize-WorkforceState -StateRoot $StateRoot
    $metrics = Read-WorkforceJson -Path $paths.metrics -DefaultValue ([pscustomobject]@{ schema_version = 1 })
    foreach ($entry in $Changes.GetEnumerator()) {
        if ($null -eq $metrics.PSObject.Properties[$entry.Key]) {
            $metrics | Add-Member -NotePropertyName $entry.Key -NotePropertyValue 0
        }
        if ($entry.Key -in @('active_worker_peak', 'burst_worker_peak')) {
            $metrics.$($entry.Key) = [math]::Max([long]$metrics.$($entry.Key), [long]$entry.Value)
        }
        else {
            $metrics.$($entry.Key) = [long]$metrics.$($entry.Key) + [long]$entry.Value
        }
    }
    $metrics.updated_at = (Get-WorkforceUtcNow).ToString('o')
    Write-WorkforceJson -Path $paths.metrics -Value $metrics
    return $metrics
}

function Invoke-WorkforceReconcile {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$Namespace,
        [Parameter(Mandatory = $true)][string]$CwdFingerprint,
        [Parameter(Mandatory = $true)][string]$TaskFingerprint,
        [Parameter(Mandatory = $true)][object[]]$Workers,
        [Parameter(Mandatory = $true)][ValidateSet('low', 'medium', 'high')][string]$InvocationLevel,
        [ValidateSet('fixed', 'adaptive')][string]$ConcurrencyPolicy = 'adaptive',
        [Parameter(Mandatory = $true)]$CircuitKey,
        [ValidateRange(0, 300)][int]$GracefulShutdownSeconds = 10,
        [ValidateRange(0, 300)][int]$PortReleaseTimeoutSeconds = 15,
        [switch]$ForceOwnedResources
    )

    [void](Initialize-WorkforceState -StateRoot $StateRoot)
    $profile = Get-InvocationProfile -Level $InvocationLevel
    $circuit = Get-ApiCircuitState -StateRoot $StateRoot -CircuitKey $CircuitKey
    $currentLimit = Get-AdaptiveWorkerLimit -InvocationProfile $profile -CircuitState $circuit -ConcurrencyPolicy $ConcurrencyPolicy
    $terminalPattern = '^(stopped|done|completed|failed|error|dead|cancelled|exited)$'
    $ownedWorkers = @($Workers | Where-Object {
        $worker = $_
        $name = @('name', 'displayName', 'title') | ForEach-Object {
            $property = $worker.PSObject.Properties[$_]
            if ($property) { [string]$property.Value }
        } | Where-Object { $_ } | Select-Object -First 1
        [string]$name -like "$Namespace-*"
    })
    $activeWorkers = @($ownedWorkers | Where-Object { [string]$_.state -notmatch $terminalPattern })
    $manifests = @(Get-WorkforceManifests -StateRoot $StateRoot)
    $matching = @($manifests | Where-Object {
        [string]$_.namespace -eq $Namespace -and [string]$_.cwd_fingerprint -eq $CwdFingerprint -and [string]$_.task_fingerprint -eq $TaskFingerprint
    } | Sort-Object updated_at -Descending)
    $activeMatch = @($matching | Where-Object { [string]$_.status -in @('acquired', 'running', 'waiting', 'needs-input') }) | Select-Object -First 1
    $completedMatch = @($matching | Where-Object { [string]$_.status -in @('completed', 'failed', 'error', 'cancelled') }) | Select-Object -First 1

    $staleResourcesCleaned = 0
    $stalePortsReleased = 0
    foreach ($manifest in @($manifests | Where-Object {
        [string]$_.namespace -eq $Namespace -and [string]$_.status -in @('completed', 'failed', 'error', 'cancelled')
    })) {
        $cleanup = Invoke-WorkforceResourceCleanup -StateRoot $StateRoot -Manifest $manifest -GracefulShutdownSeconds $GracefulShutdownSeconds -PortReleaseTimeoutSeconds $PortReleaseTimeoutSeconds -ForceOwnedResources:$ForceOwnedResources
        $staleResourcesCleaned += $cleanup.temporary_processes_stopped
        $stalePortsReleased += $cleanup.temporary_ports_released
        $manifest.cleanup_status = $cleanup.cleanup_status
        $manifest.resources_left_running = @($cleanup.resources_left_running)
        Save-WorkforceManifest -StateRoot $StateRoot -Manifest $manifest | Out-Null
    }

    $duplicate = $null -ne $activeMatch
    $completedAvailable = $null -ne $completedMatch
    $dispatchAllowed = -not $duplicate -and -not $completedAvailable -and $currentLimit -gt $activeWorkers.Count
    $reason = if ($duplicate) { 'duplicate-task-active' } elseif ($completedAvailable) { 'completed-manifest-available' } elseif ($circuit.state -eq 'open') { 'api-circuit-open' } elseif ($currentLimit -le $activeWorkers.Count) { 'worker-capacity-exhausted' } else { 'allowed' }
    if ($duplicate) {
        Update-WorkforceMetrics -StateRoot $StateRoot -Changes @{ duplicate_dispatches_prevented = 1; sessions_reused = 1 } | Out-Null
    }
    return [pscustomobject]@{
        action = 'reconcile'
        invocation_level = $InvocationLevel
        max_active_workers = $profile.max_active_workers
        burst_max_workers = $profile.burst_max_workers
        max_nested_agents = $profile.max_nested_agents
        current_active_workers = $activeWorkers.Count
        available_worker_slots = [math]::Max(0, $currentLimit - $activeWorkers.Count)
        adaptive_worker_limit = $currentLimit
        concurrency_policy = $ConcurrencyPolicy
        concurrency_reduced = $currentLimit -lt $profile.max_active_workers
        reused_worker = $activeMatch
        completed_manifest = $completedMatch
        duplicate_task_found = $duplicate
        duplicate_task_prevented = $duplicate
        stale_workers_cleaned = 0
        stale_processes_cleaned = $staleResourcesCleaned
        stale_ports_released = $stalePortsReleased
        api_circuit_state = $circuit.state
        dispatch_allowed = $dispatchAllowed
        dispatch_reason = $reason
        reconcile_performed = $true
    }
}

function Invoke-WorkforcePostflight {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)]$Manifest,
        [AllowNull()]$Result,
        [ValidateRange(0, 300)][int]$GracefulShutdownSeconds = 10,
        [ValidateRange(0, 300)][int]$PortReleaseTimeoutSeconds = 15,
        [switch]$ForceOwnedResources
    )

    $cleanup = Invoke-WorkforceResourceCleanup -StateRoot $StateRoot -Manifest $Manifest -GracefulShutdownSeconds $GracefulShutdownSeconds -PortReleaseTimeoutSeconds $PortReleaseTimeoutSeconds -ForceOwnedResources:$ForceOwnedResources
    $Manifest.status = if ($null -ne $Result -and [bool]$Result.is_error) { 'failed' } else { 'completed' }
    $Manifest.completed_at = (Get-WorkforceUtcNow).ToString('o')
    $Manifest.result = $Result
    $Manifest.resources_stopped = @($cleanup.resources_stopped)
    $Manifest.resources_left_running = @($cleanup.resources_left_running)
    $Manifest.ports_released = @($cleanup.ports_released)
    $Manifest.cleanup_status = $cleanup.cleanup_status
    Save-WorkforceManifest -StateRoot $StateRoot -Manifest $Manifest | Out-Null
    $paths = Get-WorkforceStatePaths -StateRoot $StateRoot
    Write-WorkforceJson -Path (Join-Path $paths.results "$($Manifest.manifest_id).json") -Value $Manifest
    return $cleanup
}

function Get-WorkforceResourceSummary {
    param([Parameter(Mandatory = $true)][string]$StateRoot)

    $manifests = @(Get-WorkforceManifests -StateRoot $StateRoot)
    $leases = @(Get-WorkforcePortLeases -StateRoot $StateRoot)
    return [pscustomobject]@{
        manifests = $manifests
        resources = @($manifests | ForEach-Object { @($_.resources) })
        port_leases = $leases
        cleanup_incomplete = @($manifests | Where-Object { [string]$_.cleanup_status -eq 'incomplete' }).Count
    }
}
