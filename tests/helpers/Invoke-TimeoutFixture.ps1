[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('startup', 'idle', 'hard', 'hold')][string]$Mode,
    [string]$MarkerPath
)

$ErrorActionPreference = 'Stop'
switch ($Mode) {
    'startup' {
        Start-Sleep -Seconds 5
    }
    'idle' {
        Write-Output 'READY'
        Start-Sleep -Seconds 5
    }
    'hard' {
        if (-not [string]::IsNullOrWhiteSpace($MarkerPath)) {
            [IO.File]::AppendAllText($MarkerPath, "once`n", [Text.UTF8Encoding]::new($false))
        }
        for ($index = 0; $index -lt 50; $index++) {
            Write-Output "tick-$index"
            Start-Sleep -Milliseconds 200
        }
    }
    'hold' {
        Start-Sleep -Seconds 60
    }
}
