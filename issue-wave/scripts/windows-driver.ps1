# Bounded Windows foreground verifier, extracted from ahrefs/ocannl#671 evidence.
# Dot-source to use/test the functions without starting a process.
[CmdletBinding()]
param(
    [string] $ScriptPath,
    [string] $LogPath,
    [string] $ErrorPath,
    [ValidateRange(1, 2147483)] [int] $CapSeconds = 120,
    [string] $BashPath = 'C:/Program Files/Git/usr/bin/bash.exe'
)

function Get-WaveNativeExit($Process) {
    return $Process.ExitCode
}

function Resolve-WaveExit($Record, $NativeExit) {
    if ($Record -cnotmatch '^exit: ([0-9]{1,3})$') {
        throw 'no complete final verdict (expected exit: N)'
    }
    $recordedExit = [int] $Matches[1]
    if ($recordedExit -gt 255) { throw 'verdict outside Bash exit range 0..255' }
    if ($null -ne $NativeExit -and $NativeExit -ne $recordedExit) {
        throw 'process and recorded verdict disagree'
    }
    return $recordedExit
}

function Invoke-WaveWindowsDriver {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ScriptPath,
        [Parameter(Mandatory)] [string] $LogPath,
        [Parameter(Mandatory)] [string] $ErrorPath,
        [ValidateRange(1, 2147483)] [int] $CapSeconds = 120,
        [string] $BashPath = 'C:/Program Files/Git/usr/bin/bash.exe'
    )
    $ErrorActionPreference = 'Stop'
    $process = $null
    try {
        # Start-Process flattens ArgumentList on Windows. Quote the single script operand;
        # refuse embedded quotes/newlines rather than interpreting them as more arguments.
        if ($ScriptPath -match '["\r\n]' -or $ScriptPath.EndsWith('\')) {
            throw 'script path contains unsupported argument characters'
        }
        $out = [IO.Path]::GetFullPath($LogPath)
        $err = [IO.Path]::GetFullPath($ErrorPath)
        if ($out -eq $err) { throw 'stdout and stderr must have distinct paths' }
        # Fresh paths prevent stale verdicts and accidental overwrites of previous evidence.
        foreach ($path in @($out, $err)) {
            $file = [IO.File]::Open($path, [IO.FileMode]::CreateNew)
            $file.Dispose()
        }
        $process = Start-Process -FilePath $BashPath -ArgumentList @(
            '--noprofile', '--norc', '--', ('"' + $ScriptPath + '"')
        ) -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
        # Materialize and retain the handle BEFORE waiting: Windows PowerShell can otherwise
        # expose a null ExitCode after a fast child exits (the #671 false-success trigger).
        $handle = $process.Handle
        Write-Host "runner_pid=$($process.Id) cap_seconds=$CapSeconds"
        if (-not $process.WaitForExit($CapSeconds * 1000)) {
            & "$env:SystemRoot/System32/taskkill.exe" /PID $process.Id /T /F | Out-Host
            $killExit = $LASTEXITCODE
            if ($killExit -ne 0 -or -not $process.WaitForExit(10000)) {
                throw 'timeout cleanup not confirmed; retain execution reservation'
            }
            Write-Host 'TIMEOUT: owned process tree terminated'
            return 124
        }
        # Complete asynchronous redirected-output handling before reading the final line.
        $process.WaitForExit()
        $nativeExit = Get-WaveNativeExit $process
        Write-Host "runner_exit=$nativeExit has_exited=$($process.HasExited)"
        Get-Content -LiteralPath $out | Out-Host
        Get-Content -LiteralPath $err | Out-Host
        $record = Get-Content -LiteralPath $out -Tail 1
        return (Resolve-WaveExit $record $nativeExit)
    } catch {
        Write-Host "REFUSED: $_"
        # An error after launch must not abandon the process we own.
        if ($null -ne $process) {
            try {
                if (-not $process.HasExited) {
                    & "$env:SystemRoot/System32/taskkill.exe" /PID $process.Id /T /F | Out-Host
                    if ($LASTEXITCODE -ne 0 -or -not $process.WaitForExit(10000)) {
                        Write-Host 'REFUSED: cleanup unconfirmed; retain execution reservation'
                    }
                }
            } catch {
                Write-Host "REFUSED: cleanup unconfirmed; retain execution reservation: $_"
            }
        }
        return 2
    } finally {
        if ($null -ne $process) { $process.Dispose() }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        if (-not $ScriptPath -or -not $LogPath -or -not $ErrorPath) {
            throw 'ScriptPath, LogPath and ErrorPath are required'
        }
        exit (Invoke-WaveWindowsDriver @PSBoundParameters)
    } catch {
        Write-Host "REFUSED: $_"
        exit 2
    }
}
