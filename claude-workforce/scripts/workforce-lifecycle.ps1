$stateScript = Join-Path $PSScriptRoot 'workforce-state.ps1'
if (-not (Test-Path -LiteralPath $stateScript -PathType Leaf)) {
    throw "Workforce state module is missing: $stateScript"
}
. $stateScript

function Get-WorkforceHash {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $hash = [Security.Cryptography.SHA256]::HashData($bytes)
    return ([Convert]::ToHexString($hash)).ToLowerInvariant()
}

function Get-WorkforceUtcNow {
    return [DateTimeOffset]::UtcNow
}

function Test-WorkforceCleanupRetryDue {
    param([Parameter(Mandatory = $true)]$Manifest)

    if ($null -eq $Manifest.PSObject.Properties['cleanup_retry_after'] -or [string]::IsNullOrWhiteSpace([string]$Manifest.cleanup_retry_after)) {
        return $true
    }
    try {
        return [DateTimeOffset]::Parse([string]$Manifest.cleanup_retry_after) -le (Get-WorkforceUtcNow)
    }
    catch {
        return $true
    }
}

function Get-WorkforceStatePaths {
    param([Parameter(Mandatory = $true)][string]$StateRoot)

    $resolvedRoot = [IO.Path]::GetFullPath($StateRoot)
    return [pscustomobject]@{
        root = $resolvedRoot
        state_version = Join-Path $resolvedRoot 'state-version.json'
        port_leases = Join-Path $resolvedRoot 'port-leases.json'
        circuit_breakers = Join-Path $resolvedRoot 'circuit-breakers.json'
        resource_index = Join-Path $resolvedRoot 'resource-index.json'
        capability_cache = Join-Path $resolvedRoot 'capability-cache.json'
        environment_fingerprints = Join-Path $resolvedRoot 'environment-fingerprints.json'
        metrics = Join-Path $resolvedRoot 'metrics.json'
        manifests = Join-Path $resolvedRoot 'manifests'
        worker_reports = Join-Path $resolvedRoot 'worker-reports'
        broker_resources = Join-Path $resolvedRoot 'broker-resources'
        backups = Join-Path $resolvedRoot 'backups'
        locks = Join-Path $resolvedRoot 'locks'
        results = Join-Path $resolvedRoot 'results'
        broker_key = Join-Path $resolvedRoot 'broker.key'
    }
}

$brokerScript = Join-Path $PSScriptRoot 'workforce-resource-broker.ps1'
if (-not (Test-Path -LiteralPath $brokerScript -PathType Leaf)) {
    throw "Workforce resource broker module is missing: $brokerScript"
}
. $brokerScript

function Write-WorkforceJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowNull()]$Value
    )

    Write-WorkforceState -Path $Path -Value $Value
}

function Read-WorkforceJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowNull()]$DefaultValue
    )

    return Read-WorkforceState -Path $Path -DefaultValue $DefaultValue -RestoreFromBackup
}

function Initialize-WorkforceState {
    param([Parameter(Mandatory = $true)][string]$StateRoot)

    $paths = Get-WorkforceStatePaths -StateRoot $StateRoot
    Invoke-WorkforceStateTransaction -StateRoot $StateRoot -LockName 'initialize' -ScriptBlock {
        foreach ($directory in @($paths.root, $paths.manifests, $paths.worker_reports, $paths.broker_resources, $paths.backups, $paths.locks, $paths.results)) {
            if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
                [void](New-Item -ItemType Directory -Path $directory -Force)
            }
        }
        foreach ($file in @($paths.port_leases, $paths.circuit_breakers, $paths.environment_fingerprints)) {
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
                Write-WorkforceState -Path $file -Value @() -SkipBackup
            }
        }
        if (-not (Test-Path -LiteralPath $paths.state_version -PathType Leaf)) {
            $legacyStatePresent = Test-Path -LiteralPath $paths.resource_index -PathType Leaf
            Write-WorkforceState -Path $paths.state_version -Value ([ordered]@{
                schema_version = $(if ($legacyStatePresent) { 1 } else { 2 })
                migration_required = [bool]$legacyStatePresent
                initialized_at = (Get-WorkforceUtcNow).ToString('o')
            }) -SkipBackup
        }
        if (-not (Test-Path -LiteralPath $paths.capability_cache -PathType Leaf)) {
            Write-WorkforceState -Path $paths.capability_cache -Value ([ordered]@{ schema_version = 2; entries = @() }) -SkipBackup
        }
        if (-not (Test-Path -LiteralPath $paths.metrics -PathType Leaf)) {
            Write-WorkforceState -Path $paths.metrics -Value ([ordered]@{
                schema_version = 2
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
                lock_recovered_count = 0
                revision_conflict_count = 0
                updated_at = (Get-WorkforceUtcNow).ToString('o')
            }) -SkipBackup
        }
    } | Out-Null
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

function Update-WorkforceEnvironmentFingerprint {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$Namespace,
        [Parameter(Mandatory = $true)][string]$Fingerprint
    )

    $paths = Initialize-WorkforceState -StateRoot $StateRoot
    return Invoke-WorkforceStateTransaction -StateRoot $StateRoot -LockName 'environment-fingerprints' -ScriptBlock {
        $entries = @(Read-WorkforceState -Path $paths.environment_fingerprints -DefaultValue @() -RestoreFromBackup)
        $previous = @($entries | Where-Object { [string]$_.namespace -eq $Namespace } | Sort-Object checked_at -Descending) | Select-Object -First 1
        $changed = $null -ne $previous -and [string]$previous.fingerprint -ne $Fingerprint
        $entry = [pscustomobject][ordered]@{
            schema_version = 2
            namespace = $Namespace
            fingerprint = $Fingerprint
            previous_fingerprint = $(if ($null -ne $previous) { [string]$previous.fingerprint } else { $null })
            changed = [bool]$changed
            checked_at = (Get-WorkforceUtcNow).ToString('o')
        }
        Write-WorkforceState -Path $paths.environment_fingerprints -Value (@($entries | Where-Object { [string]$_.namespace -ne $Namespace }) + @($entry))
        return $entry
    }
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
    return Invoke-WorkforceStateTransaction -StateRoot $StateRoot -LockName 'circuit-breakers' -ScriptBlock {
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
                Write-WorkforceState -Path $paths.circuit_breakers -Value $updated
            }
        }
        return $record
    }
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
    $now = Get-WorkforceUtcNow
    $previousState = 'closed'
    $record = Invoke-WorkforceStateTransaction -StateRoot $StateRoot -LockName 'circuit-breakers' -ScriptBlock {
        $records = @(Read-WorkforceJson -Path $paths.circuit_breakers -DefaultValue @())
        $record = @($records | Where-Object { [string]$_.key -eq [string]$CircuitKey.key }) | Select-Object -First 1
        if ($null -eq $record) {
            $record = [pscustomobject]@{
                key = $CircuitKey.key
                provider = $CircuitKey.provider
                endpoint_fingerprint = $CircuitKey.endpoint_fingerprint
                model = $CircuitKey.model
                state = 'closed'
                failure_count = 0
                failure_timestamps = @()
                opened_at = $null
                updated_at = $now.ToString('o')
            }
        }
        $previousState = [string]$record.state
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
        Write-WorkforceState -Path $paths.circuit_breakers -Value $updated
        return $record
    }
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
    $manifests = [Collections.Generic.List[object]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $paths.manifests -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        try {
            $manifest = Read-WorkforceJson -Path $file.FullName -DefaultValue $null
            if ($null -eq $manifest) {
                throw 'empty-manifest'
            }
            [void]$manifests.Add((ConvertTo-WorkforceManifestV2 -Manifest $manifest))
        }
        catch {
            [void]$manifests.Add([pscustomobject][ordered]@{
                schema_version = 2
                revision = 0
                manifest_id = [IO.Path]::GetFileNameWithoutExtension($file.Name)
                status = 'corrupt'
                cleanup_status = 'incomplete'
                corruption_reason = 'invalid-json-or-schema'
                updated_at = $file.LastWriteTimeUtc.ToString('o')
            })
        }
    }
    return @($manifests)
}

