[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Destination = ([IO.Path]::Combine($HOME, '.codex', 'skills', 'claude-workforce')),
    [switch]$Force,
    [switch]$SkipStateMigration
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'Install.ps1 requires PowerShell 7 or higher.'
}

$source = Join-Path $PSScriptRoot 'claude-workforce'
$destinationFull = [IO.Path]::GetFullPath($Destination)
$protectedRoots = @(
    [IO.Path]::GetPathRoot($destinationFull),
    [IO.Path]::GetFullPath($HOME),
    [IO.Path]::GetFullPath([IO.Path]::Combine($HOME, '.codex')),
    [IO.Path]::GetFullPath([IO.Path]::Combine($HOME, '.codex', 'skills'))
)
if ($destinationFull -in $protectedRoots -or [IO.Path]::GetFileName($destinationFull) -ne 'claude-workforce') {
    throw 'Destination must be a dedicated directory named claude-workforce, not a filesystem, HOME, .codex, or skills root.'
}
$Destination = $destinationFull
$destinationExists = Test-Path -LiteralPath $Destination
if ($destinationExists) {
    $destinationItem = Get-Item -LiteralPath $Destination -Force
    if (-not $destinationItem.PSIsContainer) {
        throw 'Existing destination must be a directory.'
    }
    if (($destinationItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Existing destination must not be a symbolic link, junction, or other reparse point.'
    }
}
$required = @(
    ([IO.Path]::Combine($source, 'SKILL.md')),
    ([IO.Path]::Combine($source, 'agents', 'openai.yaml')),
    ([IO.Path]::Combine($source, 'scripts', 'claude-workforce.ps1')),
    ([IO.Path]::Combine($source, 'scripts', 'new-workforce-session-profile.ps1')),
    ([IO.Path]::Combine($source, 'scripts', 'workforce-lifecycle.ps1')),
    ([IO.Path]::Combine($source, 'scripts', 'workforce-state.ps1')),
    ([IO.Path]::Combine($source, 'scripts', 'workforce-resource-broker.ps1')),
    ([IO.Path]::Combine($source, 'scripts', 'workforce-timeouts.ps1')),
    ([IO.Path]::Combine($source, 'scripts', 'workforce-reaper.ps1')),
    ([IO.Path]::Combine($source, 'config', 'provider-pricing.psd1')),
    ([IO.Path]::Combine($source, 'references', 'budget-and-timeouts.md')),
    ([IO.Path]::Combine($source, 'references', 'connectivity.md')),
    ([IO.Path]::Combine($source, 'references', 'deepseek-provider.md')),
    ([IO.Path]::Combine($source, 'references', 'invocation-levels.md')),
    ([IO.Path]::Combine($source, 'references', 'operations.md')),
    ([IO.Path]::Combine($source, 'references', 'permissions.md')),
    ([IO.Path]::Combine($source, 'references', 'port-management.md')),
    ([IO.Path]::Combine($source, 'references', 'portability.md')),
    ([IO.Path]::Combine($source, 'references', 'resource-lifecycle.md')),
    ([IO.Path]::Combine($source, 'references', 'troubleshooting.md'))
)
foreach ($path in $required) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required package file is missing: $path"
    }
}

$destinationParent = Split-Path -Parent $Destination
$backup = $null
if ($destinationExists) {
    if (-not $Force) {
        throw "Destination already exists: $Destination. Re-run with -Force to back it up and replace it."
    }
    $backupRoot = [IO.Path]::Combine($HOME, '.codex', 'backups')
    $backup = Join-Path $backupRoot "claude-workforce-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')"
    if ($PSCmdlet.ShouldProcess($Destination, "Back up to $backup")) {
        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
        Copy-Item -LiteralPath $Destination -Destination $backup -Recurse -Force
    }
}

if ($PSCmdlet.ShouldProcess($Destination, 'Install claude-workforce skill')) {
    New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    Copy-Item -LiteralPath $source -Destination $Destination -Recurse -Force
}

$migration = $null
$rollbackCommand = $null
$stateRoot = if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_WORKFORCE_STATE_ROOT)) {
    $env:CLAUDE_WORKFORCE_STATE_ROOT
}
else {
    [IO.Path]::Combine($HOME, '.codex', 'claude-workforce')
}
$migrationRequired = $false
$stateVersionPath = Join-Path $stateRoot 'state-version.json'
$resourceIndexPath = Join-Path $stateRoot 'resource-index.json'
if (Test-Path -LiteralPath $resourceIndexPath -PathType Leaf) {
    $migrationRequired = $true
}
elseif (Test-Path -LiteralPath $stateVersionPath -PathType Leaf) {
    try {
        $stateVersion = Get-Content -LiteralPath $stateVersionPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $migrationRequired = [int]$stateVersion.schema_version -lt 2
    }
    catch {
        $migrationRequired = $true
    }
}
elseif (Test-Path -LiteralPath (Join-Path $stateRoot 'manifests') -PathType Container) {
    $migrationRequired = @(Get-ChildItem -LiteralPath (Join-Path $stateRoot 'manifests') -Filter '*.json' -File -ErrorAction SilentlyContinue).Count -gt 0
}
$migrationStatus = if ($migrationRequired -and $SkipStateMigration) {
    [pscustomobject]@{ required = $true; skipped = $true; reason = 'SkipStateMigration' }
}
elseif (-not $migrationRequired) {
    [pscustomobject]@{ required = $false; skipped = $false; reason = 'not-required' }
}
if ($migrationRequired -and -not $SkipStateMigration -and (Test-Path -LiteralPath $Destination -PathType Container)) {
    $installedWorkforce = Join-Path $Destination 'scripts\claude-workforce.ps1'
    if ($PSCmdlet.ShouldProcess($stateRoot, 'Migrate workforce state with an automatic rollback backup')) {
        $migration = & $installedWorkforce -Action migrate -StateRoot $stateRoot | ConvertFrom-Json
        $migrationStatus = $migration
        if ($migration.migrated -and -not [string]::IsNullOrWhiteSpace([string]$migration.backup_path)) {
            $rollbackCommand = "pwsh -NoProfile -File `"$installedWorkforce`" -Action rollback-migration -StateRoot `"$stateRoot`" -MigrationBackupPath `"$($migration.backup_path)`""
        }
    }
}

[pscustomobject]@{
    installed = Test-Path -LiteralPath (Join-Path $Destination 'SKILL.md') -PathType Leaf
    destination = $Destination
    backup = $backup
    local_config = [IO.Path]::Combine($HOME, '.codex', 'claude-workforce.local.psd1')
    state_root = $stateRoot
    state_migration = $migrationStatus
    rollback_command = $rollbackCommand
} | ConvertTo-Json -Depth 4
