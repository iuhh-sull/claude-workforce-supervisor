[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Destination = ([IO.Path]::Combine($HOME, '.codex', 'skills', 'claude-workforce')),
    [switch]$Force
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
$required = @(
    ([IO.Path]::Combine($source, 'SKILL.md')),
    ([IO.Path]::Combine($source, 'agents', 'openai.yaml')),
    ([IO.Path]::Combine($source, 'scripts', 'claude-workforce.ps1'))
)
foreach ($path in $required) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required package file is missing: $path"
    }
}

$destinationParent = Split-Path -Parent $Destination
$backup = $null
if (Test-Path -LiteralPath $Destination) {
    if (-not $Force) {
        throw "Destination already exists: $Destination. Re-run with -Force to back it up and replace it."
    }
    $backupRoot = [IO.Path]::Combine($HOME, '.codex', 'backups')
    $backup = Join-Path $backupRoot "claude-workforce-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
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

[pscustomobject]@{
    installed = Test-Path -LiteralPath (Join-Path $Destination 'SKILL.md') -PathType Leaf
    destination = $Destination
    backup = $backup
    local_config = [IO.Path]::Combine($HOME, '.codex', 'claude-workforce.local.psd1')
} | ConvertTo-Json -Depth 4