function Set-WorkforceObjectProperty {
    param(
        [Parameter(Mandatory = $true)]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()]$Value
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        $InputObject | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
    else {
        $property.Value = $Value
    }
}

function ConvertTo-WorkforceManifestV2 {
    param([Parameter(Mandatory = $true)]$Manifest)

    if ([string]::IsNullOrWhiteSpace([string]$Manifest.manifest_id)) {
        throw 'Resource manifest requires manifest_id.'
    }
    if ($null -ne $Manifest.PSObject.Properties['schema_version'] -and [int]$Manifest.schema_version -notin @(1, 2)) {
        throw "Unsupported workforce manifest schema: $($Manifest.schema_version)"
    }
    $status = [string]$Manifest.status
    switch ($status) {
        'error' { $status = 'failed' }
        'launch-unverified' { $status = 'waiting' }
        'stop-unverified' { $status = 'cleanup-incomplete' }
        default { }
    }
    if ([string]::IsNullOrWhiteSpace($status)) {
        $status = 'acquired'
    }
    if ($status -notin @('created', 'acquired', 'running', 'waiting', 'needs-input', 'finalizing', 'completed', 'failed', 'cancelled', 'stopped', 'cleanup-incomplete', 'removed', 'stale', 'corrupt')) {
        throw "Unsupported workforce manifest status: $status"
    }
    Set-WorkforceObjectProperty -InputObject $Manifest -Name schema_version -Value 2
    if ($null -eq $Manifest.PSObject.Properties['revision']) {
        Set-WorkforceObjectProperty -InputObject $Manifest -Name revision -Value 0
    }
    Set-WorkforceObjectProperty -InputObject $Manifest -Name status -Value $status
    foreach ($name in @('resources', 'resources_stopped', 'resources_left_running', 'ports_acquired', 'ports_released', 'api_errors', 'mcp_errors')) {
        if ($null -eq $Manifest.PSObject.Properties[$name]) {
            Set-WorkforceObjectProperty -InputObject $Manifest -Name $name -Value @()
        }
    }
    if ($null -eq $Manifest.PSObject.Properties['cleanup_status']) {
        Set-WorkforceObjectProperty -InputObject $Manifest -Name cleanup_status -Value 'pending'
    }
    foreach ($resource in @($Manifest.resources)) {
        if ($null -eq $resource.PSObject.Properties['ownership_method']) {
            Set-WorkforceObjectProperty -InputObject $resource -Name ownership_method -Value 'legacy-unverified'
        }
        if ($null -eq $resource.PSObject.Properties['broker_signature']) {
            Set-WorkforceObjectProperty -InputObject $resource -Name broker_signature -Value $null
        }
    }
    return $Manifest
}

