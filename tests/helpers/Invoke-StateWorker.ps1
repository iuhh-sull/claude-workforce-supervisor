[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$StateScript,
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [Parameter(Mandatory = $true)][ValidateSet('update')][string]$Mode,
    [string]$WorkerId = 'worker'
)

$ErrorActionPreference = 'Stop'
. $StateScript

$path = Join-Path $StateRoot 'concurrent.json'
Update-WorkforceState -StateRoot $StateRoot -LockName 'concurrent-test' -Path $path -DefaultValue ([pscustomobject]@{ count = 0; workers = @() }) -UpdateScript {
    param($current)
    $current.count = [int]$current.count + 1
    $current.workers = @($current.workers) + @($WorkerId)
    return $current
} | Out-Null
