[CmdletBinding()]
param([switch]$SkipRuntime)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'Tests require PowerShell 7 or higher.'
}

$scriptPath = Join-Path $PSScriptRoot '..\claude-workforce\scripts\claude-workforce.ps1'
$profilePath = Join-Path $PSScriptRoot '..\claude-workforce\scripts\new-workforce-session-profile.ps1'
$installPath = Join-Path $PSScriptRoot '..\Install.ps1'
foreach ($path in @($scriptPath, $profilePath, $installPath)) {
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
    cmd_shim = -not $IsWindows
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

$mcpProfile = & $profilePath -Output mcp -ContextProfile project | ConvertFrom-Json -ErrorAction Stop
if ($mcpProfile.purpose -ne 'codex-claude-workforce-session-only' -or $mcpProfile.schema_version -ne 1) {
    throw 'MCP workforce profile identity is invalid.'
}
if (@($mcpProfile.advanced.settingSources) -join ',' -ne 'user,project' -or -not $mcpProfile.advanced.persistSession -or -not $mcpProfile.advanced.strictMcpConfig) {
    throw 'MCP project profile isolation fields are invalid.'
}
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
$nestedProfile = & $profilePath -Output mcp -ContextProfile project -AllowNestedAgents | ConvertFrom-Json -ErrorAction Stop
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
    if ($rosterFormat -eq 'namespace') {
        '[{"id":"owned-a","name":"cx-testns42-owned","sessionId":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","cwd":"' + $escapedCwd + '","state":"done"},{"id":"foreign-a","name":"cx-foreign-owned","sessionId":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee","cwd":"' + $escapedCwd + '","state":"done"}]'
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
    $localOriginRepo = $null
    try {
        $fakeHash = (Get-FileHash -LiteralPath $fakeClaude -Algorithm SHA256).Hash
        $backgroundBudgetRejected = $false
        try {
            & $scriptPath -Action start -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -Cwd (Split-Path -Parent $PSScriptRoot) -Prompt 'guard probe' -MaxTurns 1 -MaxBudgetUsd 1 | Out-Null
        }
        catch {
            $expectedMessage = 'Start uses Claude background mode, which does not support per-run turn, SDK budget, or provider-budget thresholds. Use run or Claude Code MCP when bounded accounting is required.'
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
        if ($startResult.workforce_profile_version -ne 1 -or $startResult.worker_name -notmatch '-w1-p[0-9a-f]{10}$' -or [string]::IsNullOrWhiteSpace([string]$startResult.launch_provenance.fingerprint)) {
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
        $noToolsProjectResult = (& $scriptPath -Action run -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -Cwd (Split-Path -Parent $PSScriptRoot) -Prompt 'NoTools isolation probe' -NoTools -ContextProfile project -MaxTurns 1 -MaxBudgetUsd 1 -IncludeSdkCostEstimate | ConvertFrom-Json)
        if ($noToolsProjectResult.context_profile -ne 'minimal') {
            throw "NoTools + ContextProfile project did not force minimal profile (got: $($noToolsProjectResult.context_profile))."
        }
        if ($noToolsProjectResult.result -notmatch 'HAS_SAFE_MODE=True') {
            throw 'NoTools + ContextProfile project did not include --safe-mode in CLI arguments.'
        }
        $result.no_tools_project_forced_minimal = $true

        # NoTools + ContextProfile full → forced minimal
        $noToolsFullResult = (& $scriptPath -Action run -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -Cwd (Split-Path -Parent $PSScriptRoot) -Prompt 'NoTools isolation probe' -NoTools -ContextProfile full -MaxTurns 1 -MaxBudgetUsd 1 -IncludeSdkCostEstimate | ConvertFrom-Json)
        if ($noToolsFullResult.context_profile -ne 'minimal') {
            throw "NoTools + ContextProfile full did not force minimal profile (got: $noToolsFullResult.context_profile)."
        }
        $result.no_tools_full_forced_minimal = $true

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

        # Unknown provider pricing cannot silently pretend that a provider soft budget is active.
        $unpricedSoftBudgetRejected = $false
        try {
            & $scriptPath -Action run -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -Cwd (Split-Path -Parent $PSScriptRoot) -Prompt 'unknown model soft budget probe' -NoTools -MaxTurns 1 -ProviderBudget 1 -Model 'gpt-5' | Out-Null
        }
        catch {
            $unpricedSoftBudgetRejected = $_.Exception.Message -match 'no audited pricing'
        }
        if (-not $unpricedSoftBudgetRejected) {
            throw 'Unknown model accepted an ineffective provider-only soft budget without acknowledgement.'
        }
        $result.unknown_model_soft_budget_guard = $true

        $unpricedOverrideResult = (& $scriptPath -Action run -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -Cwd (Split-Path -Parent $PSScriptRoot) -Prompt 'unknown model override probe' -NoTools -MaxTurns 1 -ProviderBudget 1 -Model 'gpt-5' -AllowUnpricedModel | ConvertFrom-Json)
        if ($null -ne $unpricedOverrideResult.provider_cost_estimate -or $unpricedOverrideResult.provider_cost_note -notmatch 'No audited') {
            throw 'Explicit unpriced-model override must preserve unavailable provider pricing.'
        }
        $result.unknown_model_explicit_override = $true

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
            if ($fallbackList.owner -ne 'cx-manual' -or $fallbackList.count -ne 1) {
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
        }
        finally {
            $env:CF_TEST_ROSTER_FORMAT = $previousRosterFormat
        }

        $replyModelRejected = $false
        try {
            & $scriptPath -Action reply -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -Id 'worker-model-guard' -Prompt 'guard probe' -MaxTurns 1 -ProviderBudgetCny ([decimal]'0.01') | Out-Null
        }
        catch {
            if ($_.Exception.Message -ceq 'Reply requires an explicit -Model so the resumed task is routed deliberately and provider cost uses the correct rate.') {
                $replyModelRejected = $true
            }
            else {
                throw
            }
        }
        if (-not $replyModelRejected) {
            throw 'Reply silently accepted the default model instead of requiring deliberate routing.'
        }
        $result.reply_model_guard = $true

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

        $replyEffortRejected = $false
        try {
            & $scriptPath -Action reply -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -Id 'worker-reply' -AllThreads -Prompt 'effort guard probe' -MaxTurns 1 -ProviderBudgetCny ([decimal]'0.01') -Model 'deepseek-v4-flash[1m]' -AllowLegacySession | Out-Null
        }
        catch {
            if ($_.Exception.Message -ceq 'Reply requires an explicit -Effort so the resumed task uses a deliberate reasoning level rather than silently defaulting to medium.') {
                $replyEffortRejected = $true
            }
            else {
                throw
            }
        }
        if (-not $replyEffortRejected) {
            throw 'Reply silently accepted the default Effort instead of requiring deliberate routing.'
        }
        $result.reply_effort_guard = $true

        $legacyRejected = $false
        try {
            & $scriptPath -Action reply -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -Id 'worker-reply' -AllThreads -Prompt 'legacy provenance probe' -NoTools -MaxTurns 1 -MaxBudgetUsd 1 -Model 'deepseek-v4-flash[1m]' -Effort low | Out-Null
        }
        catch {
            $legacyRejected = $_.Exception.Message -match 'predates workforce provenance tracking'
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

        $errorResult = (& $scriptPath -Action run -ClaudeExecutable $fakeClaude -ExpectedClaudeSha256 $fakeHash -Cwd (Split-Path -Parent $PSScriptRoot) -Prompt 'error recovery probe' -NoTools -MaxTurns 2 -MaxBudgetUsd 1 -Model 'deepseek-v4-flash[1m]' -IncludeSdkCostEstimate | ConvertFrom-Json)
        if ($errorResult.process_exit_code -ne 1 -or $errorResult.result_subtype -ne 'error_max_turns' -or -not $errorResult.is_error) {
            throw 'Nonzero Claude result metadata was not preserved.'
        }
        if ($errorResult.total_cost_usd -ne 0.25 -or $errorResult.usage.input_tokens -ne 100 -or $errorResult.usage.cache_read_input_tokens -ne 30) {
            throw 'Nonzero Claude usage or cost metadata was not preserved.'
        }
        if ($errorResult.sdk_total_cost_usd -ne 0.25 -or [decimal]$errorResult.provider_cost_estimate_cny -ne [decimal]'0.000201') {
            throw 'Provider-aware cost fields were not calculated from usage correctly.'
        }
        if ($errorResult.provider_pricing.currency -ne 'CNY' -or $errorResult.provider_pricing.cache_miss_per_million -ne 1) {
            throw 'Provider pricing metadata is missing or incorrect.'
        }
        if ($errorResult.provider_billing_tokens.cache_miss -ne 120 -or $errorResult.provider_billing_tokens.cache_hit -ne 30 -or $errorResult.provider_billing_tokens.output -ne 40) {
            throw 'Provider billing token buckets were not derived correctly.'
        }
        if ([decimal]$errorResult.provider_cost_components_cny.cache_miss -ne [decimal]'0.00012' -or [decimal]$errorResult.provider_cost_components_cny.cache_hit -ne [decimal]'0.0000006' -or [decimal]$errorResult.provider_cost_components_cny.output -ne [decimal]'0.00008') {
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
    }
    finally {
        $fakeRoster = Join-Path ([IO.Path]::GetTempPath()) ((Split-Path -LeafBase $fakeClaude) + '-roster.json')
        Remove-Item -LiteralPath $fakeRoster -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $fakeClaude -Force -ErrorAction SilentlyContinue
        if ($fakeCmd) {
            Remove-Item -LiteralPath $fakeCmd -Force -ErrorAction SilentlyContinue
        }
        if ($localOriginRepo -and (Test-Path -LiteralPath $localOriginRepo -PathType Container)) {
            Remove-Item -LiteralPath $localOriginRepo -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $capabilities = (& $scriptPath -Action capabilities | ConvertFrom-Json)
    if (-not $capabilities.version_supported -or $capabilities.version_degraded -or -not $capabilities.has_background -or -not $capabilities.has_json_list -or -not $capabilities.has_output_format) {
        throw 'Claude Code runtime does not satisfy workforce requirements.'
    }
    if ($capabilities.minimum_supported -ne '2.1.207' -or $capabilities.degraded_range -ne '2.1.200–2.1.206') {
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

[pscustomobject]$result | ConvertTo-Json -Depth 4
