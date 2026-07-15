[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$scriptsRoot = Join-Path $PSScriptRoot '..\claude-workforce\scripts'
$stateScript = Join-Path $scriptsRoot 'workforce-state.ps1'
$lifecycleScript = Join-Path $scriptsRoot 'workforce-lifecycle.ps1'
$reaperScript = Join-Path $scriptsRoot 'workforce-reaper.ps1'
$timeoutScript = Join-Path $scriptsRoot 'workforce-timeouts.ps1'
$profileScript = Join-Path $scriptsRoot 'new-workforce-session-profile.ps1'
$stateWorker = Join-Path $PSScriptRoot 'helpers\Invoke-StateWorker.ps1'
$timeoutFixture = Join-Path $PSScriptRoot 'helpers\Invoke-TimeoutFixture.ps1'
. $lifecycleScript
. $reaperScript
. $timeoutScript

if ($null -eq ('ClaudeWorkforceTests.AbandonedMutexFactory' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Threading;

namespace ClaudeWorkforceTests
{
    public static class AbandonedMutexFactory
    {
        public static Mutex Create(string name)
        {
            var mutex = new Mutex(false, name);
            var thread = new Thread(() => mutex.WaitOne());
            thread.Start();
            thread.Join();
            return mutex;
        }
    }
}
'@
}

function Start-RemediationProcess {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = (Get-Command pwsh -CommandType Application -ErrorAction Stop).Source
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw 'Unable to start remediation fixture process.'
    }
    return $process
}

function Wait-RemediationProcess {
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process]$Process,
        [int]$TimeoutSeconds = 30
    )

    if (-not $Process.WaitForExit($TimeoutSeconds * 1000)) {
        $Process.Kill($true)
        throw 'Remediation fixture process timed out.'
    }
    $stdout = $Process.StandardOutput.ReadToEnd()
    $stderr = $Process.StandardError.ReadToEnd()
    $exitCode = $Process.ExitCode
    $Process.Dispose()
    if ($exitCode -ne 0) {
        throw "Remediation fixture failed with exit code $exitCode. stdout=$stdout stderr=$stderr"
    }
}

function New-TimeoutStartInfo {
    param(
        [Parameter(Mandatory = $true)][string]$Mode,
        [string]$MarkerPath
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = (Get-Command pwsh -CommandType Application -ErrorAction Stop).Source
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @('-NoProfile', '-File', $timeoutFixture, '-Mode', $Mode)) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    if (-not [string]::IsNullOrWhiteSpace($MarkerPath)) {
        [void]$startInfo.ArgumentList.Add('-MarkerPath')
        [void]$startInfo.ArgumentList.Add($MarkerPath)
    }
    return $startInfo
}