function Invoke-WorkforceStateMigration {
    param([Parameter(Mandatory = $true)][string]$StateRoot)

    $paths = Initialize-WorkforceState -StateRoot $StateRoot
    return Invoke-WorkforceStateTransaction -StateRoot $StateRoot -LockName 'state-migration-gate' -ScriptBlock {
        $timestamp = (Get-WorkforceUtcNow).ToString('yyyyMMdd-HHmmss-fff')
        $backupRoot = Join-Path $paths.backups "migration-v1-$timestamp"
        [void](New-Item -ItemType Directory -Path $backupRoot -Force)
        $snapshotRoot = Join-Path $backupRoot 'state-root'
        [void](New-Item -ItemType Directory -Path $snapshotRoot -Force)
        foreach ($entry in @(Get-ChildItem -LiteralPath $paths.root -Force -ErrorAction SilentlyContinue)) {
            if ($entry.Name -in @('backups', 'locks')) {
                continue
            }
            Copy-Item -LiteralPath $entry.FullName -Destination $snapshotRoot -Recurse -Force
        }
        $snapshotBrokerKey = Join-Path $snapshotRoot 'broker.key'
        if (Test-Path -LiteralPath $snapshotBrokerKey -PathType Leaf) {
            if (-not (Protect-WorkforceBrokerKey -Path $snapshotBrokerKey) -or -not (Test-WorkforceBrokerKeyAcl -Path $snapshotBrokerKey)) {
                Remove-Item -LiteralPath $snapshotBrokerKey -Force -ErrorAction SilentlyContinue
                throw 'migration-backup-broker-key-acl-failed'
            }
        }
        if (Test-Path -LiteralPath $paths.state_version -PathType Leaf) {
            Copy-Item -LiteralPath $paths.state_version -Destination (Join-Path $backupRoot 'state-version.json') -Force
        }
        $candidates = [Collections.Generic.List[object]]::new()
        if (Test-Path -LiteralPath $paths.resource_index -PathType Leaf) {
            Copy-Item -LiteralPath $paths.resource_index -Destination (Join-Path $backupRoot 'resource-index.json') -Force
            foreach ($manifest in @(Read-WorkforceState -Path $paths.resource_index -DefaultValue @())) {
                [void]$candidates.Add($manifest)
            }
        }
        foreach ($file in @(Get-ChildItem -LiteralPath $paths.manifests -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $backupRoot $file.Name) -Force
            try {
                $manifest = Read-WorkforceState -Path $file.FullName -DefaultValue $null
                if ($null -ne $manifest) {
                    [void]$candidates.Add($manifest)
                }
            }
            catch {
            }
        }
        $migrated = 0
        $legacyResources = 0
        $selected = foreach ($group in @($candidates | Group-Object -Property manifest_id)) {
            @($group.Group | Sort-Object @{ Expression = { if ($null -ne $_.revision) { [int]$_.revision } else { 0 } }; Descending = $true }, @{ Expression = { try { [DateTimeOffset]::Parse([string]$_.updated_at) } catch { [DateTimeOffset]::MinValue } }; Descending = $true }) | Select-Object -First 1
        }
        foreach ($manifest in @($selected)) {
            $converted = ConvertTo-WorkforceManifestV2 -Manifest $manifest
            foreach ($resource in @($converted.resources)) {
                $resource.ownership_method = 'legacy-unverified'
                $resource.broker_signature = $null
                $legacyResources++
            }
            $manifestPath = Join-Path $paths.manifests "$($converted.manifest_id).json"
            Set-WorkforceObjectProperty -InputObject $converted -Name revision -Value 1
            Set-WorkforceObjectProperty -InputObject $converted -Name updated_at -Value (Get-WorkforceUtcNow).ToString('o')
            Write-WorkforceState -Path $manifestPath -Value $converted
            $migrated++
        }
        if (Test-Path -LiteralPath $paths.resource_index -PathType Leaf) {
            Remove-Item -LiteralPath $paths.resource_index -Force
        }
        Write-WorkforceState -Path $paths.state_version -Value ([ordered]@{
            schema_version = 2
            migrated_at = (Get-WorkforceUtcNow).ToString('o')
            source_schema_version = 1
            backup_path = $backupRoot
        })
        $report = [pscustomobject]@{
            migrated = $true
            manifests_migrated = $migrated
            legacy_unverified_resources = $legacyResources
            backup_path = $backupRoot
            schema_version = 2
        }
        Write-WorkforceState -Path (Join-Path $backupRoot 'migration-report.json') -Value $report -SkipBackup
        return $report
    }
}

function Restore-WorkforceStateMigration {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$BackupPath
    )

    $paths = Initialize-WorkforceState -StateRoot $StateRoot
    $resolvedBackup = [IO.Path]::GetFullPath($BackupPath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $backupBoundary = [IO.Path]::GetFullPath($paths.backups).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not ($resolvedBackup + [IO.Path]::DirectorySeparatorChar).StartsWith($backupBoundary, $(if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }))) {
        throw 'migration-rollback-denied: backup path is outside the workforce backup root'
    }
    if (-not (Test-Path -LiteralPath $resolvedBackup -PathType Container)) {
        throw 'migration-rollback-denied: backup path does not exist'
    }
    return Invoke-WorkforceStateTransaction -StateRoot $StateRoot -LockName 'state-migration-gate' -ScriptBlock {
        $snapshotRoot = Join-Path $resolvedBackup 'state-root'
        if (Test-Path -LiteralPath $snapshotRoot -PathType Container) {
            foreach ($entry in @(Get-ChildItem -LiteralPath $paths.root -Force -ErrorAction SilentlyContinue)) {
                if ($entry.Name -in @('backups', 'locks')) {
                    continue
                }
                Remove-Item -LiteralPath $entry.FullName -Recurse -Force
            }
            foreach ($entry in @(Get-ChildItem -LiteralPath $snapshotRoot -Force -ErrorAction SilentlyContinue)) {
                Copy-Item -LiteralPath $entry.FullName -Destination $paths.root -Recurse -Force
            }
            if (Test-Path -LiteralPath $paths.broker_key -PathType Leaf) {
                if (-not (Protect-WorkforceBrokerKey -Path $paths.broker_key) -or -not (Test-WorkforceBrokerKeyAcl -Path $paths.broker_key)) {
                    Remove-Item -LiteralPath $paths.broker_key -Force -ErrorAction SilentlyContinue
                    throw 'migration-rollback-broker-key-acl-failed'
                }
            }
            $restored = @(Get-ChildItem -LiteralPath $paths.manifests -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
            return [pscustomobject]@{ rolled_back = $true; manifests_restored = $restored; full_snapshot_restored = $true; backup_path = $resolvedBackup }
        }
        $restored = 0
        foreach ($current in @(Get-ChildItem -LiteralPath $paths.manifests -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $current.FullName -Force
        }
        foreach ($file in @(Get-ChildItem -LiteralPath $resolvedBackup -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            if ($file.Name -in @('state-version.json', 'resource-index.json', 'migration-report.json')) {
                continue
            }
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $paths.manifests $file.Name) -Force
            $restored++
        }
        foreach ($name in @('state-version.json', 'resource-index.json')) {
            $source = Join-Path $resolvedBackup $name
            if (Test-Path -LiteralPath $source -PathType Leaf) {
                Copy-Item -LiteralPath $source -Destination (Join-Path $paths.root $name) -Force
            }
            elseif ($name -eq 'resource-index.json' -and (Test-Path -LiteralPath $paths.resource_index -PathType Leaf)) {
                Remove-Item -LiteralPath $paths.resource_index -Force
            }
        }
        return [pscustomobject]@{ rolled_back = $true; manifests_restored = $restored; full_snapshot_restored = $false; backup_path = $resolvedBackup }
    }
}

function Read-WorkforceWorkerReport {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$ManifestId
    )

    $paths = Initialize-WorkforceState -StateRoot $StateRoot
    $path = Join-Path $paths.worker_reports "$ManifestId.json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    $report = Read-WorkforceState -Path $path -DefaultValue $null -RestoreFromBackup
    if ($null -eq $report -or [string]$report.manifest_id -ne $ManifestId) {
        throw 'worker-report-invalid: manifest-mismatch'
    }
    if ([string]$report.reported_status -notin @('running', 'waiting', 'needs-input', 'finalizing', 'completed', 'failed', 'cancelled')) {
        throw 'worker-report-invalid: status'
    }
    return $report
}

