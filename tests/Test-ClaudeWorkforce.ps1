[CmdletBinding()]
param([switch]$SkipRuntime)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'Tests require PowerShell 7 or higher.'
}

$scriptPath = Join-Path $PSScriptRoot '..\claude-workforce\scripts\claude-workforce.ps1'
$installPath = Join-Path $PSScriptRoot '..\Install.ps1'
foreach ($path in @($scriptPath, $installPath)) {
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
    ('C:' + [IO.Path]::DirectorySeparatorChar + 'Users' + [IO.Path]::DirectorySeparatorChar),
    ('D:' + [IO.Path]::DirectorySeparatorChar + 'Git' + [IO.Path]::DirectorySeparatorChar)
)
foreach ($marker in $forbidden) {
    if ($sourceText.Contains($marker, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Forbidden marker found in public script: $marker"
    }
}

$result = [ordered]@{
    parser = $true
    no_machine_paths = $true
    installer_boundary = $false
    runtime = -not $SkipRuntime
}

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

if (-not $SkipRuntime) {
    $capabilities = (& $scriptPath -Action capabilities | ConvertFrom-Json)
    if (-not $capabilities.version_supported -or -not $capabilities.has_background -or -not $capabilities.has_json_list -or -not $capabilities.has_output_format) {
        throw 'Claude Code runtime does not satisfy workforce requirements.'
    }
    if ($capabilities.bypass_allowed) {
        throw 'bypass_allowed must remain false.'
    }
    $expectedSearchAllow = @(
        'WebSearch',
        'mcp__plugin_exa_exa__web_search_exa',
        'mcp__tavily__tavily_research',
        'mcp__tavily__tavily_search'
    )
    foreach ($tool in $expectedSearchAllow) {
        if ($tool -notin @($capabilities.effective_allow_tools)) {
            throw "Expected public search tool is not allowed: $tool"
        }
    }
    foreach ($tool in @('Bash', 'Edit', 'Write', 'NotebookEdit')) {
        if ($tool -notin @($capabilities.effective_ask_tools)) {
            throw "Expected side-effecting tool is not in ask: $tool"
        }
    }
    if ('Agent' -notin @($capabilities.effective_deny_tools)) {
        throw 'Agent must be denied unless explicitly enabled for a task.'
    }
    foreach ($rule in @('Read(./.env)', 'Edit(./.env)', 'Write(./.env)', 'Read(~/.codex/auth.json)', 'Edit(~/.codex/auth.json)', 'Write(~/.codex/auth.json)')) {
        if ($rule -notin @($capabilities.effective_deny_tools)) {
            throw "Credential protection rule is missing: $rule"
        }
    }
    $result.executable_hash_pinned = [bool]$capabilities.executable_hash_pinned
    $result.broad_web_fetch_allowed = [bool]$capabilities.broad_web_fetch_allowed
}

[pscustomobject]$result | ConvertTo-Json -Depth 4
