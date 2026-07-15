function Get-WorkforceBrokerCapabilityPath {
    param([Parameter(Mandatory = $true)][string]$StateRoot)

    $paths = Get-WorkforceStatePaths -StateRoot $StateRoot
    return Join-Path $paths.broker_resources 'capabilities.json'
}

function Protect-WorkforceBrokerKey {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not $IsWindows) {
        try {
            & chmod 600 -- $Path
            return $LASTEXITCODE -eq 0
        }
        catch {
            return $false
        }
    }
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl = [Security.AccessControl.FileSecurity]::new()
        $acl.SetOwner($identity)
        $acl.SetAccessRuleProtection($true, $false)
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $identity,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $acl.AddAccessRule($rule)
        [IO.File]::SetAccessControl($Path, $acl)
        return Test-WorkforceBrokerKeyAcl -Path $Path
    }
    catch {
        return $false
    }
}

function Test-WorkforceBrokerKeyAcl {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    if (-not $IsWindows) {
        try {
            $mode = (& stat -c '%a' -- $Path 2>$null).Trim()
            return $mode -in @('400', '600')
        }
        catch {
            return $false
        }
    }
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl = [IO.File]::GetAccessControl($Path, [Security.AccessControl.AccessControlSections]::Access)
        foreach ($rule in @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))) {
            if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and $rule.IdentityReference -ne $identity) {
                return $false
            }
        }
        return $true
    }
    catch {
        return $false
    }
}

function Get-WorkforceBrokerKeyInfo {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [switch]$Create
    )

    $paths = Initialize-WorkforceState -StateRoot $StateRoot
    return Invoke-WorkforceStateTransaction -StateRoot $StateRoot -LockName 'broker-key' -ScriptBlock {
        if (-not (Test-Path -LiteralPath $paths.broker_key -PathType Leaf)) {
            if (-not $Create) {
                return [pscustomobject]@{ present = $false; acl_verified = $false; key = $null }
            }
            $key = [byte[]]::new(32)
            [Security.Cryptography.RandomNumberGenerator]::Fill($key)
            $temporaryPath = "$($paths.broker_key).$([guid]::NewGuid().ToString('N')).tmp"
            try {
                [IO.File]::WriteAllBytes($temporaryPath, $key)
                [IO.File]::Move($temporaryPath, $paths.broker_key, $false)
            }
            finally {
                if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
                    Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
                }
            }
            [void](Protect-WorkforceBrokerKey -Path $paths.broker_key)
        }
        $bytes = [IO.File]::ReadAllBytes($paths.broker_key)
        if ($bytes.Length -ne 32) {
            throw 'Workforce broker key has an invalid length.'
        }
        return [pscustomobject]@{
            present = $true
            acl_verified = Test-WorkforceBrokerKeyAcl -Path $paths.broker_key
            key = $bytes
        }
    }
}

function New-WorkforceResourceCapability {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$ManifestId,
        [string]$WorkerId,
        [string]$SessionId,
        [ValidateRange(30, 86400)][int]$TtlSeconds = 3600
    )

    [void](Get-WorkforceBrokerKeyInfo -StateRoot $StateRoot -Create)
    $tokenBytes = [byte[]]::new(32)
    [Security.Cryptography.RandomNumberGenerator]::Fill($tokenBytes)
    $token = ([Convert]::ToHexString($tokenBytes)).ToLowerInvariant()
    $tokenHash = Get-WorkforceStateHash -Text $token
    $capabilityPath = Get-WorkforceBrokerCapabilityPath -StateRoot $StateRoot
    $now = Get-WorkforceUtcNow
    Update-WorkforceState -StateRoot $StateRoot -LockName 'broker-capabilities' -Path $capabilityPath -DefaultValue @() -UpdateScript {
        param($records)
        $active = @($records | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_.expires_at) -and [DateTimeOffset]::Parse([string]$_.expires_at) -gt $now
        })
        $active += [pscustomobject][ordered]@{
            schema_version = 2
            capability_id = [guid]::NewGuid().ToString('N')
            token_hash = $tokenHash
            manifest_id = $ManifestId
            worker_id = $WorkerId
            session_id = $SessionId
            supervisor_pid = $PID
            created_at = $now.ToString('o')
            expires_at = $now.AddSeconds($TtlSeconds).ToString('o')
        }
        return @($active)
    } | Out-Null
    return [pscustomobject]@{
        token = $token
        token_hash = $tokenHash
        manifest_id = $ManifestId
        expires_at = $now.AddSeconds($TtlSeconds).ToString('o')
    }
}

