$script:WorkforceStateLocks = @{}

function Get-WorkforceStateHash {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $hash = [Security.Cryptography.SHA256]::HashData($bytes)
    return ([Convert]::ToHexString($hash)).ToLowerInvariant()
}

function Get-WorkforceStateLockKey {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$LockName
    )

    $root = [IO.Path]::GetFullPath($StateRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ($IsWindows) {
        $root = $root.ToLowerInvariant()
    }
    return "$root`n$LockName"
}

function Enter-WorkforceStateLock {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9._-]+$')][string]$LockName,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 15
    )

    $key = Get-WorkforceStateLockKey -StateRoot $StateRoot -LockName $LockName
    if ($script:WorkforceStateLocks.ContainsKey($key)) {
        $entry = $script:WorkforceStateLocks[$key]
        $entry.depth = [int]$entry.depth + 1
        return [pscustomobject]@{
            key = $key
            name = $entry.name
            recovered = [bool]$entry.recovered
            reentrant = $true
        }
    }

    $rootHash = (Get-WorkforceStateHash -Text ([IO.Path]::GetFullPath($StateRoot))).Substring(0, 24)
    $lockHash = (Get-WorkforceStateHash -Text $LockName).Substring(0, 16)
    $mutexName = "Local\ClaudeWorkforce-$rootHash-$lockHash"
    $mutex = [Threading.Mutex]::new($false, $mutexName)
    $acquired = $false
    $recovered = $false
    try {
        try {
            $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
        }
        catch [Threading.AbandonedMutexException] {
            $acquired = $true
            $recovered = $true
        }
        if (-not $acquired) {
            throw "state-lock-timeout: $LockName"
        }
        $script:WorkforceStateLocks[$key] = [pscustomobject]@{
            name = $mutexName
            mutex = $mutex
            depth = 1
            recovered = $recovered
        }
        return [pscustomobject]@{
            key = $key
            name = $mutexName
            recovered = $recovered
            reentrant = $false
        }
    }
    catch {
        if (-not $acquired) {
            $mutex.Dispose()
        }
        throw
    }
}

function Exit-WorkforceStateLock {
    param([Parameter(Mandatory = $true)]$Lock)

    $key = [string]$Lock.key
    if (-not $script:WorkforceStateLocks.ContainsKey($key)) {
        throw 'Workforce state lock is not held by this process.'
    }
    $entry = $script:WorkforceStateLocks[$key]
    $entry.depth = [int]$entry.depth - 1
    if ([int]$entry.depth -gt 0) {
        return
    }
    try {
        $entry.mutex.ReleaseMutex()
    }
    finally {
        $entry.mutex.Dispose()
        [void]$script:WorkforceStateLocks.Remove($key)
    }
}

function Invoke-WorkforceStateTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9._-]+$')][string]$LockName,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 15
    )

    $migrationLock = $null
    if ($LockName -ne 'state-migration-gate') {
        $migrationLock = Enter-WorkforceStateLock -StateRoot $StateRoot -LockName 'state-migration-gate' -TimeoutSeconds $TimeoutSeconds
    }
    $lock = $null
    try {
        $lock = Enter-WorkforceStateLock -StateRoot $StateRoot -LockName $LockName -TimeoutSeconds $TimeoutSeconds
        return & $ScriptBlock $lock
    }
    finally {
        if ($null -ne $lock) {
            Exit-WorkforceStateLock -Lock $lock
        }
        if ($null -ne $migrationLock) {
            Exit-WorkforceStateLock -Lock $migrationLock
        }
    }
}

function Read-WorkforceState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowNull()]$DefaultValue,
        [switch]$RestoreFromBackup
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $DefaultValue
    }
    try {
        $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($text)) {
            return $DefaultValue
        }
        return $text | ConvertFrom-Json -Depth 30 -ErrorAction Stop
    }
    catch {
        $backupPath = "$Path.bak"
        if ($RestoreFromBackup -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
            try {
                $backupText = [IO.File]::ReadAllText($backupPath, [Text.Encoding]::UTF8)
                $backupValue = $backupText | ConvertFrom-Json -Depth 30 -ErrorAction Stop
                Write-WorkforceState -Path $Path -Value $backupValue -SkipBackup
                return $backupValue
            }
            catch {
                throw "Workforce state JSON and backup are invalid: $Path"
            }
        }
        throw "Workforce state JSON is invalid: $Path"
    }
}

function Write-WorkforceState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowNull()]$Value,
        [switch]$SkipBackup
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
    $json = ConvertTo-Json -InputObject $Value -Depth 30
    $temporaryPath = Join-Path $directory ".$([IO.Path]::GetFileName($Path)).$([guid]::NewGuid().ToString('N')).tmp"
    $backupPath = "$Path.bak"
    try {
        [IO.File]::WriteAllText($temporaryPath, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        if (-not $SkipBackup -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
            [IO.File]::Copy($Path, $backupPath, $true)
        }
        [IO.File]::Move($temporaryPath, $Path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Update-WorkforceState {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$LockName,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowNull()]$DefaultValue,
        [Parameter(Mandatory = $true)][scriptblock]$UpdateScript,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 15
    )

    return Invoke-WorkforceStateTransaction -StateRoot $StateRoot -LockName $LockName -TimeoutSeconds $TimeoutSeconds -ScriptBlock {
        param($lock)
        $current = Read-WorkforceState -Path $Path -DefaultValue $DefaultValue -RestoreFromBackup
        $updated = & $UpdateScript $current $lock
        Write-WorkforceState -Path $Path -Value $updated
        return $updated
    }
}
