[CmdletBinding()]
param(
    [ValidateSet('settings', 'mcp')]
    [string]$Output = 'settings',
    [ValidateSet('minimal', 'user', 'project', 'full')]
    [string]$ContextProfile = 'project',
    [ValidateSet('strict', 'balanced', 'delegated')]
    [string]$TrustProfile = 'balanced',
    [switch]$AllowHooks,
    [switch]$AllowNestedAgents,
    [ValidateSet('low', 'medium', 'high')]
    [string]$InvocationLevel = 'medium',
    [ValidateSet('cleanup', 'retain-session', 'keep-resources')]
    [string]$ResourcePolicy = 'retain-session',
    [ValidateSet('stop-on-complete', 'remove-on-complete', 'idle-ttl', 'manual')]
    [string]$SessionRetentionPolicy = 'stop-on-complete',
    [ValidateRange(1, 3600)]
    [int]$McpStartupTimeoutSeconds = 60,
    [ValidateRange(1, 86400)]
    [int]$McpIdleTimeoutSeconds = 600,
    [ValidateRange(1, 86400)]
    [int]$McpToolTimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
$sensitiveReadRules = @(
    'Read(./.env)', 'Read(./.env.*)', 'Read(**/.env)', 'Read(**/.env.*)',
    'Read(~/.ssh/**)', 'Read(~/.aws/**)', 'Read(~/.codex/auth.json)',
    'Read(~/.codex/config.toml)', 'Read(~/.claude/settings.json)',
    'Read(~/.claude/settings.local.json)', 'Read(~/.npmrc)', 'Read(~/.pypirc)',
    'Read(~/.netrc)', 'Read(~/.docker/config.json)', 'Read(~/.config/gh/hosts.yml)',
    'Read(**/credentials.json)', 'Read(**/secrets.yaml)', 'Read(**/secrets.yml)',
    'Read(**/*.pem)', 'Read(**/*.key)', 'Read(**/*.pfx)', 'Read(**/*.p12)'
)
# Optional MCP tool names injected via environment variables (semicolon-separated).
# Defaults are empty — only built-in Claude Code tools are pre-configured.
# To add your MCP tools, set WORKFORCE_MCP_ALLOW_TOOLS / WORKFORCE_MCP_ASK_TOOLS in
# the current workforce process environment. Example:
#   $env:WORKFORCE_MCP_ALLOW_TOOLS = 'mcp__tavily__tavily_search;mcp__tavily__tavily_research'
#   $env:WORKFORCE_MCP_ASK_TOOLS   = 'mcp__tavily__tavily_crawl;mcp__plugin_context-mode_context-mode__ctx_fetch_and_index'
$extraAllowTools = if ($env:WORKFORCE_MCP_ALLOW_TOOLS) { @($env:WORKFORCE_MCP_ALLOW_TOOLS -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { @() }
$extraAskTools   = if ($env:WORKFORCE_MCP_ASK_TOOLS)   { @($env:WORKFORCE_MCP_ASK_TOOLS -split ';'   | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { @() }

$baseAllowRules = @(
    'Read', 'Glob', 'Grep', 'WebSearch', 'Plan', 'EnterPlanMode', 'ExitPlanMode'
) + $extraAllowTools

# These rules are intentionally relative to the delegated session CWD. An
# absolute path or a path escaping through .. does not match this grant and
# falls back to Claude Code's normal permission decision.
$worktreeWriteAllowRules = @(
    'Edit(./**)', 'Write(./**)', 'NotebookEdit(./**)'
)
$externalWriteAskRules = @(
    'Edit(../**)', 'Write(../**)', 'NotebookEdit(../**)',
    'Edit(~/**)', 'Write(~/**)', 'NotebookEdit(~/**)'
)

# Native Claude Code Bash permission patterns provide the command matching.
# Keep this list bounded; a broad Bash allow would also authorize shell-based
# writes outside the worktree on platforms without an OS sandbox.
$balancedBashAllowRules = @(
    'Bash(git status)', 'Bash(git status:*)',
    'Bash(git diff)', 'Bash(git diff:*)',
    'Bash(git log)', 'Bash(git log:*)',
    'Bash(git show)', 'Bash(git show:*)',
    'Bash(git ls-files)', 'Bash(git ls-files:*)',
    'Bash(rg:*)', 'Bash(Get-ChildItem:*)',
    'Bash(npm test)', 'Bash(npm test:*)',
    'Bash(npm run test)', 'Bash(npm run test:*)',
    'Bash(npm run lint)', 'Bash(npm run lint:*)',
    'Bash(npm run build)', 'Bash(npm run build:*)',
    'Bash(pnpm test)', 'Bash(pnpm test:*)',
    'Bash(pnpm run test)', 'Bash(pnpm run test:*)',
    'Bash(pnpm run lint)', 'Bash(pnpm run lint:*)',
    'Bash(pnpm run build)', 'Bash(pnpm run build:*)',
    'Bash(yarn test)', 'Bash(yarn test:*)',
    'Bash(yarn lint)', 'Bash(yarn lint:*)',
    'Bash(yarn build)', 'Bash(yarn build:*)',
    'Bash(pytest)', 'Bash(pytest:*)',
    'Bash(dotnet test)', 'Bash(dotnet test:*)',
    'Bash(dotnet build)', 'Bash(dotnet build:*)',
    'Bash(cargo test)', 'Bash(cargo test:*)',
    'Bash(cargo build)', 'Bash(cargo build:*)',
    'Bash(go test)', 'Bash(go test:*)',
    'Bash(go build)', 'Bash(go build:*)'
)
$delegatedBashAllowRules = @(
    'Bash(npm run typecheck)', 'Bash(npm run typecheck:*)',
    'Bash(pnpm run typecheck)', 'Bash(pnpm run typecheck:*)',
    'Bash(yarn typecheck)', 'Bash(yarn typecheck:*)',
    'Bash(dotnet format)', 'Bash(dotnet format:*)',
    'Bash(cargo check)', 'Bash(cargo check:*)',
    'Bash(cargo clippy)', 'Bash(cargo clippy:*)',
    'Bash(go vet)', 'Bash(go vet:*)'
)
$highRiskBashAskRules = @(
    'Bash(npm install:*)', 'Bash(npm i:*)', 'Bash(npm add:*)',
    'Bash(pnpm install:*)', 'Bash(pnpm add:*)',
    'Bash(yarn install:*)', 'Bash(yarn add:*)',
    'Bash(pip install:*)', 'Bash(pip3 install:*)', 'Bash(uv add:*)',
    'Bash(dotnet add:*)', 'Bash(cargo add:*)', 'Bash(go get:*)',
    'Bash(winget install:*)', 'Bash(choco install:*)', 'Bash(scoop install:*)',
    'Bash(git commit:*)', 'Bash(git push:*)',
    'Bash(gh pr create:*)', 'Bash(gh release create:*)',
    'Bash(npm publish:*)', 'Bash(dotnet nuget push:*)', 'Bash(cargo publish:*)',
    'Bash(vercel:*)', 'Bash(netlify deploy:*)', 'Bash(terraform apply:*)',
    'Bash(rm:*)', 'Bash(del:*)', 'Bash(Remove-Item:*)',
    'Bash(git clean:*)', 'Bash(git reset:*)'
)

$askRules = switch ($TrustProfile) {
    'strict' {
        @('Bash', 'Edit', 'Write', 'NotebookEdit', 'WebFetch', 'Agent', 'Task')
        break
    }
    default {
        @('WebFetch', 'Agent', 'Task') + $externalWriteAskRules + $highRiskBashAskRules
        break
    }
}
$askRules += $extraAskTools + $sensitiveReadRules
$allowRules = $baseAllowRules
if ($TrustProfile -in @('balanced', 'delegated')) {
    $allowRules += $worktreeWriteAllowRules + $balancedBashAllowRules
}
if ($TrustProfile -eq 'delegated') {
    $allowRules += $delegatedBashAllowRules
}
if ($AllowNestedAgents) {
    $askRules = @($askRules | Where-Object { $_ -notin @('Agent', 'Task') })
    $allowRules += @('Agent', 'Task')
}

$settings = [ordered]@{}
if (-not $AllowHooks) {
    $settings.disableAllHooks = $true
}
$settings.permissions = [ordered]@{
    disableBypassPermissionsMode = 'disable'
    disableAutoMode = 'disable'
    deny = @()
    ask = @($askRules | Select-Object -Unique)
    allow = @($allowRules | Select-Object -Unique)
}

if ($Output -eq 'settings') {
    $settings | ConvertTo-Json -Compress -Depth 12
    return
}

$settingSources = switch ($ContextProfile) {
    'minimal' { @() }
    'user' { @('user') }
    'project' { @('user', 'project') }
    'full' { @('user', 'project', 'local') }
}

[ordered]@{
    schema_version = 1
    purpose = 'codex-claude-workforce-session-only'
    trust_profile = $TrustProfile
    hooks_allowed = [bool]$AllowHooks
    settings = $settings
    allowedTools = @()
    disallowedTools = @()
    strictAllowedTools = $false
    lifecycle = [ordered]@{
        schema_version = 1
        invocation_level = $InvocationLevel
        resource_policy = $ResourcePolicy
        session_retention_policy = $SessionRetentionPolicy
        mcp_startup_timeout_seconds = $McpStartupTimeoutSeconds
        mcp_idle_timeout_seconds = $McpIdleTimeoutSeconds
        mcp_tool_timeout_seconds = $McpToolTimeoutSeconds
        recovery = [ordered]@{
            http_sse = 'wait-for-internal-reconnect-then-restart-confirmed-dead-service-once'
            stdio = 'verify-owned-child-exit-then-restart-once'
        }
    }
    advanced = [ordered]@{
        settingSources = $settingSources
        settings = $settings
        persistSession = $true
        strictMcpConfig = $ContextProfile -ne 'full'
    }
    notes = @(
        'Pass settings only to mcp__claude_code__claude_code or diskResumeConfig for the delegated session.',
        'Do not copy this object into ~/.claude/settings.json.',
        'Leave MCP allowedTools and disallowedTools empty so claude-code-mcp can surface requests through canUseTool.',
        'Use claude_code_check and respond_permission for per-request approval; do not persist approval rules.',
        "Trust profile '$TrustProfile' only pre-authorizes the rules listed in settings.permissions.allow; unmatched actions keep the runtime default decision.",
        'Sensitive reads, writes outside the session CWD, installs, destructive commands, push, publish, and deploy remain reviewable requests.',
        'WebFetch stays reviewable because a static profile cannot safely distinguish every public target from private or credential-bearing URLs.',
        'Bash requests are classified by the Codex supervisor through claude-code-mcp; this profile does not implement a second shell parser.'
    )
} | ConvertTo-Json -Depth 12