function Test-WorkforceResourceCapability {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$ManifestId,
        [string]$WorkerId,
        [string]$SessionId
    )

    if ($Token -notmatch '^[a-fA-F0-9]{64}$') {
        return [pscustomobject]@{ verified = $false; reason = 'token-invalid'; record = $null }
    }
    $path = Get-WorkforceBrokerCapabilityPath -StateRoot $StateRoot
    $records = @(Read-WorkforceState -Path $path -DefaultValue @() -RestoreFromBackup)
    $hash = Get-WorkforceStateHash -Text $Token.ToLowerInvariant()
    $now = Get-WorkforceUtcNow
    $record = @($records | Where-Object {
        [string]$_.token_hash -eq $hash -and
        [string]$_.manifest_id -eq $ManifestId -and
        ([string]::IsNullOrWhiteSpace($WorkerId) -or [string]$_.worker_id -eq $WorkerId) -and
        ([string]::IsNullOrWhiteSpace($SessionId) -or [string]$_.session_id -eq $SessionId) -and
        [DateTimeOffset]::Parse([string]$_.expires_at) -gt $now
    }) | Select-Object -First 1
    if ($null -eq $record) {
        return [pscustomobject]@{ verified = $false; reason = 'token-mismatch-or-expired'; record = $null }
    }
    return [pscustomobject]@{ verified = $true; reason = 'matched'; record = $record }
}

function Get-WorkforceParentProcessId {
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    if ($IsWindows) {
        try {
            $record = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop
            return [int]$record.ParentProcessId
        }
        catch {}
        if ($null -eq ('ClaudeWorkforce.NativeProcessSnapshot' -as [type])) {
            try {
                Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace ClaudeWorkforce {
    public static class NativeProcessSnapshot {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct PROCESSENTRY32 {
            public uint dwSize;
            public uint cntUsage;
            public uint th32ProcessID;
            public IntPtr th32DefaultHeapID;
            public uint th32ModuleID;
            public uint cntThreads;
            public uint th32ParentProcessID;
            public int pcPriClassBase;
            public uint dwFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
            public string szExeFile;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool Process32FirstW(IntPtr snapshot, ref PROCESSENTRY32 entry);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool Process32NextW(IntPtr snapshot, ref PROCESSENTRY32 entry);

        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);

        public static int GetParentProcessId(int processId) {
            IntPtr snapshot = CreateToolhelp32Snapshot(2, 0);
            if (snapshot == new IntPtr(-1)) return 0;
            try {
                PROCESSENTRY32 entry = new PROCESSENTRY32();
                entry.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32));
                if (!Process32FirstW(snapshot, ref entry)) return 0;
                do {
                    if (entry.th32ProcessID == (uint)processId) return (int)entry.th32ParentProcessID;
                } while (Process32NextW(snapshot, ref entry));
                return 0;
            }
            finally {
                CloseHandle(snapshot);
            }
        }
    }
}
'@ -ErrorAction Stop
            }
            catch {
                if ($null -eq ('ClaudeWorkforce.NativeProcessSnapshot' -as [type])) {
                    return 0
                }
            }
        }
        return [ClaudeWorkforce.NativeProcessSnapshot]::GetParentProcessId($ProcessId)
    }
    try {
        $stat = [IO.File]::ReadAllText("/proc/$ProcessId/stat", [Text.Encoding]::UTF8)
        $rightParen = $stat.LastIndexOf(')')
        if ($rightParen -lt 0) {
            return 0
        }
        $fields = $stat.Substring($rightParen + 2).Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
        return [int]$fields[1]
    }
    catch {
        return 0
    }
}