function Test-WorkforceManifestTransition {
    param(
        [AllowEmptyString()][string]$From,
        [Parameter(Mandatory = $true)][string]$To
    )

    if ([string]::IsNullOrWhiteSpace($From) -or $From -eq $To) {
        return $true
    }
    $allowed = @{
        created = @('acquired', 'failed', 'cancelled')
        acquired = @('running', 'finalizing', 'failed', 'cancelled')
        running = @('waiting', 'needs-input', 'finalizing', 'failed', 'cancelled', 'stale')
        waiting = @('running', 'needs-input', 'finalizing', 'failed', 'cancelled', 'stale')
        'needs-input' = @('running', 'waiting', 'finalizing', 'cancelled', 'stale')
        finalizing = @('completed', 'failed', 'cancelled', 'stopped', 'cleanup-incomplete')
        completed = @('removed')
        failed = @('removed')
        cancelled = @('removed')
        stopped = @('removed')
        'cleanup-incomplete' = @('completed', 'failed', 'cancelled', 'stopped', 'removed')
        stale = @('finalizing', 'removed')
        corrupt = @('removed')
    }
    return $allowed.ContainsKey($From) -and $To -in @($allowed[$From])
}

function Save-WorkforceManifest {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)]$Manifest,
        [int]$ExpectedRevision = -1
    )

    $paths = Initialize-WorkforceState -StateRoot $StateRoot
    $Manifest = ConvertTo-WorkforceManifestV2 -Manifest $Manifest
    $manifestPath = Join-Path $paths.manifests "$($Manifest.manifest_id).json"
    $lockName = "manifest-$($Manifest.manifest_id)"
    return Invoke-WorkforceStateTransaction -StateRoot $StateRoot -LockName 'state-migration-gate' -ScriptBlock {
        Invoke-WorkforceStateTransaction -StateRoot $StateRoot -LockName $lockName -ScriptBlock {
            $existing = if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
                ConvertTo-WorkforceManifestV2 -Manifest (Read-WorkforceJson -Path $manifestPath -DefaultValue $null)
            }
            else {
                $null
            }
            $currentRevision = if ($null -eq $existing) { 0 } else { [int]$existing.revision }
            $callerRevision = if ($ExpectedRevision -ge 0) { $ExpectedRevision } else { [int]$Manifest.revision }
            if ($null -ne $existing -and $callerRevision -ne $currentRevision) {
                throw "manifest-revision-conflict: expected $callerRevision, current $currentRevision"
            }
            if ($null -eq $existing -and $ExpectedRevision -gt 0) {
                throw "manifest-revision-conflict: manifest does not exist at revision $ExpectedRevision"
            }
            if ($null -ne $existing -and -not (Test-WorkforceManifestTransition -From ([string]$existing.status) -To ([string]$Manifest.status))) {
                throw "invalid-manifest-transition: $($existing.status) -> $($Manifest.status)"
            }
            Set-WorkforceObjectProperty -InputObject $Manifest -Name revision -Value ($currentRevision + 1)
            Set-WorkforceObjectProperty -InputObject $Manifest -Name updated_at -Value (Get-WorkforceUtcNow).ToString('o')
            Write-WorkforceState -Path $manifestPath -Value $Manifest
        } | Out-Null
        return $Manifest
    }
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
        schema_version = 2
        revision = 0
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
        [string]$OwnershipFingerprint,
        [string]$ManifestId,
        [string]$ResourceId,
        [switch]$AllowOwnedListener
    )

    $paths = Initialize-WorkforceState -StateRoot $StateRoot
    if ($Port -eq 0) {
        if ($Protocol -ne 'tcp') {
            throw 'Dynamic port selection currently supports TCP only.'
        }
        $Port = Get-WorkforceDynamicTcpPort
    }
    $now = Get-WorkforceUtcNow
    $lease = Invoke-WorkforceStateTransaction -StateRoot $StateRoot -LockName 'port-leases' -ScriptBlock {
        $leases = @(Read-WorkforceJson -Path $paths.port_leases -DefaultValue @())
        $active = @($leases | Where-Object {
            [int]$_.port -eq $Port -and [string]$_.protocol -eq $Protocol -and
            [string]$_.state -notin @('released', 'expired', 'conflict') -and
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
        if ($listening -eq $true -and -not $AllowOwnedListener) {
            throw "Port $Port/$Protocol is already used by an unowned process; it will not be terminated."
        }
        $effectiveTtl = if ($ProcessId -le 0) { [math]::Min($TtlSeconds, 5) } else { $TtlSeconds }
        $newLease = [pscustomobject][ordered]@{
            schema_version = 2
            lease_id = (Get-WorkforceHash -Text "$SessionId`n$WorkerId`n$Protocol`n$Port").Substring(0, 24)
            state = $(if ($ProcessId -gt 0) { 'requested' } else { 'reserved' })
            port = $Port
            protocol = $Protocol
            manifest_id = $ManifestId
            session_id = $SessionId
            worker_id = $WorkerId
            resource_id = $ResourceId
            pid = $(if ($ProcessId -gt 0) { $ProcessId } else { $null })
            process_start_time = $ProcessStartTime
            purpose = $Purpose
            persistent = [bool]$Persistent
            ownership_fingerprint = $OwnershipFingerprint
            broker_signature = $null
            created_at = $now.ToString('o')
            bound_at = $null
            released_at = $null
            expires_at = $now.AddSeconds($effectiveTtl).ToString('o')
        }
        Write-WorkforceState -Path $paths.port_leases -Value (@($leases) + @($newLease))
        return $newLease
    }
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
    $removed = Invoke-WorkforceStateTransaction -StateRoot $StateRoot -LockName 'port-leases' -ScriptBlock {
        $leases = @(Read-WorkforceJson -Path $paths.port_leases -DefaultValue @())
        $lease = @($leases | Where-Object { [string]$_.lease_id -eq $LeaseId }) | Select-Object -First 1
        if ($null -eq $lease) {
            return $false
        }
        if ($RequireReleasedPort -and (Test-WorkforcePortListening -Port ([int]$lease.port) -Protocol ([string]$lease.protocol)) -eq $true) {
            return $false
        }
        if ([string]$lease.state -eq 'released') {
            return $true
        }
        $lease.state = 'released'
        $lease.released_at = (Get-WorkforceUtcNow).ToString('o')
        $keyInfo = Get-WorkforceBrokerKeyInfo -StateRoot $StateRoot
        if ($keyInfo.present -and [string]$lease.broker_signature -match '^[0-9a-fA-F]{64}$') {
            $lease.broker_signature = Get-WorkforcePortLeaseSignature -Key $keyInfo.key -Lease $lease
        }
        Write-WorkforceState -Path $paths.port_leases -Value @($leases)
        return $true
    }
    if (-not $removed) {
        return $false
    }
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
        $expectedStart = [DateTimeOffset]::Parse((ConvertTo-WorkforceBrokerTimestampText -Value $Resource.process_start_time), [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
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
    $brokerResources = @(Get-WorkforceOwnedResources -StateRoot $StateRoot -ManifestId ([string]$Manifest.manifest_id))
    $cleanupResources = [Collections.Generic.List[object]]::new()
    foreach ($resource in $brokerResources) {
        $expired = -not [string]::IsNullOrWhiteSpace([string]$resource.expires_at) -and [DateTimeOffset]::Parse([string]$resource.expires_at) -le $now
        if ([bool]$resource.persistent -and -not $expired) {
            [void]$leftRunning.Add($resource)
            continue
        }
        [void]$cleanupResources.Add($resource)
    }

    foreach ($resource in @($cleanupResources | Where-Object { [string]$_.type -eq 'process' })) {
        $stopResult = Stop-WorkforceOwnedResource -StateRoot $StateRoot -Resource $resource -ExpectedManifestId ([string]$Manifest.manifest_id) -ExpectedWorkerId ([string]$Manifest.worker_id) -ExpectedSessionId ([string]$Manifest.session_id) -Force:$ForceOwnedResources
        if ($stopResult.verified_stopped) {
            [void]$stopped.Add([pscustomobject]@{ resource = $resource; cleanup = $stopResult })
            $paths = Get-WorkforceStatePaths -StateRoot $StateRoot
            $resourcePath = Join-Path $paths.broker_resources "$($resource.resource_id).json"
            if (Test-Path -LiteralPath $resourcePath -PathType Leaf) {
                Invoke-WorkforceStateTransaction -StateRoot $StateRoot -LockName "broker-$($resource.resource_id)" -ScriptBlock {
                    Remove-Item -LiteralPath $resourcePath -Force
                } | Out-Null
            }
        }
        else {
            [void]$leftRunning.Add([pscustomobject]@{ resource = $resource; cleanup_error = $stopResult.cleanup_error; cleanup = $stopResult })
        }
    }

    foreach ($resource in @($cleanupResources | Where-Object { [string]$_.type -eq 'mcp' })) {
        $mcpTrust = Test-WorkforceResourceOwnership -StateRoot $StateRoot -Resource $resource -ExpectedManifestId ([string]$Manifest.manifest_id) -ExpectedWorkerId ([string]$Manifest.worker_id) -ExpectedSessionId ([string]$Manifest.session_id)
        if (-not $mcpTrust.verified) {
            [void]$leftRunning.Add([pscustomobject]@{ resource = $resource; cleanup_error = $mcpTrust.reason })
            continue
        }
        $linkedProcess = @($brokerResources | Where-Object {
            [string]$_.resource_id -eq [string]$resource.process_resource_id -and [string]$_.type -eq 'process'
        }) | Select-Object -First 1
        if ($null -eq $linkedProcess) {
            [void]$leftRunning.Add([pscustomobject]@{ resource = $resource; cleanup_error = 'mcp-process-resource-missing' })
            continue
        }
        $linkedOwnership = Test-WorkforceResourceOwnership -StateRoot $StateRoot -Resource $linkedProcess -ExpectedManifestId ([string]$Manifest.manifest_id) -ExpectedWorkerId ([string]$Manifest.worker_id) -ExpectedSessionId ([string]$Manifest.session_id)
        if (-not $linkedOwnership.verified -or $linkedOwnership.running) {
            [void]$leftRunning.Add([pscustomobject]@{ resource = $resource; cleanup_error = $(if ($linkedOwnership.running) { 'mcp-process-still-running' } else { $linkedOwnership.reason }) })
            if ($null -ne $linkedOwnership.process) { $linkedOwnership.process.Dispose() }
            continue
        }
        $paths = Get-WorkforceStatePaths -StateRoot $StateRoot
        $resourcePath = Join-Path $paths.broker_resources "$($resource.resource_id).json"
        if (Test-Path -LiteralPath $resourcePath -PathType Leaf) {
            Invoke-WorkforceStateTransaction -StateRoot $StateRoot -LockName "broker-$($resource.resource_id)" -ScriptBlock {
                Remove-Item -LiteralPath $resourcePath -Force
            } | Out-Null
        }
    }

    foreach ($resource in @($cleanupResources | Where-Object { [string]$_.type -notin @('process', 'mcp') })) {
        [void]$leftRunning.Add([pscustomobject]@{ resource = $resource; cleanup_error = 'unsupported-resource-type' })
    }

    foreach ($resource in @($Manifest.resources)) {
        if ([string]$resource.type -ne 'process') {
            continue
        }
        [void]$leftRunning.Add([pscustomobject]@{
            resource = $resource
            cleanup_error = 'legacy-unverified'
        })
    }

    $workerLeases = @(Get-WorkforcePortLeases -StateRoot $StateRoot | Where-Object {
        ([string]::IsNullOrWhiteSpace([string]$Manifest.worker_id) -or [string]$_.worker_id -eq [string]$Manifest.worker_id) -and
        ([string]::IsNullOrWhiteSpace([string]$Manifest.session_id) -or [string]$_.session_id -eq [string]$Manifest.session_id) -and
        [string]$_.state -notin @('released', 'expired', 'conflict')
    })
    foreach ($lease in $workerLeases) {
        if ([string]$lease.state -eq 'bound') {
            $leaseTrust = Test-WorkforcePortLeaseSignature -StateRoot $StateRoot -Lease $lease
            if (-not $leaseTrust.verified) {
                [void]$leftRunning.Add([pscustomobject]@{ resource = $lease; cleanup_error = $leaseTrust.reason })
                continue
            }
        }
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
        owned_processes_stopped = @($stopped | Where-Object { [string]$_.resource.type -eq 'process' }).Count
        owned_processes_leaked = @($leftRunning | Where-Object { [string]$_.resource.type -eq 'process' }).Count
        ports_leaked = @($leftRunning | Where-Object { $null -ne $_.resource.port }).Count
        cleanup_incomplete_count = $(if ($cleanupStatus -eq 'incomplete') { 1 } else { 0 })
    } | Out-Null
    return [pscustomobject]@{
        postflight_completed = $true
        resources_stopped = @($stopped)
        resources_left_running = @($leftRunning)
        ports_released = @($releasedPorts)
        temporary_processes_stopped = @($stopped | Where-Object { [string]$_.resource.type -eq 'process' }).Count
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
    return Invoke-WorkforceStateTransaction -StateRoot $StateRoot -LockName 'metrics' -ScriptBlock {
        $metrics = Read-WorkforceJson -Path $paths.metrics -DefaultValue ([pscustomobject]@{ schema_version = 2 })
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
        Write-WorkforceState -Path $paths.metrics -Value $metrics
        return $metrics
    }
}

function Get-WorkforcePortOwnerProcessIds {
    param(
        [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$Port,
        [ValidateSet('tcp', 'udp')][string]$Protocol = 'tcp'
    )

    try {
        if ($IsWindows) {
            if ($Protocol -eq 'tcp' -and $null -ne (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
                try {
                    $processIds = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop | Select-Object -ExpandProperty OwningProcess -Unique)
                    return [pscustomobject]@{ verified = $true; process_ids = @($processIds | ForEach-Object { [int]$_ }); reason = 'net-tcp' }
                }
                catch {}
            }
            if ($Protocol -eq 'udp' -and $null -ne (Get-Command Get-NetUDPEndpoint -ErrorAction SilentlyContinue)) {
                try {
                    $processIds = @(Get-NetUDPEndpoint -LocalPort $Port -ErrorAction Stop | Select-Object -ExpandProperty OwningProcess -Unique)
                    return [pscustomobject]@{ verified = $true; process_ids = @($processIds | ForEach-Object { [int]$_ }); reason = 'net-udp' }
                }
                catch {}
            }
            $netstat = Get-Command netstat.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $netstat) {
                $protocolName = $Protocol.ToUpperInvariant()
                $lines = @(& $netstat.Source -ano -p $protocolName 2>$null)
                if ($LASTEXITCODE -ne 0) {
                    return [pscustomobject]@{ verified = $false; process_ids = @(); reason = 'owner-query-failed' }
                }
                $processIds = @(
                    foreach ($line in $lines) {
                        $fields = @(([string]$line).Trim() -split '\s+')
                        $minimumFields = if ($Protocol -eq 'tcp') { 5 } else { 4 }
                        if ($fields.Count -lt $minimumFields -or [string]$fields[0] -ne $protocolName -or [string]$fields[1] -notmatch ':(\d+)$' -or [int]$Matches[1] -ne $Port) {
                            continue
                        }
                        if ($Protocol -eq 'tcp' -and [string]$fields[3] -ne 'LISTENING') {
                            continue
                        }
                        $pidField = if ($Protocol -eq 'tcp') { [string]$fields[4] } else { [string]$fields[3] }
                        if ($pidField -match '^\d+$' -and [int]$pidField -gt 0) {
                            [int]$pidField
                        }
                    }
                )
                return [pscustomobject]@{ verified = $true; process_ids = @($processIds | Select-Object -Unique); reason = "netstat-$Protocol" }
            }
            return [pscustomobject]@{ verified = $false; process_ids = @(); reason = 'owner-query-unavailable' }
        }
        $lsof = Get-Command lsof -ErrorAction SilentlyContinue
        if ($null -eq $lsof) {
            return [pscustomobject]@{ verified = $false; process_ids = @(); reason = 'owner-query-unavailable' }
        }
        $selector = if ($Protocol -eq 'tcp') { "TCP:$Port" } else { "UDP:$Port" }
        $arguments = @('-nP', '-t', '-i', $selector)
        if ($Protocol -eq 'tcp') {
            $arguments += '-sTCP:LISTEN'
        }
        $processIds = @(& $lsof.Source @arguments 2>$null | Where-Object { [string]$_ -match '^\d+$' } | ForEach-Object { [int]$_ } | Select-Object -Unique)
        return [pscustomobject]@{ verified = $true; process_ids = $processIds; reason = 'lsof' }
    }
    catch {
        return [pscustomobject]@{ verified = $false; process_ids = @(); reason = 'owner-query-failed' }
    }
}

function ConvertTo-WorkforceWorkerState {
    param([AllowEmptyString()][string]$State)

    switch -Regex ($State.Trim().ToLowerInvariant()) {
        '^(working|running|active|busy)$' { return 'running' }
        '^(waiting|idle)$' { return 'waiting' }
        '^(needs[-_ ]?input|blocked|permission)$' { return 'needs-input' }
        '^(completed|done|success|succeeded)$' { return 'completed' }
        '^(failed|error|crashed)$' { return 'failed' }
        '^(stopped|cancelled|canceled|exited|dead|removed)$' { return 'stopped' }
        default { return 'unknown' }
    }
}

function Get-WorkforceWorkerIdentity {
    param([Parameter(Mandatory = $true)]$Worker)

    $name = @('name', 'displayName', 'title') | ForEach-Object {
        $property = $Worker.PSObject.Properties[$_]
        if ($property) { [string]$property.Value }
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
    $id = @('id', 'workerId') | ForEach-Object {
        $property = $Worker.PSObject.Properties[$_]
        if ($property) { [string]$property.Value }
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
    $sessionId = @('sessionId', 'session_id') | ForEach-Object {
        $property = $Worker.PSObject.Properties[$_]
        if ($property) { [string]$property.Value }
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
    return [pscustomobject]@{
        id = $id
        name = $name
        session_id = $sessionId
        state = ConvertTo-WorkforceWorkerState -State ([string]$Worker.state)
        raw = $Worker
    }
}

function Invoke-WorkforceReconcile {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$Namespace,
        [Parameter(Mandatory = $true)][string]$CwdFingerprint,
        [Parameter(Mandatory = $true)][string]$TaskFingerprint,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Workers,
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
    $ownedWorkers = @($Workers | ForEach-Object { Get-WorkforceWorkerIdentity -Worker $_ } | Where-Object { [string]$_.name -like "$Namespace-*" })
    $activeWorkers = @($ownedWorkers | Where-Object { [string]$_.state -in @('running', 'waiting', 'needs-input', 'unknown') })
    $manifests = @(Get-WorkforceManifests -StateRoot $StateRoot)
    $staleWorkersFound = 0
    $staleWorkersCleaned = 0
    foreach ($manifest in @($manifests | Where-Object { [string]$_.namespace -eq $Namespace -and [string]$_.status -in @('acquired', 'running', 'waiting', 'needs-input', 'finalizing', 'stale') })) {
        $workerMatch = @($ownedWorkers | Where-Object {
            (-not [string]::IsNullOrWhiteSpace([string]$manifest.worker_id) -and [string]$_.id -eq [string]$manifest.worker_id) -or
            (-not [string]::IsNullOrWhiteSpace([string]$manifest.session_id) -and [string]$_.session_id -eq [string]$manifest.session_id) -or
            (-not [string]::IsNullOrWhiteSpace([string]$manifest.worker_name) -and [string]$_.name -eq [string]$manifest.worker_name)
        }) | Select-Object -First 1
        if ($null -eq $workerMatch) {
            $staleWorkersFound++
            if ([string]$manifest.status -in @('running', 'waiting', 'needs-input')) {
                $manifest.status = 'stale'
                Save-WorkforceManifest -StateRoot $StateRoot -Manifest $manifest | Out-Null
            }
            $cleanup = Invoke-WorkforcePostflight -StateRoot $StateRoot -Manifest $manifest -Result $null -GracefulShutdownSeconds $GracefulShutdownSeconds -PortReleaseTimeoutSeconds $PortReleaseTimeoutSeconds -ForceOwnedResources:$ForceOwnedResources
            if ($cleanup.cleanup_status -eq 'complete') {
                $staleWorkersCleaned++
            }
            continue
        }
        if ([string]$workerMatch.state -in @('completed', 'failed', 'stopped')) {
            $manifest.status = 'finalizing'
            Save-WorkforceManifest -StateRoot $StateRoot -Manifest $manifest | Out-Null
            $terminalResult = [pscustomobject]@{
                subtype = "background-$($workerMatch.state)"
                is_error = [string]$workerMatch.state -ne 'completed'
                session_id = [string]$manifest.session_id
            }
            [void](Invoke-WorkforcePostflight -StateRoot $StateRoot -Manifest $manifest -Result $terminalResult -GracefulShutdownSeconds $GracefulShutdownSeconds -PortReleaseTimeoutSeconds $PortReleaseTimeoutSeconds -ForceOwnedResources:$ForceOwnedResources)
        }
        elseif ([string]$manifest.status -eq 'stale') {
            $manifest.status = if ([string]$workerMatch.state -in @('running', 'waiting', 'needs-input')) { [string]$workerMatch.state } else { 'running' }
            Save-WorkforceManifest -StateRoot $StateRoot -Manifest $manifest | Out-Null
        }
    }
    $manifests = @(Get-WorkforceManifests -StateRoot $StateRoot)
    $manifestWorkerIds = @($manifests | ForEach-Object { [string]$_.worker_id } | Where-Object { $_ } | Select-Object -Unique)
    $manifestSessionIds = @($manifests | ForEach-Object { [string]$_.session_id } | Where-Object { $_ } | Select-Object -Unique)
    $manifestWorkerNames = @($manifests | ForEach-Object { [string]$_.worker_name } | Where-Object { $_ } | Select-Object -Unique)
    $untrackedWorkers = @($ownedWorkers | Where-Object {
        [string]$_.id -notin $manifestWorkerIds -and [string]$_.session_id -notin $manifestSessionIds -and [string]$_.name -notin $manifestWorkerNames
    })
    $terminalManifestActiveWorkers = foreach ($terminalManifest in @($manifests | Where-Object { [string]$_.status -in @('completed', 'failed', 'cancelled', 'stopped') })) {
        $activeWorker = @($ownedWorkers | Where-Object {
            [string]$_.state -in @('running', 'waiting', 'needs-input', 'unknown') -and (
                (-not [string]::IsNullOrWhiteSpace([string]$terminalManifest.worker_id) -and [string]$_.id -eq [string]$terminalManifest.worker_id) -or
                (-not [string]::IsNullOrWhiteSpace([string]$terminalManifest.session_id) -and [string]$_.session_id -eq [string]$terminalManifest.session_id) -or
                (-not [string]::IsNullOrWhiteSpace([string]$terminalManifest.worker_name) -and [string]$_.name -eq [string]$terminalManifest.worker_name)
            )
        }) | Select-Object -First 1
        if ($null -ne $activeWorker) {
            [pscustomobject]@{ manifest_id = $terminalManifest.manifest_id; manifest_status = $terminalManifest.status; worker = $activeWorker; reason = 'terminal-manifest-active-worker' }
        }
    }
    $matching = @($manifests | Where-Object {
        [string]$_.namespace -eq $Namespace -and [string]$_.cwd_fingerprint -eq $CwdFingerprint -and [string]$_.task_fingerprint -eq $TaskFingerprint
    } | Sort-Object updated_at -Descending)
    $activeMatch = @($matching | Where-Object { [string]$_.status -in @('acquired', 'running', 'waiting', 'needs-input', 'finalizing') }) | Select-Object -First 1
    $successfulCompletedMatch = @($matching | Where-Object {
        [string]$_.status -eq 'completed' -and
        -not [bool]$_.result.is_error -and
        [string]$_.cleanup_status -eq 'complete' -and
        [int]$_.schema_version -eq 2
    }) | Select-Object -First 1
    $failedRecoverableMatch = @($matching | Where-Object {
        [string]$_.status -eq 'failed' -and -not [string]::IsNullOrWhiteSpace([string]$_.session_id)
    }) | Select-Object -First 1
    $failedTerminalMatch = @($matching | Where-Object {
        [string]$_.status -eq 'failed' -and [string]::IsNullOrWhiteSpace([string]$_.session_id)
    }) | Select-Object -First 1
    $previousCancelled = @($matching | Where-Object { [string]$_.status -eq 'cancelled' }) | Select-Object -First 1
    $cleanupBlocker = @($matching | Where-Object {
        [string]$_.status -eq 'cleanup-incomplete' -or [string]$_.cleanup_status -eq 'incomplete'
    }) | Select-Object -First 1
    $corruptMatch = @($matching | Where-Object { [string]$_.status -eq 'corrupt' }) | Select-Object -First 1

    $staleResourcesCleaned = 0
    $stalePortsReleased = 0
    foreach ($manifest in @($manifests | Where-Object {
        [string]$_.namespace -eq $Namespace -and [string]$_.status -in @('completed', 'failed', 'cancelled', 'cleanup-incomplete') -and [string]$_.cleanup_status -ne 'complete'
    } | Where-Object {
        Test-WorkforceCleanupRetryDue -Manifest $_
    })) {
        $cleanup = Invoke-WorkforceResourceCleanup -StateRoot $StateRoot -Manifest $manifest -GracefulShutdownSeconds $GracefulShutdownSeconds -PortReleaseTimeoutSeconds $PortReleaseTimeoutSeconds -ForceOwnedResources:$ForceOwnedResources
        $staleResourcesCleaned += $cleanup.temporary_processes_stopped
        $stalePortsReleased += $cleanup.temporary_ports_released
        $manifest.cleanup_status = $cleanup.cleanup_status
        $manifest.resources_left_running = @($cleanup.resources_left_running)
        Set-WorkforceObjectProperty -InputObject $manifest -Name cleanup_retry_after -Value $(if ($cleanup.cleanup_status -eq 'complete') { $null } else { (Get-WorkforceUtcNow).AddSeconds(60).ToString('o') })
        Save-WorkforceManifest -StateRoot $StateRoot -Manifest $manifest | Out-Null
    }

    $duplicate = $null -ne $activeMatch
    $completedAvailable = $null -ne $successfulCompletedMatch
    $dispatchAllowed = -not $duplicate -and -not $completedAvailable -and $null -eq $cleanupBlocker -and $null -eq $corruptMatch -and $currentLimit -gt $activeWorkers.Count
    $reason = if ($duplicate) { 'duplicate-task-active' } elseif ($completedAvailable) { 'completed-manifest-available' } elseif ($null -ne $cleanupBlocker) { 'cleanup-incomplete' } elseif ($null -ne $corruptMatch) { 'manifest-corrupt' } elseif ($circuit.state -eq 'open') { 'api-circuit-open' } elseif ($currentLimit -le $activeWorkers.Count) { 'worker-capacity-exhausted' } else { 'allowed' }
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
        completed_manifest = $successfulCompletedMatch
        successful_manifest = $successfulCompletedMatch
        recovery_manifest = $failedRecoverableMatch
        previous_failure = $(if ($null -ne $failedRecoverableMatch) { $failedRecoverableMatch } else { $failedTerminalMatch })
        previous_cancelled_manifest = $previousCancelled
        cleanup_blocker = $cleanupBlocker
        corrupt_manifest = $corruptMatch
        duplicate_task_found = $duplicate
        duplicate_task_prevented = $duplicate
        stale_workers_found = $staleWorkersFound
        stale_workers_cleaned = $staleWorkersCleaned
        untracked_workers = @($untrackedWorkers)
        terminal_manifest_active_workers = @($terminalManifestActiveWorkers)
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

    $workerReport = $null
    try {
        $workerReport = Read-WorkforceWorkerReport -StateRoot $StateRoot -ManifestId ([string]$Manifest.manifest_id)
    }
    catch {
        Set-WorkforceObjectProperty -InputObject $Manifest -Name worker_report_error -Value $_.Exception.Message
    }
    if ($null -eq $Result) {
        $Result = [pscustomobject]@{
            subtype = 'worker-absent-without-trusted-terminal-state'
            terminal_status = 'failed'
            is_error = $true
            session_id = [string]$Manifest.session_id
        }
    }
    if ([string]$Manifest.status -in @('completed', 'failed', 'cancelled', 'stopped') -and [string]$Manifest.cleanup_status -eq 'complete') {
        return [pscustomobject]@{
            postflight_completed = $true
            resources_stopped = @($Manifest.resources_stopped)
            resources_left_running = @($Manifest.resources_left_running)
            ports_released = @($Manifest.ports_released)
            temporary_processes_stopped = @($Manifest.resources_stopped).Count
            temporary_ports_released = @($Manifest.ports_released).Count
            owned_processes_remaining = 0
            owned_ports_remaining = 0
            cleanup_status = 'complete'
            idempotent_replay = $true
        }
    }
    if ([string]$Manifest.status -in @('acquired', 'running', 'waiting', 'needs-input', 'stale')) {
        $Manifest.status = 'finalizing'
        Save-WorkforceManifest -StateRoot $StateRoot -Manifest $Manifest | Out-Null
    }
    elseif ([string]$Manifest.status -notin @('finalizing', 'cleanup-incomplete', 'completed', 'failed', 'cancelled', 'stopped')) {
        throw "postflight-invalid-manifest-state: $($Manifest.status)"
    }
    $cleanup = Invoke-WorkforceResourceCleanup -StateRoot $StateRoot -Manifest $Manifest -GracefulShutdownSeconds $GracefulShutdownSeconds -PortReleaseTimeoutSeconds $PortReleaseTimeoutSeconds -ForceOwnedResources:$ForceOwnedResources
    $terminalStatus = if ([string]$Result.terminal_status -in @('completed', 'failed', 'cancelled')) { [string]$Result.terminal_status } elseif ([bool]$Result.is_error) { 'failed' } else { 'completed' }
    $Manifest.status = if ($cleanup.cleanup_status -eq 'complete') { $terminalStatus } else { 'cleanup-incomplete' }
    $Manifest.completed_at = (Get-WorkforceUtcNow).ToString('o')
    $Manifest.result = $Result
    $workerReportAudit = if ($null -ne $workerReport) {
        [pscustomobject]@{
            manifest_id = [string]$workerReport.manifest_id
            reported_status = [string]$workerReport.reported_status
            updated_at = [string]$workerReport.updated_at
            result_summary = $workerReport.result_summary
            trusted_for_resources = $false
        }
    }
    else {
        $null
    }
    Set-WorkforceObjectProperty -InputObject $Manifest -Name worker_report -Value $workerReportAudit
    $Manifest.resources_stopped = @($cleanup.resources_stopped)
    $Manifest.resources_left_running = @($cleanup.resources_left_running)
    $Manifest.ports_released = @($cleanup.ports_released)
    $Manifest.cleanup_status = $cleanup.cleanup_status
    Set-WorkforceObjectProperty -InputObject $Manifest -Name cleanup_retry_after -Value $(if ($cleanup.cleanup_status -eq 'complete') { $null } else { (Get-WorkforceUtcNow).AddSeconds(60).ToString('o') })
    Save-WorkforceManifest -StateRoot $StateRoot -Manifest $Manifest | Out-Null
    $paths = Get-WorkforceStatePaths -StateRoot $StateRoot
    Invoke-WorkforceStateTransaction -StateRoot $StateRoot -LockName "result-$($Manifest.manifest_id)" -ScriptBlock {
        Write-WorkforceState -Path (Join-Path $paths.results "$($Manifest.manifest_id).json") -Value $Manifest
    } | Out-Null
    return $cleanup
}

function Get-WorkforceResourceSummary {
    param([Parameter(Mandatory = $true)][string]$StateRoot)

    $manifests = @(Get-WorkforceManifests -StateRoot $StateRoot)
    $leases = @(Get-WorkforcePortLeases -StateRoot $StateRoot)
    $resources = @(Get-WorkforceOwnedResources -StateRoot $StateRoot)
    return [pscustomobject]@{
        manifests = $manifests
        resources = $resources
        port_leases = $leases
        cleanup_incomplete = @($manifests | Where-Object { [string]$_.cleanup_status -eq 'incomplete' }).Count
    }
}
