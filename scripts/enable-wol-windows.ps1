# Enable Wake-on-LAN on a Windows box. Run ELEVATED (admin PowerShell) on rog / minix.
#   powershell -ExecutionPolicy Bypass -File enable-wol-windows.ps1
# BIOS/UEFI still has the final say: enable "Wake on LAN" / "Power On by PCI-E" there too.

$ErrorActionPreference = 'Stop'

Write-Host "== Ethernet adapters =="
Get-NetAdapter -Physical | Where-Object { $_.MediaType -eq '802.3' } | Format-Table Name, Status, MacAddress

# 1. Disable Fast Startup — hybrid shutdown leaves most NICs unable to wake from S5.
Write-Host "`n== Disabling Fast Startup =="
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
                 -Name HiberbootEnabled -Value 0 -Type DWord
Write-Host "HiberbootEnabled = 0"

foreach ($nic in Get-NetAdapter -Physical | Where-Object { $_.MediaType -eq '802.3' }) {
  Write-Host "`n== $($nic.Name) =="

  # 2. Power management: let the device wake the machine, and only on a magic packet.
  Enable-NetAdapterPowerManagement -Name $nic.Name -WakeOnMagicPacket -ErrorAction SilentlyContinue
  $pm = Get-NetAdapterPowerManagement -Name $nic.Name
  $pm.WakeOnMagicPacket = 'Enabled'
  $pm.DeviceSleepOnDisconnect = 'Disabled'
  Set-NetAdapterPowerManagement -InputObject $pm
  Get-NetAdapterPowerManagement -Name $nic.Name |
    Format-List WakeOnMagicPacket, WakeOnPattern, DeviceSleepOnDisconnect

  # 3. Vendor advanced properties — names vary by driver; set whichever exist. Only a magic
  # packet may wake the machine; pattern and link triggers are disabled with the power savers.
  $advancedSettings = [ordered]@{
    'Wake on Magic Packet'      = 'Enabled'
    'Wake on pattern match'     = 'Disabled'
    'WakeOnLink'                = 'Disabled'
    'Energy Efficient Ethernet' = 'Disabled'
    'Green Ethernet'            = 'Disabled'
    'Ultra Low Power Mode'      = 'Disabled'
  }
  foreach ($kw in $advancedSettings.Keys) {
    $p = Get-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName $kw -ErrorAction SilentlyContinue
    if ($p) {
      $val = $advancedSettings[$kw]
      try {
        Set-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName $kw -DisplayValue $val
        Write-Host "  $kw -> $val"
      } catch { Write-Warning "  $kw : could not set ($val): $($_.Exception.Message)" }
    }
  }

  # 4. Shutdown WoL (Intel/Realtek): keep the NIC powered in S5.
  foreach ($kw in 'Shutdown Wake-On-Lan', 'Shutdown Wake Up', 'Wake on Magic Packet from power off state') {
    $p = Get-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName $kw -ErrorAction SilentlyContinue
    if ($p) {
      try {
        Set-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName $kw -DisplayValue 'Enabled'
        Write-Host "  $kw -> Enabled"
      } catch { Write-Warning "  $kw : could not enable: $($_.Exception.Message)" }
    }
  }
}

Write-Host "`n== Devices currently armed to wake the system =="
powercfg /devicequery wake_armed

Write-Host "`nDone. Shut down fully (shutdown /s /t 0), then test from the Mac:"
Write-Host "  ~/bin/wake-lab.sh --wait <rog-or-minix>"