function Test-WorkforceProcessDescendant {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [Parameter(Mandatory = $true)][int]$AncestorProcessId
    )

    if ($ProcessId -le 0 -or $AncestorProcessId -le 0) {
        return $false
    }
    $current = $ProcessId
    $visited = [Collections.Generic.HashSet[int]]::new()
    for ($depth = 0; $depth -lt 64 -and $current -gt 0; $depth++) {
        if ($current -eq $AncestorProcessId) {
            return $true
        }
        if (-not $visited.Add($current)) {
            return $false
        }
        $current = Get-WorkforceParentProcessId -ProcessId $current
    }
    return $false
}

function ConvertTo-WorkforceBrokerTimestampText {
    param([Parameter(Mandatory = $true)][AllowNull()]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return ''
    }

    try {
        $timestamp = if ($Value -is [DateTimeOffset]) {
            [DateTimeOffset]$Value
        }
        elseif ($Value -is [DateTime]) {
            [DateTimeOffset]::new([DateTime]$Value)
        }
        else {
            [DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture)
        }
        return $timestamp.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
    catch {
        return [string]$Value
    }
}

function Get-WorkforceBrokerSignatureText {
    param([Parameter(Mandatory = $true)]$Resource)

    return @(
        [string]$Resource.schema_version,
        [string]$Resource.manifest_id,
        [string]$Resource.resource_id,
        [string]$Resource.type,
        [string]$Resource.worker_id,
        [string]$Resource.session_id,
        [string]$Resource.pid,
        (ConvertTo-WorkforceBrokerTimestampText -Value $Resource.process_start_time),
        [string]$Resource.executable,
        [string]$Resource.executable_path_hash,
        [string]$Resource.parent_pid,
        [string]$Resource.ownership_method,
        (ConvertTo-WorkforceBrokerTimestampText -Value $Resource.broker_verified_at),
        $(if ([bool]$Resource.broker_key_acl_verified) { 'true' } else { 'false' }),
        [string]$Resource.purpose,
        $(if ([bool]$Resource.persistent) { 'true' } else { 'false' }),
        (ConvertTo-WorkforceBrokerTimestampText -Value $Resource.expires_at),
        [string]$Resource.stop_strategy.type,
        [string]$Resource.stop_strategy.grace_seconds,
        [string]$Resource.transport,
        [string]$Resource.endpoint_fingerprint,
        [string]$Resource.process_resource_id
    ) -join "`n"
}

function Get-WorkforceBrokerSignature {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Key,
        [Parameter(Mandatory = $true)]$Resource
    )

    $hmac = [Security.Cryptography.HMACSHA256]::new($Key)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes((Get-WorkforceBrokerSignatureText -Resource $Resource))
        return ([Convert]::ToHexString($hmac.ComputeHash($bytes))).ToLowerInvariant()
    }
    finally {
        $hmac.Dispose()
    }
}

function Get-WorkforcePortLeaseSignature {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Key,
        [Parameter(Mandatory = $true)]$Lease
    )

    $text = @(
        [string]$Lease.schema_version,
        [string]$Lease.lease_id,
        [string]$Lease.manifest_id,
        [string]$Lease.resource_id,
        [string]$Lease.port,
        [string]$Lease.protocol,
        [string]$Lease.pid,
        (ConvertTo-WorkforceBrokerTimestampText -Value $Lease.process_start_time),
        [string]$Lease.session_id,
        [string]$Lease.worker_id,
        [string]$Lease.state,
        [string]$Lease.purpose,
        $(if ([bool]$Lease.persistent) { 'true' } else { 'false' }),
        [string]$Lease.ownership_fingerprint,
        (ConvertTo-WorkforceBrokerTimestampText -Value $Lease.created_at),
        (ConvertTo-WorkforceBrokerTimestampText -Value $Lease.bound_at),
        (ConvertTo-WorkforceBrokerTimestampText -Value $Lease.released_at),
        (ConvertTo-WorkforceBrokerTimestampText -Value $Lease.expires_at)
    ) -join "`n"
    $hmac = [Security.Cryptography.HMACSHA256]::new($Key)
    try {
        return ([Convert]::ToHexString($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).ToLowerInvariant()
    }
    finally {
        $hmac.Dispose()
    }
}

