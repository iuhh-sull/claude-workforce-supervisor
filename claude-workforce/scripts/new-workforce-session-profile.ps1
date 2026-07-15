[CmdletBinding()]
param(
    [ValidateSet('settings', 'mcp')]
    [string]$Output = 'settings',
    [ValidateSet('minimal', 'user', 'project', 'full')]
    [string]$ContextProfile = 'project',
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

$askRules = @(
    'Bash', 'Edit', 'Write', 'NotebookEdit', 'WebFetch', 'Agent', 'Task'
) + $extraAskTools + $sensitiveReadRules
$allowRules = @(
    'Read', 'Glob', 'Grep', 'WebSearch', 'Plan', 'EnterPlanMode', 'ExitPlanMode'
) + $extraAllowTools
if ($AllowNestedAgents) {
    $askRules = @($askRules | Where-Object { $_ -notin @('Agent', 'Task') })
    $allowRules += @('Agent', 'Task')
}

$settings = [ordered]@{
    permissions = [ordered]@{
        disableBypassPermissionsMode = 'disable'
        disableAutoMode = 'disable'
        deny = @()
        ask = @($askRules | Select-Object -Unique)
        allow = @($allowRules | Select-Object -Unique)
    }
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
        'Writing, shell commands, public fetch targets, nested agents, sensitive reads, and unverified MCP calls remain reviewable requests.',
        'Bash requests are classified by the Codex supervisor through claude-code-mcp; this profile does not implement a second shell parser.'
    )
} | ConvertTo-Json -Depth 12