$result = [ordered]@{
    concurrent_8_processes = $false
    abandoned_mutex_recovered = $false
    manifest_authority = $false
    cas_conflict = $false
    illegal_transition = $false
    backup_restore = $false
    migration_roundtrip = $false
    migration_full_rollback = $false
    migration_broker_key_acl = $false
    broker_token_hmac = $false
    broker_critical_fields_hmac = $false
    non_descendant_rejected = $false
    listener_pid_bound = $false
    listener_pid_mismatch_rejected = $false
    key_acl_fail_closed = $false
    cross_manifest_unregister_rejected = $false
    mcp_cleanup_closed = $false
    mcp_cleanup_order_independent = $false
    worker_report_untrusted = $false
    worker_report_success_rejected = $false
    reaper_idempotent = $false
    startup_timeout = $false
    idle_timeout = $false
    hard_timeout = $false
    partial_output_preserved = $false
    no_duplicate_side_effects = $false
    trust_profiles = $false
    hooks_default_off = $false
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "claude-workforce-remediation-$([guid]::NewGuid().ToString('N'))"
$childProcesses = [Collections.Generic.List[Diagnostics.Process]]::new()
$listener = $null
try {
    [void](New-Item -ItemType Directory -Path $testRoot -Force)

    $stateRoot = Join-Path $testRoot 'state'
    $workers = foreach ($workerId in 1..8) {
        Start-RemediationProcess -Arguments @('-NoProfile', '-File', $stateWorker, '-StateScript', $stateScript, '-StateRoot', $stateRoot, '-Mode', 'update', '-WorkerId', "worker-$workerId")
    }
    foreach ($worker in $workers) {
        Wait-RemediationProcess -Process $worker
    }
    $concurrent = Read-WorkforceState -Path (Join-Path $stateRoot 'concurrent.json') -DefaultValue $null -RestoreFromBackup
    if ([int]$concurrent.count -ne 8 -or @($concurrent.workers | Select-Object -Unique).Count -ne 8) {
        throw 'Eight-process state transaction lost an update.'
    }
    $result.concurrent_8_processes = $true

    $rootHash = (Get-WorkforceStateHash -Text ([IO.Path]::GetFullPath($stateRoot))).Substring(0, 24)
    $lockHash = (Get-WorkforceStateHash -Text 'abandoned-test').Substring(0, 16)
    $abandonedHandle = [ClaudeWorkforceTests.AbandonedMutexFactory]::Create("Local\ClaudeWorkforce-$rootHash-$lockHash")
    $recoveredLock = Enter-WorkforceStateLock -StateRoot $stateRoot -LockName 'abandoned-test' -TimeoutSeconds 5
    try {
        if (-not $recoveredLock.recovered) {
            throw 'Abandoned mutex was not reported as recovered.'
        }
        $result.abandoned_mutex_recovered = $true
    }
    finally {
        Exit-WorkforceStateLock -Lock $recoveredLock
        $abandonedHandle.Dispose()
    }

    $manifest = New-WorkforceManifest -Namespace 'test' -CwdFingerprint 'cwd' -Role 'worker' -TaskFingerprint 'task' -WorkerId 'worker-a' -WorkerName 'worker-a' -SessionId '11111111-1111-4111-8111-111111111111'
    Save-WorkforceManifest -StateRoot $stateRoot -Manifest $manifest | Out-Null
    $indexCopy = $manifest | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $indexCopy.status = 'failed'
    Write-WorkforceState -Path (Join-Path $stateRoot 'resource-index.json') -Value @($indexCopy)
    $authoritative = @(Get-WorkforceManifests -StateRoot $stateRoot | Where-Object { $_.manifest_id -eq $manifest.manifest_id }) | Select-Object -First 1
    if ([string]$authoritative.status -ne 'acquired') {
        throw 'resource-index.json overrode the authoritative Manifest file.'
    }
    $result.manifest_authority = $true

    $first = $authoritative | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $second = $authoritative | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $first.status = 'running'
    Save-WorkforceManifest -StateRoot $stateRoot -Manifest $first -ExpectedRevision ([int]$authoritative.revision) | Out-Null
    $second.status = 'failed'
    try {
        Save-WorkforceManifest -StateRoot $stateRoot -Manifest $second -ExpectedRevision ([int]$authoritative.revision) | Out-Null
        throw 'A stale compare-and-swap write unexpectedly succeeded.'
    }
    catch {
        if ($_.Exception.Message -notmatch 'manifest-revision-conflict') { throw }
    }
    $result.cas_conflict = $true

    $current = @(Get-WorkforceManifests -StateRoot $stateRoot | Where-Object { $_.manifest_id -eq $manifest.manifest_id }) | Select-Object -First 1
    $illegal = $current | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $illegal.status = 'completed'
    try {
        Save-WorkforceManifest -StateRoot $stateRoot -Manifest $illegal -ExpectedRevision ([int]$current.revision) | Out-Null
        throw 'An illegal running-to-completed transition unexpectedly succeeded.'
    }
    catch {
        if ($_.Exception.Message -notmatch 'invalid-manifest-transition') { throw }
    }
    $result.illegal_transition = $true

    $backupPath = Join-Path $stateRoot 'backup-probe.json'
    Write-WorkforceState -Path $backupPath -Value ([pscustomobject]@{ value = 1 })
    Write-WorkforceState -Path $backupPath -Value ([pscustomobject]@{ value = 2 })
    [IO.File]::WriteAllText($backupPath, '{broken', [Text.UTF8Encoding]::new($false))
    $restored = Read-WorkforceState -Path $backupPath -DefaultValue $null -RestoreFromBackup
    if ([int]$restored.value -ne 1) {
        throw 'State backup restore did not recover the previous generation.'
    }
    $result.backup_restore = $true

    $legacyRoot = Join-Path $testRoot 'legacy'
    [void](New-Item -ItemType Directory -Path $legacyRoot -Force)
    $legacyManifest = [pscustomobject]@{
        manifest_id = 'legacy-manifest'
        revision = 3
        status = 'running'
        updated_at = [DateTimeOffset]::UtcNow.ToString('o')
        resources = @([pscustomobject]@{ type = 'process'; pid = 123; ownership_fingerprint = 'legacy' })
    }
    Write-WorkforceState -Path (Join-Path $legacyRoot 'resource-index.json') -Value @($legacyManifest)
    Write-WorkforceState -Path (Join-Path $legacyRoot 'metrics.json') -Value ([pscustomobject]@{ schema_version = 2; rollback_marker = 7 })
    $legacyKeyInfo = Get-WorkforceBrokerKeyInfo -StateRoot $legacyRoot -Create
    if (-not $legacyKeyInfo.present) {
        throw 'Legacy broker key fixture was not created.'
    }
    $originalProtectBrokerKey = ${function:Protect-WorkforceBrokerKey}
    $originalTestBrokerKeyAcl = ${function:Test-WorkforceBrokerKeyAcl}
    $script:RemediationProtectedKeyPaths = [Collections.Generic.List[string]]::new()
    try {
        ${function:Protect-WorkforceBrokerKey} = {
            param([Parameter(Mandatory = $true)][string]$Path)
            [void]$script:RemediationProtectedKeyPaths.Add([IO.Path]::GetFullPath($Path))
            return $true
        }
        ${function:Test-WorkforceBrokerKeyAcl} = {
            param([Parameter(Mandatory = $true)][string]$Path)
            return Test-Path -LiteralPath $Path -PathType Leaf
        }
        $migration = Invoke-WorkforceStateMigration -StateRoot $legacyRoot
        $migratedManifest = @(Get-WorkforceManifests -StateRoot $legacyRoot) | Select-Object -First 1
        if (-not $migration.migrated -or [int]$migratedManifest.schema_version -ne 2 -or [string]$migratedManifest.resources[0].ownership_method -ne 'legacy-unverified' -or (Test-Path -LiteralPath (Join-Path $legacyRoot 'resource-index.json'))) {
            throw 'State migration did not produce a schema-v2 legacy-unverified Manifest.'
        }
        $backupBrokerKey = Join-Path ([string]$migration.backup_path) 'state-root\broker.key'
        if (-not (Test-WorkforceBrokerKeyAcl -Path $backupBrokerKey) -or [IO.Path]::GetFullPath($backupBrokerKey) -notin @($script:RemediationProtectedKeyPaths)) {
            throw 'State migration did not explicitly protect and verify the broker key backup.'
        }
        Write-WorkforceState -Path (Join-Path $legacyRoot 'metrics.json') -Value ([pscustomobject]@{ schema_version = 2; rollback_marker = 99 })
        $rollback = Restore-WorkforceStateMigration -StateRoot $legacyRoot -BackupPath ([string]$migration.backup_path)
        $activeBrokerKey = Join-Path $legacyRoot 'broker.key'
        if (-not (Test-WorkforceBrokerKeyAcl -Path $activeBrokerKey) -or [IO.Path]::GetFullPath($activeBrokerKey) -notin @($script:RemediationProtectedKeyPaths)) {
            throw 'State migration rollback did not explicitly protect and verify the active broker key.'
        }
    }
    finally {
        ${function:Protect-WorkforceBrokerKey} = $originalProtectBrokerKey
        ${function:Test-WorkforceBrokerKeyAcl} = $originalTestBrokerKeyAcl
        Remove-Variable -Scope Script -Name RemediationProtectedKeyPaths -ErrorAction SilentlyContinue
    }
    $rolledBackVersion = Read-WorkforceState -Path (Join-Path $legacyRoot 'state-version.json') -DefaultValue $null -RestoreFromBackup
    $rolledBackMetrics = Read-WorkforceState -Path (Join-Path $legacyRoot 'metrics.json') -DefaultValue $null -RestoreFromBackup
    if (-not $rollback.rolled_back -or -not $rollback.full_snapshot_restored -or -not (Test-Path -LiteralPath (Join-Path $legacyRoot 'resource-index.json')) -or [int]$rolledBackVersion.schema_version -ne 1 -or [int]$rolledBackMetrics.rollback_marker -ne 7) {
        throw 'State migration rollback did not restore the v1 index and version marker.'
    }
    $result.migration_roundtrip = $true
    $result.migration_full_rollback = $true
    $result.migration_broker_key_acl = $true

    $brokerRoot = Join-Path $testRoot 'broker'
    $brokerManifest = New-WorkforceManifest -Namespace 'broker' -CwdFingerprint 'cwd' -Role 'worker' -TaskFingerprint 'broker-task' -WorkerId 'broker-worker' -WorkerName 'broker-worker' -SessionId '22222222-2222-4222-8222-222222222222'
    Save-WorkforceManifest -StateRoot $brokerRoot -Manifest $brokerManifest | Out-Null
    $brokerManifest.status = 'running'
    Save-WorkforceManifest -StateRoot $brokerRoot -Manifest $brokerManifest | Out-Null
    $capability = New-WorkforceResourceCapability -StateRoot $brokerRoot -ManifestId $brokerManifest.manifest_id -WorkerId $brokerManifest.worker_id -SessionId $brokerManifest.session_id
    $validCapability = Test-WorkforceResourceCapability -StateRoot $brokerRoot -Token $capability.token -ManifestId $brokerManifest.manifest_id -WorkerId $brokerManifest.worker_id -SessionId $brokerManifest.session_id
    $invalidCapability = Test-WorkforceResourceCapability -StateRoot $brokerRoot -Token ('0' * 64) -ManifestId $brokerManifest.manifest_id -WorkerId $brokerManifest.worker_id -SessionId $brokerManifest.session_id
    if (-not $validCapability.verified -or $invalidCapability.verified -or $capability.token.Length -ne 64) {
        throw 'Broker capability token validation failed.'
    }

    $keyInfo = Get-WorkforceBrokerKeyInfo -StateRoot $brokerRoot -Create
    $currentProcess = Get-Process -Id $PID
    $currentPath = [string]$currentProcess.Path
    $resource = [pscustomobject][ordered]@{
        schema_version = 2
        resource_id = 'current-process'
        type = 'process'
        manifest_id = $brokerManifest.manifest_id
        worker_id = $brokerManifest.worker_id
        session_id = $brokerManifest.session_id
        pid = $PID
        process_start_time = $currentProcess.StartTime.ToUniversalTime().ToString('o')
        executable_path_hash = (Get-FileHash -LiteralPath $currentPath -Algorithm SHA256).Hash.ToLowerInvariant()
        ownership_method = 'registered-token-descendant'
        broker_signature = $null
        persistent = $true
        expires_at = [DateTimeOffset]::UtcNow.AddMinutes(5).ToString('o')
        stop_strategy = [pscustomobject]@{ type = 'process-handle'; grace_seconds = 0 }
    }
    $resource.broker_signature = Get-WorkforceBrokerSignature -Key $keyInfo.key -Resource $resource
    $resourcePath = Join-Path (Get-WorkforceStatePaths -StateRoot $brokerRoot).broker_resources 'current-process.json'
    Write-WorkforceState -Path $resourcePath -Value $resource
    $ownership = Test-WorkforceResourceOwnership -StateRoot $brokerRoot -Resource $resource -ExpectedManifestId $brokerManifest.manifest_id -ExpectedWorkerId $brokerManifest.worker_id -ExpectedSessionId $brokerManifest.session_id
    $tampered = $resource | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $tampered.session_id = '33333333-3333-4333-8333-333333333333'
    $tamperedOwnership = Test-WorkforceResourceOwnership -StateRoot $brokerRoot -Resource $tampered -ExpectedManifestId $brokerManifest.manifest_id
    $shortSignature = $resource | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $shortSignature.broker_signature = 'abcd'
    $shortOwnership = Test-WorkforceResourceOwnership -StateRoot $brokerRoot -Resource $shortSignature -ExpectedManifestId $brokerManifest.manifest_id
    $tamperedType = $resource | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $tamperedType.type = 'mcp'
    $tamperedPersistent = $resource | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $tamperedPersistent.persistent = $false
    $tamperedStop = $resource | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $tamperedStop.stop_strategy.type = 'kill-tree'
    if (-not $ownership.verified -or $tamperedOwnership.verified -or $shortOwnership.verified -or
        (Test-WorkforceResourceOwnership -StateRoot $brokerRoot -Resource $tamperedType -ExpectedManifestId $brokerManifest.manifest_id).verified -or
        (Test-WorkforceResourceOwnership -StateRoot $brokerRoot -Resource $tamperedPersistent -ExpectedManifestId $brokerManifest.manifest_id).verified -or
        (Test-WorkforceResourceOwnership -StateRoot $brokerRoot -Resource $tamperedStop -ExpectedManifestId $brokerManifest.manifest_id).verified -or
        $null -eq (Get-Process -Id $PID -ErrorAction SilentlyContinue)) {
        throw 'Broker HMAC verification did not fail closed.'
    }
    $result.broker_token_hmac = $true
    $result.broker_critical_fields_hmac = $true

    $outsider = Start-RemediationProcess -Arguments @('-NoProfile', '-File', $timeoutFixture, '-Mode', 'hold')
    [void]$childProcesses.Add($outsider)
    $originalParentFunction = ${function:Get-WorkforceParentProcessId}
    try {
        ${function:Get-WorkforceParentProcessId} = {
            param([int]$ProcessId)
            if ($ProcessId -eq $PID) { return 500001 }
            return 0
        }
        $nonDescendantRejected = $false
        try {
            Register-WorkforceProcess -StateRoot $brokerRoot -ManifestId $brokerManifest.manifest_id -WorkerId $brokerManifest.worker_id -SessionId $brokerManifest.session_id -CapabilityToken $capability.token -ProcessId $outsider.Id | Out-Null
        }
        catch {
            $nonDescendantRejected = $_.Exception.Message -match 'non-descendant-process'
        }
        if (-not $nonDescendantRejected) {
            throw 'Broker accepted a process outside the tested descendant chain.'
        }
        $result.non_descendant_rejected = $true
    }
    finally {
        ${function:Get-WorkforceParentProcessId} = $originalParentFunction
    }

    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $listenerPort = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    $ownerQuery = Get-WorkforcePortOwnerProcessIds -Port $listenerPort -Protocol tcp
    if (-not $ownerQuery.verified -or $PID -notin @($ownerQuery.process_ids)) {
        throw "Listener PID query failed closed unexpectedly: $($ownerQuery.reason)"
    }
    $lease = Register-WorkforcePort -StateRoot $brokerRoot -ManifestId $brokerManifest.manifest_id -WorkerId $brokerManifest.worker_id -SessionId $brokerManifest.session_id -CapabilityToken $capability.token -ResourceId $resource.resource_id -Port $listenerPort
    if ([string]$lease.state -ne 'bound' -or -not (Test-WorkforcePortLeaseSignature -StateRoot $brokerRoot -Lease $lease).verified -or [int]$lease.pid -ne $PID) {
        throw 'Broker did not bind the lease to the verified listener PID.'
    }
    $result.listener_pid_bound = $true

    $child = Start-RemediationProcess -Arguments @('-NoProfile', '-File', $timeoutFixture, '-Mode', 'hold')
    [void]$childProcesses.Add($child)
    $childResource = $resource | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $childResource.resource_id = 'child-process'
    $childResource.pid = $child.Id
    $childResource.process_start_time = $child.StartTime.ToUniversalTime().ToString('o')
    $childResource.executable_path_hash = (Get-FileHash -LiteralPath ([string]$child.Path) -Algorithm SHA256).Hash.ToLowerInvariant()
    $childResource.broker_signature = Get-WorkforceBrokerSignature -Key $keyInfo.key -Resource $childResource
    Write-WorkforceState -Path (Join-Path (Get-WorkforceStatePaths -StateRoot $brokerRoot).broker_resources 'child-process.json') -Value $childResource
    $originalKeyFunction = ${function:Get-WorkforceBrokerKeyInfo}
    $script:RemediationBrokerKey = $keyInfo.key
    try {
        ${function:Get-WorkforceBrokerKeyInfo} = {
            param([string]$StateRoot, [switch]$Create)
            return [pscustomobject]@{ present = $true; key = $script:RemediationBrokerKey; acl_verified = $false }
        }
        $aclStop = Stop-WorkforceOwnedResource -StateRoot $brokerRoot -Resource $childResource -ExpectedManifestId $brokerManifest.manifest_id -ExpectedWorkerId $brokerManifest.worker_id -ExpectedSessionId $brokerManifest.session_id
        if ($aclStop.verified_stopped -or $aclStop.cleanup_error -ne 'broker-key-acl-unverified' -or $child.HasExited) {
            throw 'Resource cleanup did not fail closed when the broker key ACL was unverified.'
        }
        $result.key_acl_fail_closed = $true
    }
    finally {
        ${function:Get-WorkforceBrokerKeyInfo} = $originalKeyFunction
        Remove-Variable -Scope Script -Name RemediationBrokerKey -ErrorAction SilentlyContinue
    }
    $mismatchRejected = $false
    try {
        Register-WorkforcePort -StateRoot $brokerRoot -ManifestId $brokerManifest.manifest_id -WorkerId $brokerManifest.worker_id -SessionId $brokerManifest.session_id -CapabilityToken $capability.token -ResourceId $childResource.resource_id -Port $listenerPort | Out-Null
    }
    catch {
        $mismatchRejected = $_.Exception.Message -match 'listener-pid-mismatch'
    }
    if (-not $mismatchRejected) {
        throw 'Broker accepted a lease whose listener PID did not match the signed process.'
    }
    $result.listener_pid_mismatch_rejected = $true

    $listener.Stop()
    $listener = $null
    if (-not (Remove-WorkforcePortLease -StateRoot $brokerRoot -LeaseId $lease.lease_id -RequireReleasedPort)) {
        throw 'Verified port lease could not be released after listener shutdown.'
    }
    $releasedLease = @(Get-WorkforcePortLeases -StateRoot $brokerRoot | Where-Object { $_.lease_id -eq $lease.lease_id }) | Select-Object -First 1
    if ([string]$releasedLease.state -ne 'released' -or -not (Test-WorkforcePortLeaseSignature -StateRoot $brokerRoot -Lease $releasedLease).verified) {
        throw 'Released port lease did not retain a valid terminal record.'
    }

    $foreignManifest = New-WorkforceManifest -Namespace 'foreign' -CwdFingerprint 'cwd' -Role 'worker' -TaskFingerprint 'foreign-task' -WorkerId 'foreign-worker' -WorkerName 'foreign-worker' -SessionId '55555555-5555-4555-8555-555555555555'
    Save-WorkforceManifest -StateRoot $brokerRoot -Manifest $foreignManifest | Out-Null
    $foreignCapability = New-WorkforceResourceCapability -StateRoot $brokerRoot -ManifestId $foreignManifest.manifest_id -WorkerId $foreignManifest.worker_id -SessionId $foreignManifest.session_id
    $crossManifestRejected = $false
    try {
        Unregister-WorkforceResource -StateRoot $brokerRoot -ResourceId $resource.resource_id -ManifestId $foreignManifest.manifest_id -CapabilityToken $foreignCapability.token | Out-Null
    }
    catch {
        $crossManifestRejected = $_.Exception.Message -match 'manifest-mismatch'
    }
    if (-not $crossManifestRejected -or -not (Test-Path -LiteralPath $resourcePath -PathType Leaf)) {
        throw 'A foreign Manifest capability unregistered another Manifest resource.'
    }
    $result.cross_manifest_unregister_rejected = $true

    $mcpManifest = New-WorkforceManifest -Namespace 'mcp' -CwdFingerprint 'cwd' -Role 'worker' -TaskFingerprint 'mcp-task' -WorkerId 'mcp-worker' -WorkerName 'mcp-worker' -SessionId '66666666-6666-4666-8666-666666666666'
    Save-WorkforceManifest -StateRoot $brokerRoot -Manifest $mcpManifest | Out-Null
    $mcpManifest.status = 'running'
    Save-WorkforceManifest -StateRoot $brokerRoot -Manifest $mcpManifest | Out-Null
    $mcpCapability = New-WorkforceResourceCapability -StateRoot $brokerRoot -ManifestId $mcpManifest.manifest_id -WorkerId $mcpManifest.worker_id -SessionId $mcpManifest.session_id
    $mcpChild = Start-RemediationProcess -Arguments @('-NoProfile', '-File', $timeoutFixture, '-Mode', 'hold')
    [void]$childProcesses.Add($mcpChild)
    $mcpProcess = Register-WorkforceProcess -StateRoot $brokerRoot -ManifestId $mcpManifest.manifest_id -WorkerId $mcpManifest.worker_id -SessionId $mcpManifest.session_id -CapabilityToken $mcpCapability.token -ProcessId $mcpChild.Id
    $missingMcpProcessRejected = $false
    try {
        Register-WorkforceMcpEndpoint -StateRoot $brokerRoot -ManifestId $mcpManifest.manifest_id -WorkerId $mcpManifest.worker_id -SessionId $mcpManifest.session_id -CapabilityToken $mcpCapability.token -Transport stdio -ProcessResourceId missing | Out-Null
    }
    catch {
        $missingMcpProcessRejected = $_.Exception.Message -match 'process-resource-not-found'
    }
    $mcpEndpoint = Register-WorkforceMcpEndpoint -StateRoot $brokerRoot -ManifestId $mcpManifest.manifest_id -WorkerId $mcpManifest.worker_id -SessionId $mcpManifest.session_id -CapabilityToken $mcpCapability.token -Transport stdio -ProcessResourceId $mcpProcess.resource_id
    $tamperedMcp = $mcpEndpoint | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $tamperedMcp.transport = 'http'
    $tamperedMcpTrust = Test-WorkforceResourceOwnership -StateRoot $brokerRoot -Resource $tamperedMcp -ExpectedManifestId $mcpManifest.manifest_id
    $originalOwnedResources = ${function:Get-WorkforceOwnedResources}
    $originalMcpKeyInfo = ${function:Get-WorkforceBrokerKeyInfo}
    $script:RemediationMcpKeyInfo = Get-WorkforceBrokerKeyInfo -StateRoot $brokerRoot
    $script:RemediationOwnedResources = $originalOwnedResources
    $script:RemediationMcpManifestId = [string]$mcpManifest.manifest_id
    $script:RemediationMcpEndpoint = $mcpEndpoint
    $script:RemediationMcpProcess = $mcpProcess
    try {
        ${function:Get-WorkforceOwnedResources} = {
            param(
                [Parameter(Mandatory = $true)][string]$StateRoot,
                [string]$ManifestId
            )
            if ([string]$ManifestId -eq $script:RemediationMcpManifestId) {
                return @($script:RemediationMcpEndpoint, $script:RemediationMcpProcess)
            }
            return & $script:RemediationOwnedResources -StateRoot $StateRoot -ManifestId $ManifestId
        }
        ${function:Get-WorkforceBrokerKeyInfo} = {
            param(
                [Parameter(Mandatory = $true)][string]$StateRoot,
                [switch]$Create
            )
            return [pscustomobject]@{
                present = $true
                key = $script:RemediationMcpKeyInfo.key
                acl_verified = $true
            }
        }
        $mcpCleanup = Invoke-WorkforcePostflight -StateRoot $brokerRoot -Manifest $mcpManifest -Result ([pscustomobject]@{ subtype = 'trusted-test-failure'; terminal_status = 'failed'; is_error = $true; session_id = $mcpManifest.session_id }) -GracefulShutdownSeconds 0 -PortReleaseTimeoutSeconds 0 -ForceOwnedResources
    }
    finally {
        ${function:Get-WorkforceOwnedResources} = $originalOwnedResources
        ${function:Get-WorkforceBrokerKeyInfo} = $originalMcpKeyInfo
        Remove-Variable -Scope Script -Name RemediationOwnedResources -ErrorAction SilentlyContinue
        Remove-Variable -Scope Script -Name RemediationMcpKeyInfo -ErrorAction SilentlyContinue
        Remove-Variable -Scope Script -Name RemediationMcpManifestId -ErrorAction SilentlyContinue
        Remove-Variable -Scope Script -Name RemediationMcpEndpoint -ErrorAction SilentlyContinue
        Remove-Variable -Scope Script -Name RemediationMcpProcess -ErrorAction SilentlyContinue
    }
    [void]$mcpChild.WaitForExit(5000)
    $mcpResourcesRemaining = @(Get-WorkforceOwnedResources -StateRoot $brokerRoot -ManifestId $mcpManifest.manifest_id).Count
    if (-not $missingMcpProcessRejected -or $tamperedMcpTrust.verified -or $mcpCleanup.cleanup_status -ne 'complete' -or $mcpResourcesRemaining -ne 0) {
        throw "MCP endpoint registration or cleanup did not fail closed around its process resource: missing_rejected=$missingMcpProcessRejected tamper_verified=$($tamperedMcpTrust.verified) cleanup=$($mcpCleanup.cleanup_status) remaining=$mcpResourcesRemaining"
    }
    $result.mcp_cleanup_closed = $true
    $result.mcp_cleanup_order_independent = $true

    $reportManifest = New-WorkforceManifest -Namespace 'report' -CwdFingerprint 'cwd' -Role 'worker' -TaskFingerprint 'report-task' -WorkerId 'report-worker' -WorkerName 'report-worker' -SessionId '44444444-4444-4444-8444-444444444444'
    Save-WorkforceManifest -StateRoot $brokerRoot -Manifest $reportManifest | Out-Null
    $reportManifest.status = 'running'
    Save-WorkforceManifest -StateRoot $brokerRoot -Manifest $reportManifest | Out-Null
    $reportPath = Join-Path (Get-WorkforceStatePaths -StateRoot $brokerRoot).worker_reports "$($reportManifest.manifest_id).json"
    Write-WorkforceState -Path $reportPath -Value ([pscustomobject]@{
        manifest_id = $reportManifest.manifest_id
        reported_status = 'completed'
        resources_requested = @([pscustomobject]@{ pid = $PID; trusted = $true })
        result_summary = [pscustomobject]@{ message = 'done' }
        updated_at = [DateTimeOffset]::UtcNow.ToString('o')
    })
    [void](Invoke-WorkforcePostflight -StateRoot $brokerRoot -Manifest $reportManifest -Result $null -GracefulShutdownSeconds 0 -PortReleaseTimeoutSeconds 0)
    $reported = @(Get-WorkforceManifests -StateRoot $brokerRoot | Where-Object { $_.manifest_id -eq $reportManifest.manifest_id }) | Select-Object -First 1
    if ([string]$reported.status -ne 'failed' -or [string]$reported.result.subtype -ne 'worker-absent-without-trusted-terminal-state' -or $null -ne $reported.worker_report.PSObject.Properties['resources_requested'] -or [bool]$reported.worker_report.trusted_for_resources -or @(Get-WorkforceOwnedResources -StateRoot $brokerRoot -ManifestId $reportManifest.manifest_id).Count -ne 0) {
        throw 'Untrusted worker report changed trusted resource ownership.'
    }
    $result.worker_report_untrusted = $true
    $result.worker_report_success_rejected = $true

    $staleManifest = New-WorkforceManifest -Namespace 'reaper' -CwdFingerprint 'cwd' -Role 'worker' -TaskFingerprint 'reaper-task' -WorkerId 'missing-worker' -WorkerName 'reaper-missing-worker' -SessionId '77777777-7777-4777-8777-777777777777'
    $staleManifest.status = 'stale'
    $staleManifest.revision = 1
    Write-WorkforceState -Path (Join-Path (Get-WorkforceStatePaths -StateRoot $brokerRoot).manifests "$($staleManifest.manifest_id).json") -Value $staleManifest
    $firstReap = Invoke-WorkforceReaper -StateRoot $brokerRoot -Workers @() -GracefulShutdownSeconds 0 -PortReleaseTimeoutSeconds 0
    $afterFirstReap = @(Get-WorkforceManifests -StateRoot $brokerRoot | Where-Object { $_.manifest_id -eq $staleManifest.manifest_id }) | Select-Object -First 1
    $firstRevision = [int]$afterFirstReap.revision
    $secondReap = Invoke-WorkforceReaper -StateRoot $brokerRoot -Workers @() -GracefulShutdownSeconds 0 -PortReleaseTimeoutSeconds 0
    $afterSecondReap = @(Get-WorkforceManifests -StateRoot $brokerRoot | Where-Object { $_.manifest_id -eq $staleManifest.manifest_id }) | Select-Object -First 1
    if ($firstReap.idempotent -or -not $secondReap.idempotent -or [string]$afterFirstReap.status -ne 'failed' -or [int]$afterSecondReap.revision -ne $firstRevision) {
        throw 'Reaper did not clean a stale Manifest exactly once.'
    }
    $result.reaper_idempotent = $true

    $startup = Invoke-WorkforceMonitoredProcess -StartInfo (New-TimeoutStartInfo -Mode startup) -StartupTimeoutSeconds 1 -IdleTimeoutSeconds 0 -HardTimeoutSeconds 0 -CompatibilityTimeoutSeconds 10
    if (-not $startup.TimedOut -or $startup.TimeoutKind -ne 'startup') {
        throw 'Startup timeout was not enforced.'
    }
    $result.startup_timeout = $true

    $idle = Invoke-WorkforceMonitoredProcess -StartInfo (New-TimeoutStartInfo -Mode idle) -StartupTimeoutSeconds 10 -IdleTimeoutSeconds 1 -HardTimeoutSeconds 0 -CompatibilityTimeoutSeconds 10
    if (-not $idle.TimedOut -or $idle.TimeoutKind -ne 'idle' -or $idle.StandardOutput -notmatch 'READY') {
        throw 'Idle timeout did not preserve partial output.'
    }
    $result.idle_timeout = $true
    $result.partial_output_preserved = $true

    $markerPath = Join-Path $testRoot 'hard-timeout-marker.txt'
    $hard = Invoke-WorkforceMonitoredProcess -StartInfo (New-TimeoutStartInfo -Mode hard -MarkerPath $markerPath) -StartupTimeoutSeconds 10 -IdleTimeoutSeconds 3 -HardTimeoutSeconds 1 -CompatibilityTimeoutSeconds 10
    if (-not $hard.TimedOut -or $hard.TimeoutKind -ne 'hard' -or $hard.StandardOutput -notmatch 'tick-') {
        throw 'Hard timeout was not enforced while output remained active.'
    }
    $markerLines = @(Get-Content -LiteralPath $markerPath -Encoding UTF8)
    if ($markerLines.Count -ne 1) {
        throw 'Timeout fixture repeated a side effect.'
    }
    $result.hard_timeout = $true
    $result.no_duplicate_side_effects = $true

    $strict = & $profileScript -Output mcp -ContextProfile project -TrustProfile strict | ConvertFrom-Json
    $balanced = & $profileScript -Output mcp -ContextProfile project -TrustProfile balanced | ConvertFrom-Json
    $delegated = & $profileScript -Output mcp -ContextProfile project -TrustProfile delegated | ConvertFrom-Json
    $hooksAllowed = & $profileScript -Output mcp -ContextProfile project -TrustProfile strict -AllowHooks | ConvertFrom-Json
    if ('Edit' -in @($strict.settings.permissions.allow) -or 'Edit(./**)' -notin @($balanced.settings.permissions.allow) -or @($delegated.settings.permissions.allow).Count -le @($balanced.settings.permissions.allow).Count) {
        throw 'Trust profiles do not provide the expected monotonic delegation levels.'
    }
    $result.trust_profiles = $true
    if (-not [bool]$strict.settings.disableAllHooks -or $null -ne $hooksAllowed.settings.PSObject.Properties['disableAllHooks'] -or -not $hooksAllowed.hooks_allowed) {
        throw 'Hooks were not disabled by default or AllowHooks did not remove the override.'
    }
    $result.hooks_default_off = $true
}
finally {
    if ($null -ne $listener) {
        $listener.Stop()
    }
    foreach ($process in $childProcesses) {
        if (-not $process.HasExited) {
            $process.Kill($true)
            [void]$process.WaitForExit(5000)
        }
        $process.Dispose()
    }
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

[pscustomobject]$result | ConvertTo-Json -Depth 6