function Test-WorkforcePortLeaseSignature {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)]$Lease
    )

    $keyInfo = Get-WorkforceBrokerKeyInfo -StateRoot $StateRoot
    if (-not $keyInfo.present) {
        return [pscustomobject]@{ verified = $false; reason = 'broker-key-missing' }
    }
    if ([string]$Lease.broker_signature -notmatch '^[0-9a-fA-F]{64}$') {
        return [pscustomobject]@{ verified = $false; reason = 'port-signature-invalid' }
    }
    $expected = Get-WorkforcePortLeaseSignature -Key $keyInfo.key -Lease $Lease
    $verified = [Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
        [Text.Encoding]::ASCII.GetBytes($expected),
        [Text.Encoding]::ASCII.GetBytes(([string]$Lease.broker_signature).ToLowerInvariant())
    )
    return [pscustomobject]@{ verified = [bool]$verified; reason = $(if ($verified) { 'matched' } else { 'port-signature-invalid' }) }
}

function Register-WorkforceProcess {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$ManifestId,
        [Parameter(Mandatory = $true)][string]$WorkerId,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$CapabilityToken,
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [string]$Purpose = 'workforce-process',
        [switch]$Persistent,
        [ValidateRange(1, 604800)][int]$TtlSeconds = 3600,
        [ValidateSet('process-handle', 'ctrl-c', 'ctrl-break', 'stdin-close', 'command', 'http-shutdown', 'job-object', 'kill-tree')][string]$StopStrategy = 'process-handle',
        [ValidateRange(0, 300)][int]$GraceSeconds = 10
    )

    $capability = Test-WorkforceResourceCapability -StateRoot $StateRoot -Token $CapabilityToken -ManifestId $ManifestId -WorkerId $WorkerId -SessionId $SessionId
    if (-not $capability.verified) {
        throw "resource-registration-denied: $($capability.reason)"
    }
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        throw 'resource-registration-denied: process-not-running'
    }
    try {
        $processPath = [string]$process.Path
        if ([string]::IsNullOrWhiteSpace($processPath) -or -not (Test-Path -LiteralPath $processPath -PathType Leaf)) {
            throw 'resource-registration-denied: executable-path-unavailable'
        }
        $rootPid = Get-WorkforceParentProcessId -ProcessId $PID
        if ($rootPid -le 0) {
            throw 'resource-registration-denied: registration-root-unavailable'
        }
        if (-not (Test-WorkforceProcessDescendant -ProcessId $ProcessId -AncestorProcessId $rootPid)) {
            throw 'resource-registration-denied: non-descendant-process'
        }
        $keyInfo = Get-WorkforceBrokerKeyInfo -StateRoot $StateRoot -Create
        $now = Get-WorkforceUtcNow
        $resource = [pscustomobject][ordered]@{
            schema_version = 2
            resource_id = [guid]::NewGuid().ToString('N')
            type = 'process'
            manifest_id = $ManifestId
            worker_id = $WorkerId
            session_id = $SessionId
            pid = $ProcessId
            process_start_time = $process.StartTime.ToUniversalTime().ToString('o')
            executable = [IO.Path]::GetFileName($processPath)
            executable_path_hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $processPath).Hash.ToLowerInvariant()
            parent_pid = Get-WorkforceParentProcessId -ProcessId $ProcessId
            ownership_method = 'registered-token-descendant'
            broker_verified_at = $now.ToString('o')
            broker_signature = $null
            broker_key_acl_verified = [bool]$keyInfo.acl_verified
            purpose = $Purpose
            persistent = [bool]$Persistent
            expires_at = $now.AddSeconds($TtlSeconds).ToString('o')
            stop_strategy = [pscustomobject]@{
                type = $StopStrategy
                grace_seconds = $GraceSeconds
            }
        }
        $resource.broker_signature = Get-WorkforceBrokerSignature -Key $keyInfo.key -Resource $resource
        $paths = Get-WorkforceStatePaths -StateRoot $StateRoot
        $resourcePath = Join-Path $paths.broker_resources "$($resource.resource_id).json"
        Invoke-WorkforceStateTransaction -StateRoot $StateRoot -LockName "broker-$($resource.resource_id)" -ScriptBlock {
            Write-WorkforceState -Path $resourcePath -Value $resource
        } | Out-Null
        Update-WorkforceMetrics -StateRoot $StateRoot -Changes @{ owned_processes_started = 1 } | Out-Null
        return $resource
    }
    finally {
        $process.Dispose()
    }
}

