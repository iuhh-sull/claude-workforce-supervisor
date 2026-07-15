function Invoke-WorkforceReaper {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Workers,
        [ValidateSet('low', 'medium', 'high')][string]$InvocationLevel = 'medium',
        [ValidateSet('fixed', 'adaptive')][string]$ConcurrencyPolicy = 'adaptive',
        [ValidateRange(0, 300)][int]$GracefulShutdownSeconds = 10,
        [ValidateRange(0, 300)][int]$PortReleaseTimeoutSeconds = 15,
        [switch]$ForceOwnedResources
    )

    return Invoke-WorkforceStateTransaction -StateRoot $StateRoot -LockName 'reaper-global' -ScriptBlock {
        $before = @(Get-WorkforceManifests -StateRoot $StateRoot)
        $beforeState = @($before | Sort-Object manifest_id | ForEach-Object { "$($_.manifest_id)|$($_.revision)|$($_.status)|$($_.cleanup_status)|$($_.updated_at)" }) -join "`n"
        $candidates = @($before | Where-Object {
            [string]$_.status -in @('acquired', 'running', 'waiting', 'needs-input', 'finalizing', 'stale', 'cleanup-incomplete')
        })
        $namespaces = @($candidates | ForEach-Object { [string]$_.namespace } | Where-Object { $_ } | Select-Object -Unique)
        $results = foreach ($namespace in $namespaces) {
            $sample = @($candidates | Where-Object { [string]$_.namespace -eq $namespace } | Sort-Object updated_at -Descending) | Select-Object -First 1
            if ($null -eq $sample) {
                continue
            }
            $circuitKey = Get-ApiCircuitKey -Provider 'reaper' -Endpoint '' -Model 'none'
            Invoke-WorkforceReconcile `
                -StateRoot $StateRoot `
                -Namespace $namespace `
                -CwdFingerprint ([string]$sample.cwd_fingerprint) `
                -TaskFingerprint ([string]$sample.task_fingerprint) `
                -Workers $Workers `
                -InvocationLevel $InvocationLevel `
                -ConcurrencyPolicy $ConcurrencyPolicy `
                -CircuitKey $circuitKey `
                -GracefulShutdownSeconds $GracefulShutdownSeconds `
                -PortReleaseTimeoutSeconds $PortReleaseTimeoutSeconds `
                -ForceOwnedResources:$ForceOwnedResources
        }
        $after = @(Get-WorkforceManifests -StateRoot $StateRoot)
        $afterState = @($after | Sort-Object manifest_id | ForEach-Object { "$($_.manifest_id)|$($_.revision)|$($_.status)|$($_.cleanup_status)|$($_.updated_at)" }) -join "`n"
        return [pscustomobject]@{
            action = 'reap'
            candidates = $candidates.Count
            namespaces_checked = $namespaces.Count
            stale_workers_found = @($results | Measure-Object -Property stale_workers_found -Sum).Sum
            stale_workers_cleaned = @($results | Measure-Object -Property stale_workers_cleaned -Sum).Sum
            cleanup_incomplete = @($after | Where-Object { [string]$_.status -eq 'cleanup-incomplete' -or [string]$_.cleanup_status -eq 'incomplete' }).Count
            terminal_manifests = @($after | Where-Object { [string]$_.status -in @('completed', 'failed', 'cancelled', 'stopped') }).Count
            idempotent = $beforeState -eq $afterState
            completed_at = (Get-WorkforceUtcNow).ToString('o')
        }
    }
}
