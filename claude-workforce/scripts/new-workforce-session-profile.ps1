[CmdletBinding()]
param(
    [ValidateSet('settings', 'mcp')]
    [string]$Output = 'settings',
    [ValidateSet('minimal', 'user', 'project', 'full')]
    [string]$ContextProfile = 'project',
    [switch]$AllowNestedAgents
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
$askRules = @(
    'Bash', 'Edit', 'Write', 'NotebookEdit', 'WebFetch', 'Agent', 'Task',
    'mcp__plugin_exa_exa__web_fetch_exa',
    'mcp__tavily__tavily_crawl', 'mcp__tavily__tavily_extract',
    'mcp__tavily__tavily_map',
    'mcp__plugin_context-mode_context-mode__ctx_fetch_and_index',
    'mcp__plugin_context-mode_context-mode__ctx_execute',
    'mcp__plugin_context-mode_context-mode__ctx_execute_file',
    'mcp__plugin_context-mode_context-mode__ctx_batch_execute'
) + $sensitiveReadRules
$allowRules = @(
    'Read', 'Glob', 'Grep', 'WebSearch', 'Plan', 'EnterPlanMode', 'ExitPlanMode',
    'mcp__plugin_exa_exa__web_search_exa',
    'mcp__tavily__tavily_research', 'mcp__tavily__tavily_search',
    'mcp__plugin_context-mode_context-mode__ctx_search'
)
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