function Get-WorkforceOwnedResources {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [string]$ManifestId
    )

    $paths = Initialize-WorkforceState -StateRoot $StateRoot
    $resources = foreach ($file in @(Get-ChildItem -LiteralPath $paths.broker_resources -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        if ($file.Name -eq 'capabilities.json') {
            continue
        }
        try {
            Read-WorkforceState -Path $file.FullName -DefaultValue $null -RestoreFromBackup
        }
        catch {
            [pscustomobject]@{ resource_id = [IO.Path]::GetFileNameWithoutExtension($file.Name); type = 'corrupt'; broker_signature = $null }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($ManifestId)) {
        $resources = @($resources | Where-Object { [string]$_.manifest_id -eq $ManifestId })
    }
    return @($resources)
}

function Test-WorkforceResourceOwnership {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)]$Resource,
        [string]$ExpectedManifestId,
        [string]$ExpectedWorkerId,
        [string]$ExpectedSessionId,
        [switch]$RequireForceCleanupTrust
    )

    $keyInfo = Get-WorkforceBrokerKeyInfo -StateRoot $StateRoot
    if (-not $keyInfo.present) {
        return [pscustomobject]@{ verified = $false; running = $true; reason = 'broker-key-missing'; process = $null }
    }
    if ($RequireForceCleanupTrust -and -not $keyInfo.acl_verified) {
        return [pscustomobject]@{ verified = $false; running = $true; reason = 'broker-key-acl-unverified'; process = $null }
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedManifestId) -and [string]$Resource.manifest_id -ne $ExpectedManifestId) {
        return [pscustomobject]@{ verified = $false; running = $true; reason = 'manifest-mismatch'; process = $null }
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedWorkerId) -and [string]$Resource.worker_id -ne $ExpectedWorkerId) {
        return [pscustomobject]@{ verified = $false; running = $true; reason = 'worker-mismatch'; process = $null }
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSessionId) -and [string]$Resource.session_id -ne $ExpectedSessionId) {
        return [pscustomobject]@{ verified = $false; running = $true; reason = 'session-mismatch'; process = $null }
    }
    $expectedSignature = Get-WorkforceBrokerSignature -Key $keyInfo.key -Resource $Resource
    if ([string]$Resource.broker_signature -notmatch '^[0-9a-fA-F]{64}$' -or -not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
        [Text.Encoding]::ASCII.GetBytes($expectedSignature),
        [Text.Encoding]::ASCII.GetBytes(([string]$Resource.broker_signature).ToLowerInvariant())
    )) {
        return [pscustomobject]@{ verified = $false; running = $true; reason = 'broker-signature-invalid'; process = $null }
    }
    if ([string]$Resource.type -ne 'process' -or [int]$Resource.pid -le 0) {
        return [pscustomobject]@{ verified = $true; running = $false; reason = 'signed-nonprocess-resource'; process = $null }
    }
    $process = Get-Process -Id ([int]$Resource.pid) -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        return [pscustomobject]@{ verified = $true; running = $false; reason = 'not-running'; process = $null }
    }
    try {
        $actualStart = $process.StartTime.ToUniversalTime()
        $expectedStart = [DateTimeOffset]::Parse((ConvertTo-WorkforceBrokerTimestampText -Value $Resource.process_start_time), [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
        if ([math]::Abs(($actualStart - $expectedStart).TotalSeconds) -gt 1) {
            return [pscustomobject]@{ verified = $false; running = $true; reason = 'pid-reused'; process = $process }
        }
        $processPath = [string]$process.Path
        if ([string]::IsNullOrWhiteSpace($processPath) -or -not (Test-Path -LiteralPath $processPath -PathType Leaf)) {
            return [pscustomobject]@{ verified = $false; running = $true; reason = 'executable-path-unavailable'; process = $process }
        }
        $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $processPath).Hash.ToLowerInvariant()
        if ($actualHash -ne [string]$Resource.executable_path_hash) {
            return [pscustomobject]@{ verified = $false; running = $true; reason = 'executable-mismatch'; process = $process }
        }
        return [pscustomobject]@{ verified = $true; running = $true; reason = 'matched'; process = $process }
    }
    catch {
        return [pscustomobject]@{ verified = $false; running = $true; reason = 'process-identity-unavailable'; process = $process }
    }
}

