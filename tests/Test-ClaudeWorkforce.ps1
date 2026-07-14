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

$requiredMarkers = @(
    "'run'",
    'ContextProfile',
    'MaxTurns',
    'MaxBudgetUsd',
    'MaxMcpOutputTokens',
    'EnableToolSearch',
    '--max-turns',
    '--max-budget-usd',
    '--no-chrome',
    'total_cost_usd',
    'result_subtype',
    'usage'
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
    $backgroundBudgetRejected = $false
    try {
        & $scriptPath -Action start -Cwd (Split-Path -Parent $PSScriptRoot) -Prompt 'guard probe' -MaxTurns 1 -MaxBudgetUsd 1 | Out-Null
    }
    catch {
        $expectedMessage = 'Start uses Claude background mode, which does not support --max-turns or --max-budget-usd. Use run or Claude Code MCP when a hard cap is required.'
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

    $fakeClaude = Join-Path ([IO.Path]::GetTempPath()) "claude-workforce-fake-$([guid]::NewGuid().ToString('N')).ps1"
    $fakeSource = @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Remaining)
if ('--version' -in $Remaining) {
    '2.1.207 (Claude Code)'
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
if (($Remaining -join ' ') -like '*null usage probe*') {
    '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"session_id":"22222222-2222-4222-8222-222222222222","total_cost_usd":0.01,"result":"OK"}'
    exit 0
}
'{"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":2,"session_id":"11111111-1111-4111-8111-111111111111","total_cost_usd":0.25,"usage":{"input_tokens":100,"cache_creation_input_tokens":20,"cache_read_input_tokens":30,"output_tokens":40},"result":null}'
exit 1
'@
    [IO.File]::WriteAllText($fakeClaude, $fakeSource, [Text.UTF8Encoding]::new($false))
    try {
        $fakeHash = (Get-FileHash -LiteralPath $fakeClaude -Algorithm SHA256).Hash
        $errorResult = (& $scriptPath -Action run -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -Cwd (Split-Path -Parent $PSScriptRoot) -Prompt 'error recovery probe' -NoTools -MaxTurns 2 -MaxBudgetUsd 1 | ConvertFrom-Json)
        if ($errorResult.process_exit_code -ne 1 -or $errorResult.result_subtype -ne 'error_max_turns' -or -not $errorResult.is_error) {
            throw 'Nonzero Claude result metadata was not preserved.'
        }
        if ($errorResult.total_cost_usd -ne 0.25 -or $errorResult.usage.input_tokens -ne 100 -or $errorResult.usage.cache_read_input_tokens -ne 30) {
            throw 'Nonzero Claude usage or cost metadata was not preserved.'
        }
        $result.nonzero_usage_recovery = $true

        $missingUsageResult = (& $scriptPath -Action run -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -Cwd (Split-Path -Parent $PSScriptRoot) -Prompt 'null usage probe' -NoTools -MaxTurns 1 -MaxBudgetUsd 1 | ConvertFrom-Json)
        if ($missingUsageResult.result_subtype -ne 'success' -or $missingUsageResult.result -ne 'OK') {
            throw 'Claude result without usage metadata was not preserved.'
        }
        if ($null -ne $missingUsageResult.usage.input_tokens -or $null -ne $missingUsageResult.usage.output_tokens) {
            throw 'Missing Claude usage metadata must remain explicitly null.'
        }
        $result.missing_usage_recovery = $true
    }
    finally {
        Remove-Item -LiteralPath $fakeClaude -Force -ErrorAction SilentlyContinue
    }

    $capabilities = (& $scriptPath -Action capabilities | ConvertFrom-Json)
    if (-not $capabilities.version_supported -or -not $capabilities.has_background -or -not $capabilities.has_json_list -or -not $capabilities.has_output_format) {
        throw 'Claude Code runtime does not satisfy workforce requirements.'
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
    if ($capabilities.default_context_profile -ne 'auto' -or $capabilities.default_mcp_output_tokens -ne 10000) {
        throw 'Cost-control defaults drifted from the documented profile.'
    }
    foreach ($argument in @('--no-chrome', '--safe-mode', '--strict-mcp-config', '--tools', '--disable-slash-commands')) {
        if ($argument -notin @($capabilities.no_tools_isolation)) {
            throw "No-tools isolation capability is missing argument: $argument"
        }
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
