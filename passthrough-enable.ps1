#Requires -RunAsAdministrator
<#
  passthrough-enable.ps1 - enable / revert / show MAC Pass-Through for a USB dock (Realtek).
  How it works: with BIOS "MAC Address Pass-Through" enabled, firmware writes the host MAC into ACPI
  DSDT as _AUXMAC_#AABBCCDDEEFF#. These 4 registry values force the Realtek driver to apply it to the
  dock NIC (otherwise the driver skips passthrough for non-branded docks like WAVLINK).
  Verified on Dell Latitude 5530 (driver rtu56cx22x64), 2026-11-19 -> the dock NIC adopts the host pass-through MAC.
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
function Get-DsdtAuxMac {
  if (-not ('Fw.Pt' -as [type])) {
    Add-Type -Namespace Fw -Name Pt -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern uint GetSystemFirmwareTable(uint p, uint t, byte[] b, uint s);'
  }
  $sz = [Fw.Pt]::GetSystemFirmwareTable(0x41435049, 0x54445344, $null, 0)   # 'ACPI','DSDT'
  if ($sz -le 0) { return $null }
  $b = New-Object byte[] $sz
  [void][Fw.Pt]::GetSystemFirmwareTable(0x41435049, 0x54445344, $b, $sz)
  $t = -join ($b | ForEach-Object { [char]$_ })
  $m = [regex]::Match($t, '_[A-Z]{2,6}MAC_#[0-9A-Fa-f]{12}#')
  if ($m.Success) { return $m.Value } else { return $null }
}

$a = Get-DockAdapter
if (-not $a)   { Write-Host 'Dock NIC (Realtek USB 2.5G) not found. Plug in the dock.' -ForegroundColor Red; return }
$key = Get-DockKey $a.InterfaceGuid
if (-not $key) { Write-Host 'Adapter registry key not found.' -ForegroundColor Red; return }
$svc = (Get-PnpDeviceProperty -InstanceId $a.PnPDeviceID -KeyName 'DEVPKEY_Device_Service' -ErrorAction SilentlyContinue).Data
$aux = Get-DsdtAuxMac

Write-Host ""
Write-Host "Adapter : $($a.Name)   MAC=$($a.MacAddress)   driver=$svc"
Write-Host "Key     : $($key.Name)"
if ($aux) { Write-Host "DSDT    : $aux   (BIOS passthrough active)" -ForegroundColor Green }
else      { Write-Host "DSDT    : no _AUXMAC_ string - enable 'MAC Address Pass-Through' in BIOS, else passthrough is impossible" -ForegroundColor Yellow }
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
  Write-Host 'Apply aborted: no MAC in DSDT (see yellow note about BIOS). Registry left unchanged.' -ForegroundColor Red
  return
}
foreach ($n in $RECIPE.Keys) { New-ItemProperty $key.PSPath -Name $n -Value $RECIPE[$n] -PropertyType DWord -Force | Out-Null }
$exp= ($aux -replace '[_#A-Za-z]','') -replace '(..)(..)(..)(..)(..)(..)','$1-$2-$3-$4-$5-$6'
Write-Host ""
Write-Host ("ENABLED: " + (($RECIPE.Keys | ForEach-Object { "$_=$($RECIPE[$_])" }) -join ', ')) -ForegroundColor Green
Write-Host "Expected dock MAC after replug: $exp" -ForegroundColor Green
Write-Host 'Now UNPLUG and REPLUG the dock (Thunderbolt), then:  .\passthrough-enable.ps1 -Status' -ForegroundColor Cyan