function Stop-WorkforceOwnedResource {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)]$Resource,
        [string]$ExpectedManifestId,
        [string]$ExpectedWorkerId,
        [string]$ExpectedSessionId,
        [switch]$Force
    )

    $ownership = Test-WorkforceResourceOwnership -StateRoot $StateRoot -Resource $Resource -ExpectedManifestId $ExpectedManifestId -ExpectedWorkerId $ExpectedWorkerId -ExpectedSessionId $ExpectedSessionId
    $result = [ordered]@{
        resource_id = [string]$Resource.resource_id
        graceful_attempted = $false
        graceful_strategy = [string]$Resource.stop_strategy.type
        graceful_succeeded = $false
        force_attempted = $false
        force_succeeded = $false
        verified_stopped = -not [bool]$ownership.running
        cleanup_error = $null
    }
    if (-not $ownership.running) {
        return [pscustomobject]$result
    }
    if (-not $ownership.verified) {
        $result.cleanup_error = $ownership.reason
        return [pscustomobject]$result
    }
    $keyInfo = Get-WorkforceBrokerKeyInfo -StateRoot $StateRoot
    if (-not $keyInfo.present -or -not $keyInfo.acl_verified) {
        $result.cleanup_error = 'broker-key-acl-unverified'
        if ($null -ne $ownership.process) { $ownership.process.Dispose() }
        return [pscustomobject]$result
    }
    $process = $ownership.process
    try {
        $strategy = [string]$Resource.stop_strategy.type
        $graceSeconds = [int]$Resource.stop_strategy.grace_seconds
        switch ($strategy) {
            'process-handle' {
                $result.graceful_attempted = $true
                [void]$process.CloseMainWindow()
                if ($graceSeconds -gt 0) {
                    [void]$process.WaitForExit($graceSeconds * 1000)
                }
                $result.graceful_succeeded = $process.HasExited
            }
            'kill-tree' {
                $result.cleanup_error = 'force-required'
            }
            default {
                $result.cleanup_error = "graceful-strategy-unavailable:$strategy"
            }
        }
        if (-not $process.HasExited -and $Force) {
            $result.force_attempted = $true
            $process.Kill($true)
            [void]$process.WaitForExit(5000)
            $result.force_succeeded = $process.HasExited
        }
        $result.verified_stopped = $process.HasExited
        if ($result.verified_stopped) {
            $result.cleanup_error = $null
        }
        elseif ([string]::IsNullOrWhiteSpace([string]$result.cleanup_error)) {
            $result.cleanup_error = if ($Force) { 'force-stop-failed' } else { 'graceful-timeout' }
        }
        return [pscustomobject]$result
    }
    catch {
        $result.cleanup_error = 'process-stop-failed'
        return [pscustomobject]$result
    }
    finally {
        $process.Dispose()
    }
}

