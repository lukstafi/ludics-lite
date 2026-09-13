# Run on native Windows under both Windows PowerShell 5.1 and PowerShell 7.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/windows-driver.ps1"
$root = Join-Path ([IO.Path]::GetTempPath()) ('wave driver ' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $root | Out-Null
$engine = (Get-Process -Id $PID).Path
$driver = Join-Path $PSScriptRoot 'windows-driver.ps1'
$bash = 'C:/Program Files/Git/usr/bin/bash.exe'
$count = 0
function Assert-Equal($Name, $Got, $Want) {
    if ($Got -ne $Want) { throw "$Name got=$Got want=$Want" }
    Write-Host "PASS: $Name"
}
function Run-Case($Name, $Body, $Want, [switch] $NullExit, [int] $Cap = 10) {
    $script:count++
    $stem = Join-Path $root "$script:count"
    $scriptPath = "$stem inner.sh"
    [IO.File]::WriteAllText($scriptPath, $Body.Replace("`r`n", "`n"))
    # Git Bash understands Windows forward-slash paths; spaces exercise argument quoting.
    $scriptPath = $scriptPath.Replace('\', '/')
    if ($NullExit) {
        $loader = "$stem loader.ps1"
        $text = ". '$($driver.Replace("'", "''"))'`n" +
            "function Get-WaveNativeExit(`$Process) { return `$null }`n" +
            "exit (Invoke-WaveWindowsDriver -ScriptPath '$($scriptPath.Replace("'", "''"))' " +
            "-LogPath '$stem.log' -ErrorPath '$stem.err' -CapSeconds $Cap)`n"
        [IO.File]::WriteAllText($loader, $text)
        & $engine -NoProfile -ExecutionPolicy Bypass -File $loader
    } else {
        & $engine -NoProfile -ExecutionPolicy Bypass -File $driver -ScriptPath $scriptPath `
            -LogPath "$stem.log" -ErrorPath "$stem.err" -CapSeconds $Cap -BashPath $bash
    }
    Assert-Equal $Name $LASTEXITCODE $Want
}
try {
    Assert-Equal 'null native success needs sentinel' (Resolve-WaveExit 'exit: 0' $null) 0
    Assert-Equal 'null native failure stays failure' (Resolve-WaveExit 'exit: 7' $null) 7
    foreach ($case in @(@('exit: 0', 7), @('exit: 7', 0), @('', $null),
        @('exit: 256', $null), @('exit: 999999999999', $null), @('EXIT: 0', $null))) {
        $refused = $false
        try { $null = Resolve-WaveExit $case[0] $case[1] } catch { $refused = $true }
        Assert-Equal "refuse record=$($case[0]) native=$($case[1])" $refused $true
    }
    # Deterministically model delayed output draining after the timed wait returns.
    # Without the parameterless wait this exposes an early success instead of final failure.
    function Start-Process {
        param($FilePath, $ArgumentList, $RedirectStandardOutput, $RedirectStandardError,
            [switch] $PassThru)
        [IO.File]::WriteAllText($RedirectStandardOutput, "exit: 0`n")
        $fake = [pscustomobject] @{ Id = 1; Handle = 1; HasExited = $true;
            ExitCode = $null; Log = $RedirectStandardOutput }
        $fake | Add-Member ScriptMethod WaitForExit {
            param($Milliseconds = $null)
            if ($null -ne $Milliseconds) { return $true }
            [IO.File]::WriteAllText($this.Log, "exit: 0`nexit: 7`n")
        }
        $fake | Add-Member ScriptMethod Dispose {}
        return $fake
    }
    try {
        Assert-Equal 'drain final failure before trusting null native exit' (
            Invoke-WaveWindowsDriver -ScriptPath '/mock' -LogPath (Join-Path $root 'drain.log') `
                -ErrorPath (Join-Path $root 'drain.err')) 7
    } finally {
        Remove-Item Function:Start-Process
    }
    Run-Case 'native success' "printf 'exit: 0\n'`nexit 0`n" 0
    Run-Case 'native failure' "printf 'exit: 7\n'`nexit 7`n" 7
    Run-Case 'inner Bash failure with null Process.ExitCode' @'
/usr/bin/bash --noprofile --norc -c 'exit 7'
rc=$?
printf 'exit: %s\n' "$rc"
exit "$rc"
'@ 7 -NullExit
    Run-Case 'null native success' "printf 'exit: 0\n'`n" 0 -NullExit
    Run-Case 'missing sentinel with null exit' "exit 7`n" 2 -NullExit
    Run-Case 'sentinel must be final' "printf 'exit: 0\ntrailing output\n'`n" 2
    Run-Case 'mismatched native exit' "printf 'exit: 0\n'`nexit 7`n" 2
    Run-Case 'timeout kills owned child tree' '(/usr/bin/sleep 3; /usr/bin/touch "$0.survived") &
wait
'  124 -Cap 1
    Start-Sleep -Seconds 3
    Assert-Equal 'timed-out grandchild cannot publish later' (Test-Path (Join-Path $root "$script:count inner.sh.survived")) $false
    # Evidence paths are never reused, even if the old sentinel claims success.
    $stale = Join-Path $root 'stale.log'
    [IO.File]::WriteAllText($stale, "exit: 0`n")
    Assert-Equal 'stale evidence refused' (Invoke-WaveWindowsDriver -ScriptPath '/missing' `
        -LogPath $stale -ErrorPath "$stale.err") 2
    Assert-Equal 'stale evidence preserved' ([IO.File]::ReadAllText($stale)) "exit: 0`n"
    Write-Host 'All Windows driver controls passed.'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}
# CI's PowerShell wrapper otherwise inherits the intentionally nonzero child verdict.
# Uncaught assertion failures terminate above; only the fully passing suite reaches here.
exit 0
