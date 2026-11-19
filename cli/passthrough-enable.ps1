#Requires -RunAsAdministrator
<#
  passthrough-enable.ps1 - enable / revert / show MAC Pass-Through for a USB dock (Realtek).
  How it works: with BIOS "MAC Address Pass-Through" enabled, firmware writes the host MAC into ACPI
  DSDT as _AUXMAC_#AABBCCDDEEFF#. These 4 registry values force the Realtek driver to apply it to the
  dock NIC (otherwise the driver skips passthrough for non-branded docks like WAVLINK).
  Verified on Dell Latitude 5530 (driver rtu56cx22x64), 2026-11-19 -> dock MAC became 00-BE-43-6B-6A-AF.
  REQUIRES: BIOS "MAC Address Pass-Through" enabled (else no MAC in DSDT; script warns, leaves registry alone).
  Run as ADMIN:
    .\passthrough-enable.ps1           # show state and ENABLE
    .\passthrough-enable.ps1 -Revert   # REVERT (restore the dock's own MAC)
    .\passthrough-enable.ps1 -Status   # show state only
  After Apply/Revert: unplug and replug the dock (Thunderbolt). Do NOT Disable/Enable the adapter (BSOD WDF_VIOLATION).
#>
param([switch]$Revert, [switch]$Status)

$RECIPE = [ordered]@{ EnableManualCloneMAC = 1; AUXMacType = 3; AUXMacSupportVer = 1; EnableCloneMAC = 1 }
$CLASS  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'

function Get-DockAdapter {
  Get-NetAdapter | Where-Object { $_.InterfaceDescription -match 'Realtek.*USB|8156|2\.5GbE|2\.5G' } | Select-Object -First 1
}
function Get-DockKey([string]$guid) {
  Get-ChildItem $CLASS | Where-Object {
    (Get-ItemProperty $_.PSPath -Name NetCfgInstanceId -ErrorAction SilentlyContinue).NetCfgInstanceId -eq $guid
  } | Select-Object -First 1
}
function Get-DsdtInfo {
  # Generic, any-machine: read this host's live ACPI DSDT, report the pass-through MAC the firmware
  # publishes AND whether the firmware supports the feature at all. Standard Windows API; nothing is
  # hardcoded per machine. Supported = known pass-through plumbing present (Dell object AMAC /
  # Lenovo object MACA, or an _AUXMAC_/_RTXMAC_ marker, even a disabled placeholder with no MAC).
  if (-not ('Fw.Pt' -as [type])) {
    Add-Type -Namespace Fw -Name Pt -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern uint GetSystemFirmwareTable(uint p, uint t, byte[] b, uint s);'
  }
  $sz = [Fw.Pt]::GetSystemFirmwareTable(0x41435049, 0x54445344, $null, 0)   # 'ACPI','DSDT'
  if ($sz -le 0) { return @{ Mac = $null; Supported = $false } }
  $b = New-Object byte[] $sz
  [void][Fw.Pt]::GetSystemFirmwareTable(0x41435049, 0x54445344, $b, $sz)
  $t = -join ($b | ForEach-Object { [char]$_ })
  $m = [regex]::Match($t, '_[A-Z]{2,6}MAC_#[0-9A-Fa-f]{12}#')
  $mac = if ($m.Success) { $m.Value } else { $null }
  $supported = [bool]($mac -or $t.Contains('AMAC') -or $t.Contains('MACA') -or ($t -match '_[A-Z]{2,6}MAC_#'))
  return @{ Mac = $mac; Supported = $supported }
}

$a = Get-DockAdapter
if (-not $a)   { Write-Host 'Dock NIC (Realtek USB 2.5G) not found. Plug in the dock.' -ForegroundColor Red; return }
$key = Get-DockKey $a.InterfaceGuid
if (-not $key) { Write-Host 'Adapter registry key not found.' -ForegroundColor Red; return }
$svc = (Get-PnpDeviceProperty -InstanceId $a.PnPDeviceID -KeyName 'DEVPKEY_Device_Service' -ErrorAction SilentlyContinue).Data
$dsdt = Get-DsdtInfo; $aux = $dsdt.Mac

Write-Host ""
Write-Host "Adapter : $($a.Name)   MAC=$($a.MacAddress)   driver=$svc"
Write-Host "Key     : $($key.Name)"
if ($aux)                  { Write-Host "DSDT    : $aux   (BIOS pass-through ON, MAC published)" -ForegroundColor Green }
elseif ($dsdt.Supported)   { Write-Host "DSDT    : BIOS SUPPORTS pass-through but it is OFF - enable 'MAC Address Pass-Through' in BIOS setup" -ForegroundColor Yellow }
else                       { Write-Host "DSDT    : firmware has NO pass-through feature (no AMAC/MACA object) - this host cannot do BIOS pass-through" -ForegroundColor Yellow }
$p = Get-ItemProperty $key.PSPath
Write-Host ("Recipe  : " + (($RECIPE.Keys | ForEach-Object { "$_=" + $(if ($null -eq $p.$_) {'-'} else {$p.$_}) }) -join ', '))

if ($Status) { return }

if ($Revert) {
  foreach ($n in $RECIPE.Keys) { Remove-ItemProperty $key.PSPath -Name $n -ErrorAction SilentlyContinue }
  Write-Host ""
  Write-Host 'REVERTED: recipe values removed. Replug the dock to restore its own MAC.' -ForegroundColor Cyan
  return
}

# Apply
if (-not $aux) {
  Write-Host ""
  if ($dsdt.Supported) { Write-Host 'Apply aborted: BIOS supports pass-through but it is OFF. Enable it in BIOS setup, replug, then re-run. Registry left unchanged.' -ForegroundColor Red }
  else                 { Write-Host 'Apply aborted: this firmware has no pass-through feature. Nothing to apply (see README for the manual NetworkAddress alternative). Registry left unchanged.' -ForegroundColor Red }
  return
}
foreach ($n in $RECIPE.Keys) { New-ItemProperty $key.PSPath -Name $n -Value $RECIPE[$n] -PropertyType DWord -Force | Out-Null }
$exp= ($aux -replace '[_#A-Za-z]','') -replace '(..)(..)(..)(..)(..)(..)','$1-$2-$3-$4-$5-$6'
Write-Host ""
Write-Host ("ENABLED: " + (($RECIPE.Keys | ForEach-Object { "$_=$($RECIPE[$_])" }) -join ', ')) -ForegroundColor Green
Write-Host "Expected dock MAC after replug: $exp" -ForegroundColor Green
Write-Host 'Now UNPLUG and REPLUG the dock (Thunderbolt), then:  .\passthrough-enable.ps1 -Status' -ForegroundColor Cyan
