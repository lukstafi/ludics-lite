# Re-pin the Windows Update active hours on a Windows box. Run ELEVATED (admin PowerShell) on
# rog / minix.
#   powershell -ExecutionPolicy Bypass -File enable-active-hours-windows.ps1
# Active hours are the only setting that keeps an update restart off the box while a sweep lane is
# running: on 2026-09-15 KB5129195 restarted minix 21 min into its hip unit, because active hours
# were 10:00-01:00 and the sweep runs in the morning. Both boxes were then hand-set to 6 -> 0 with
# SmartActiveHoursState=0, and nothing re-applies that -- a feature update can reset the values,
# which is why `scripts/wake-lab.sh status` reads the same three values back and warns when the
# sweep window (WAKE_LAB_SWEEP_HOURS, default 7-11 local) is not inside them. This script is the
# one-step repair for that warning; run it on the box the warning named.

[CmdletBinding()]
param(
  [int] $Start = 6,   # first active hour, INCLUSIVE
  [int] $End   = 0,   # the hour active hours end, EXCLUSIVE: 0 is midnight, so 6-0 is 06:00-24:00
  [switch] $Smart     # leave Windows free to move the window (SmartActiveHoursState=1)
)

$ErrorActionPreference = 'Stop'

$key = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
$names = 'ActiveHoursStart', 'ActiveHoursEnd', 'SmartActiveHoursState'

function Get-Setting {
  param([string] $Name)
  # A value that has never been written is not an error here: it is exactly the state this script
  # repairs, and it has to print in the "before" block rather than abort the run.
  try {
    $v = (Get-ItemProperty -Path $key -Name $Name -ErrorAction Stop).$Name
    if ($null -eq $v) { '(unset)' } else { "$v" }
  } catch { '(unset)' }
}

function Show-Settings {
  param([string] $Label)
  Write-Host "== $Label =="
  foreach ($n in $names) { Write-Host ("  {0,-21} = {1}" -f $n, (Get-Setting $n)) }
}

# Validate BEFORE touching the registry. A span Windows cannot mean is the same finding wake-lab.sh
# reports on a box whose values an update reset, so writing one here would move the reset from
# Windows into this script -- and the quiet line it would then print is worse than the warning it
# replaced. The end is exclusive, so equal endpoints are an EMPTY window, not a day-long one, and
# Windows allows at most 18 hours (which is what makes 6 -> 0 the pinned maximum).
# Write-Error is -ErrorAction Continue deliberately: under the $ErrorActionPreference above it
# would throw instead, and the exit code of this refusal would be the host's rather than the 1
# stated here.
if ($Start -lt 0 -or $Start -gt 23 -or $End -lt 0 -or $End -gt 23) {
  Write-Error "active hours $Start-$End are not a pair of clock hours (0-23); nothing was written" -ErrorAction Continue
  exit 1
}
$span = (($End - $Start) + 24) % 24
if ($span -eq 0) {
  Write-Error "active hours $Start-$End span no time at all (the end is exclusive); nothing was written" -ErrorAction Continue
  exit 1
}
if ($span -gt 18) {
  Write-Error "active hours $Start-$End span $span h, which Windows cannot mean (its maximum is 18 h); nothing was written" -ErrorAction Continue
  exit 1
}

# Elevation is checked after the span, so an invalid one is refused on any shell, but before the
# write, where a missing one surfaces as "Requested registry access is not allowed" -- which reads
# like a locked-down box rather than a forgotten Run as administrator.
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole(
      [Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Warning "not running elevated: the HKLM write below will fail. Re-run from an admin PowerShell."
}

Show-Settings 'before'

if (-not (Test-Path $key)) { New-Item -Path $key -Force > $null }
$smartValue = if ($Smart) { 1 } else { 0 }
Set-ItemProperty -Path $key -Name ActiveHoursStart      -Value $Start      -Type DWord
Set-ItemProperty -Path $key -Name ActiveHoursEnd        -Value $End        -Type DWord
Set-ItemProperty -Path $key -Name SmartActiveHoursState -Value $smartValue -Type DWord

Write-Host ""
Show-Settings 'after'

Write-Host ""
if ($Smart) {
  Write-Host "Active hours pinned to $Start-$End ($span h, the end exclusive), but smart active hours are ON: Windows may move the window, and wake-lab.sh will keep warning."
} else {
  Write-Host "Active hours pinned to $Start-$End ($span h, the end exclusive), smart active hours off."
}
Write-Host "Confirm from the Mac:"
Write-Host "  scripts/wake-lab.sh status <box>"