function Unregister-WorkforceResource {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$ResourceId,
        [Parameter(Mandatory = $true)][string]$ManifestId,
        [Parameter(Mandatory = $true)][string]$CapabilityToken
    )

    if ($ResourceId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') {
        throw 'resource-unregister-denied: invalid-resource-id'
    }
    $paths = Get-WorkforceStatePaths -StateRoot $StateRoot
    $path = Join-Path $paths.broker_resources "$ResourceId.json"
    return Invoke-WorkforceStateTransaction -StateRoot $StateRoot -LockName "broker-$ResourceId" -ScriptBlock {
        $capability = Test-WorkforceResourceCapability -StateRoot $StateRoot -Token $CapabilityToken -ManifestId $ManifestId
        if (-not $capability.verified) {
            throw "resource-unregister-denied: $($capability.reason)"
        }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            return $false
        }
        $resource = Read-WorkforceState -Path $path -DefaultValue $null -RestoreFromBackup
        if ($null -eq $resource) {
            throw 'resource-unregister-denied: resource-unreadable'
        }
        $ownership = Test-WorkforceResourceOwnership `
            -StateRoot $StateRoot `
            -Resource $resource `
            -ExpectedManifestId $ManifestId `
            -ExpectedWorkerId ([string]$capability.record.worker_id) `
            -ExpectedSessionId ([string]$capability.record.session_id)
        if (-not $ownership.verified) {
            throw "resource-unregister-denied: $($ownership.reason)"
        }
        Remove-Item -LiteralPath $path -Force
        return $true
    }
}

function Register-WorkforcePort {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$ManifestId,
        [Parameter(Mandatory = $true)][string]$WorkerId,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$CapabilityToken,
        [Parameter(Mandatory = $true)][string]$ResourceId,
        [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$Port,
        [ValidateSet('tcp', 'udp')][string]$Protocol = 'tcp',
        [string]$Purpose = 'workforce-port',
        [ValidateRange(1, 604800)][int]$TtlSeconds = 3600
    )

    $capability = Test-WorkforceResourceCapability -StateRoot $StateRoot -Token $CapabilityToken -ManifestId $ManifestId -WorkerId $WorkerId -SessionId $SessionId
    if (-not $capability.verified) {
        throw "port-registration-denied: $($capability.reason)"
    }
    $resource = @(Get-WorkforceOwnedResources -StateRoot $StateRoot -ManifestId $ManifestId | Where-Object { [string]$_.resource_id -eq $ResourceId }) | Select-Object -First 1
    if ($null -eq $resource) {
        throw 'port-registration-denied: resource-not-found'
    }
    $ownership = Test-WorkforceResourceOwnership -StateRoot $StateRoot -Resource $resource -ExpectedManifestId $ManifestId -ExpectedWorkerId $WorkerId -ExpectedSessionId $SessionId
    if (-not $ownership.verified -or -not $ownership.running) {
        throw "port-registration-denied: $($ownership.reason)"
    }
    if ((Test-WorkforcePortListening -Port $Port -Protocol $Protocol) -ne $true) {
        throw 'port-registration-denied: port-not-listening'
    }
    $ownerQuery = Get-WorkforcePortOwnerProcessIds -Port $Port -Protocol $Protocol
    if (-not $ownerQuery.verified) {
        throw "port-registration-denied: $($ownerQuery.reason)"
    }
    if ([int]$resource.pid -notin @($ownerQuery.process_ids)) {
        throw 'port-registration-denied: listener-pid-mismatch'
    }
    $lease = Add-WorkforcePortLease -StateRoot $StateRoot -Port $Port -Protocol $Protocol -SessionId $SessionId -WorkerId $WorkerId -Purpose $Purpose -ProcessId ([int]$resource.pid) -ProcessStartTime (ConvertTo-WorkforceBrokerTimestampText -Value $resource.process_start_time) -TtlSeconds $TtlSeconds -ManifestId $ManifestId -ResourceId $ResourceId -AllowOwnedListener
    $paths = Get-WorkforceStatePaths -StateRoot $StateRoot
    $keyInfo = Get-WorkforceBrokerKeyInfo -StateRoot $StateRoot
    $boundAt = (Get-WorkforceUtcNow).ToString('o')
    $lease.state = 'bound'
    $lease.bound_at = $boundAt
    $lease.broker_signature = Get-WorkforcePortLeaseSignature -Key $keyInfo.key -Lease $lease
    Update-WorkforceState -StateRoot $StateRoot -LockName 'port-leases' -Path $paths.port_leases -DefaultValue @() -UpdateScript {
        param($leases)
        foreach ($candidate in @($leases)) {
            if ([string]$candidate.lease_id -eq [string]$lease.lease_id) {
                $candidate.state = 'bound'
                $candidate.bound_at = $boundAt
                $candidate.broker_signature = $lease.broker_signature
            }
        }
        return @($leases)
    } | Out-Null
    return $lease
}

function Register-WorkforceMcpEndpoint {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$ManifestId,
        [Parameter(Mandatory = $true)][string]$WorkerId,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$CapabilityToken,
        [Parameter(Mandatory = $true)][string]$Transport,
        [string]$EndpointFingerprint,
        [Parameter(Mandatory = $true)][string]$ProcessResourceId
    )

    $capability = Test-WorkforceResourceCapability -StateRoot $StateRoot -Token $CapabilityToken -ManifestId $ManifestId -WorkerId $WorkerId -SessionId $SessionId
    if (-not $capability.verified) {
        throw "mcp-registration-denied: $($capability.reason)"
    }
    $processResource = @(Get-WorkforceOwnedResources -StateRoot $StateRoot -ManifestId $ManifestId | Where-Object {
        [string]$_.resource_id -eq $ProcessResourceId -and [string]$_.type -eq 'process'
    }) | Select-Object -First 1
    if ($null -eq $processResource) {
        throw 'mcp-registration-denied: process-resource-not-found'
    }
    $processOwnership = Test-WorkforceResourceOwnership -StateRoot $StateRoot -Resource $processResource -ExpectedManifestId $ManifestId -ExpectedWorkerId $WorkerId -ExpectedSessionId $SessionId
    if (-not $processOwnership.verified -or -not $processOwnership.running) {
        throw "mcp-registration-denied: $($processOwnership.reason)"
    }
    $keyInfo = Get-WorkforceBrokerKeyInfo -StateRoot $StateRoot -Create
    $resource = [pscustomobject][ordered]@{
        schema_version = 2
        resource_id = [guid]::NewGuid().ToString('N')
        type = 'mcp'
        manifest_id = $ManifestId
        worker_id = $WorkerId
        session_id = $SessionId
        pid = 0
        process_start_time = ''
        executable_path_hash = ''
        parent_pid = 0
        ownership_method = 'registered-token'
        broker_verified_at = (Get-WorkforceUtcNow).ToString('o')
        broker_signature = $null
        broker_key_acl_verified = [bool]$keyInfo.acl_verified
        transport = $Transport
        endpoint_fingerprint = $EndpointFingerprint
        process_resource_id = $ProcessResourceId
        persistent = $false
        stop_strategy = [pscustomobject]@{ type = 'process-handle'; grace_seconds = 10 }
    }
    $resource.broker_signature = Get-WorkforceBrokerSignature -Key $keyInfo.key -Resource $resource
    $paths = Get-WorkforceStatePaths -StateRoot $StateRoot
    Invoke-WorkforceStateTransaction -StateRoot $StateRoot -LockName "broker-$($resource.resource_id)" -ScriptBlock {
        Write-WorkforceState -Path (Join-Path $paths.broker_resources "$($resource.resource_id).json") -Value $resource
    } | Out-Null
    return $resource
}
