#Requires -Version 5
<# Realtek MAC Pass-Through - WinForms GUI.
   Finds the Realtek USB dock NIC, shows live MAC/driver, the MAC the BIOS publishes in ACPI DSDT,
   the registry recipe state, and lets you Enable / Revert pass-through. Reads everything from the
   system - nothing hardcoded. Run as Administrator to change settings.
   -Screenshot <png> : render the window to a PNG and exit (for previews).  -Demo : sample data. #>
param([string]$Screenshot, [switch]$Demo, [string]$DemoState = 'active-tool')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

# ----------------------------------------------------------------------------
#  THEME  (single source of style for the whole app - never style controls ad-hoc)
# ----------------------------------------------------------------------------
$script:T = @{
  Bg        = [Drawing.Color]::FromArgb(244,245,247)
  Surface   = [Drawing.Color]::FromArgb(255,255,255)
  SurfAlt   = [Drawing.Color]::FromArgb(237,239,242)
  SurfAltHi = [Drawing.Color]::FromArgb(227,230,234)
  Border    = [Drawing.Color]::FromArgb(226,229,233)
  Text      = [Drawing.Color]::FromArgb(28,32,38)
  Sub       = [Drawing.Color]::FromArgb(120,126,134)
  Accent    = [Drawing.Color]::FromArgb(37,99,235)
  Success   = [Drawing.Color]::FromArgb(22,160,83)
  SuccessHi = [Drawing.Color]::FromArgb(18,140,72)
  Neutral   = [Drawing.Color]::FromArgb(134,140,148)
  Warn      = [Drawing.Color]::FromArgb(224,138,30)
  White     = [Drawing.Color]::White
  Pad       = 24
}
$script:F = @{
  Head    = New-Object Drawing.Font('Segoe UI',15.5,[Drawing.FontStyle]::Bold)
  Sub     = New-Object Drawing.Font('Segoe UI',9)
  Section = New-Object Drawing.Font('Segoe UI',8,[Drawing.FontStyle]::Bold)
  Caption = New-Object Drawing.Font('Segoe UI',9)
  Value   = New-Object Drawing.Font('Segoe UI',9.5,[Drawing.FontStyle]::Bold)
  Mono    = New-Object Drawing.Font('Consolas',10)
  Banner  = New-Object Drawing.Font('Segoe UI',12,[Drawing.FontStyle]::Bold)
  Button  = New-Object Drawing.Font('Segoe UI',9.5,[Drawing.FontStyle]::Bold)
}

# ----------------------------------------------------------------------------
#  SYSTEM ACCESS  (everything read live - nothing hardcoded)
# ----------------------------------------------------------------------------
$RECIPE = [ordered]@{ EnableManualCloneMAC = 1; AUXMacType = 3; AUXMacSupportVer = 1; EnableCloneMAC = 1 }
$CLASS  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
function Test-Admin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator) }
function Get-DockAdapter {
  # strict: a Realtek USB NIC only (USB vendor 0BDA). These registry keys are Realtek-specific.
  Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
    $_.PnPDeviceID -match '^USB\\VID_0BDA' -or ($_.InterfaceDescription -match 'Realtek' -and $_.InterfaceDescription -match 'USB|2\.5G')
  } | Select-Object -First 1
}
function Get-DockKey([string]$guid) { Get-ChildItem $CLASS -ErrorAction SilentlyContinue | Where-Object { (Get-ItemProperty $_.PSPath -Name NetCfgInstanceId -ErrorAction SilentlyContinue).NetCfgInstanceId -eq $guid } | Select-Object -First 1 }
function Get-DsdtInfo {
  # Generic, any-machine: read this host's live ACPI DSDT and report (a) the pass-through MAC the
  # firmware publishes, and (b) whether the firmware SUPPORTS the feature at all. Standard Windows
  # API, nothing hardcoded per machine. Supported = the known pass-through plumbing is present:
  # Dell object AMAC / Lenovo object MACA, or an _AUXMAC_/_RTXMAC_ marker (even a disabled placeholder).
  if (-not ('Fw.Pt' -as [type])) { Add-Type -Namespace Fw -Name Pt -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern uint GetSystemFirmwareTable(uint p, uint t, byte[] b, uint s);' }
  $sz = [Fw.Pt]::GetSystemFirmwareTable(0x41435049, 0x54445344, $null, 0); if ($sz -le 0) { return @{ Mac = $null; Supported = $false } }
  $b = New-Object byte[] $sz; [void][Fw.Pt]::GetSystemFirmwareTable(0x41435049, 0x54445344, $b, $sz)
  $t = -join ($b | ForEach-Object { [char]$_ }); $m = [regex]::Match($t, '_[A-Z]{2,6}MAC_#([0-9A-Fa-f]{12})#')
  $mac = if ($m.Success) { $m.Groups[1].Value } else { $null }
  $supported = [bool]($mac -or $t.Contains('AMAC') -or $t.Contains('MACA') -or ($t -match '_[A-Z]{2,6}MAC_#'))
  return @{ Mac = $mac; Supported = $supported }
}
function Get-DsdtAuxMac { (Get-DsdtInfo).Mac }
function Format-Mac([string]$hex) { if (-not $hex) { return $null }; ($hex -replace '(..)(..)(..)(..)(..)(..)', '$1-$2-$3-$4-$5-$6').ToUpper() }

# ----------------------------------------------------------------------------
#  STYLED CONTROL FACTORIES  (the only place visual style is applied)
# ----------------------------------------------------------------------------
function New-Card([int]$x,[int]$y,[int]$w,[int]$h,[string]$title) {
  $card = New-Object Windows.Forms.Panel
  $card.Location = New-Object Drawing.Point($x,$y); $card.Size = New-Object Drawing.Size($w,$h); $card.BackColor = $script:T.Surface
  $card.Add_Paint({ param($s,$e)
    $e.Graphics.SmoothingMode = 'AntiAlias'
    $pen = New-Object Drawing.Pen($script:T.Border,1); $e.Graphics.DrawRectangle($pen,0,0,$s.Width-1,$s.Height-1); $pen.Dispose()
  })
  if ($title) {
    $lab = New-Object Windows.Forms.Label; $lab.Text = $title.ToUpper(); $lab.Font = $script:F.Section; $lab.ForeColor = $script:T.Sub
    $lab.AutoSize = $true; $lab.Location = New-Object Drawing.Point(14,10); $card.Controls.Add($lab)
  }
  $script:form.Controls.Add($card); return $card
}
function Add-Row($parent,[string]$cap,[int]$y,[string]$keyName,[switch]$mono) {
  $c = New-Object Windows.Forms.Label; $c.Text = $cap; $c.Font = $script:F.Caption; $c.ForeColor = $script:T.Sub; $c.AutoSize = $true; $c.Location = New-Object Drawing.Point(14,$y); $parent.Controls.Add($c)
  $v = New-Object Windows.Forms.Label; if ($mono) { $v.Font = $script:F.Mono } else { $v.Font = $script:F.Value }; $v.ForeColor = $script:T.Text; $v.AutoSize = $true; $v.Location = New-Object Drawing.Point(150,($y-1)); $parent.Controls.Add($v); $script:UI[$keyName] = $v
}
function New-Button([string]$text,[int]$x,[string]$kind) {
  $b = New-Object Windows.Forms.Button; $b.Text = $text; $b.Size = New-Object Drawing.Size(148,40); $b.Location = New-Object Drawing.Point($x,428)
  $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0; $b.Font = $script:F.Button; $b.Cursor = 'Hand'
  if ($kind -eq 'primary') {
    $b.BackColor = $script:T.Success; $b.ForeColor = $script:T.White; $b.FlatAppearance.MouseOverBackColor = $script:T.SuccessHi
  } else {
    $b.BackColor = $script:T.SurfAlt; $b.ForeColor = $script:T.Text; $b.FlatAppearance.BorderSize = 1; $b.FlatAppearance.BorderColor = $script:T.Border; $b.FlatAppearance.MouseOverBackColor = $script:T.SurfAltHi
  }
  $script:form.Controls.Add($b); return $b
}

function New-AppIcon {
  # custom icon: accent rounded square + white two-way "pass-through" arrows
  $bmp = New-Object Drawing.Bitmap(32,32); $g = [Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'; $g.Clear([Drawing.Color]::Transparent)
  $path = New-Object Drawing.Drawing2D.GraphicsPath; $r = 8
  $path.AddArc(0,0,$r,$r,180,90); $path.AddArc(31-$r,0,$r,$r,270,90); $path.AddArc(31-$r,31-$r,$r,$r,0,90); $path.AddArc(0,31-$r,$r,$r,90,90); $path.CloseAllFigures()
  $bg = New-Object Drawing.SolidBrush($script:T.Accent); $g.FillPath($bg,$path); $bg.Dispose()
  $pen = New-Object Drawing.Pen($script:T.White,2.6); $pen.CustomEndCap = New-Object Drawing.Drawing2D.AdjustableArrowCap(3,3)
  $g.DrawLine($pen, 8,12, 21,12); $g.DrawLine($pen, 24,20, 11,20); $pen.Dispose(); $g.Dispose()
  return [Drawing.Icon]::FromHandle($bmp.GetHicon())
}

# ----------------------------------------------------------------------------
#  WINDOW
# ----------------------------------------------------------------------------
$script:form = New-Object Windows.Forms.Form
$script:form.Text = 'Realtek MAC Pass-Through'; $script:form.ClientSize = New-Object Drawing.Size(520,584)
$script:form.StartPosition = 'CenterScreen'; $script:form.BackColor = $script:T.Bg; $script:form.Font = $script:F.Sub
$script:form.FormBorderStyle = 'FixedSingle'; $script:form.MaximizeBox = $false
try { $script:form.Icon = New-AppIcon } catch {}
$script:UI = @{}

$hdr = New-Object Windows.Forms.Label; $hdr.Text = 'Realtek MAC Pass-Through'; $hdr.Font = $script:F.Head; $hdr.ForeColor = $script:T.Text; $hdr.AutoSize = $true; $hdr.Location = New-Object Drawing.Point(24,18); $script:form.Controls.Add($hdr)
$sub = New-Object Windows.Forms.Label; $sub.Text = 'USB NIC dock  -  Windows'; $sub.Font = $script:F.Sub; $sub.ForeColor = $script:T.Sub; $sub.AutoSize = $true; $sub.Location = New-Object Drawing.Point(26,50); $script:form.Controls.Add($sub)

# status pill (color + dot set in Update-Ui)
$script:pill = New-Object Windows.Forms.Panel; $script:pill.Location = New-Object Drawing.Point(24,80); $script:pill.Size = New-Object Drawing.Size(472,46); $script:pill.BackColor = $script:T.Neutral
$script:pill.Add_Paint({ param($s,$e)
  $e.Graphics.SmoothingMode = 'AntiAlias'
  $br = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(210,255,255,255)); $e.Graphics.FillEllipse($br,18,($s.Height/2 - 5),10,10); $br.Dispose()
})
$script:form.Controls.Add($script:pill)
$script:pillLbl = New-Object Windows.Forms.Label; $script:pillLbl.Font = $script:F.Banner; $script:pillLbl.ForeColor = $script:T.White; $script:pillLbl.TextAlign = 'MiddleLeft'
$script:pillLbl.Location = New-Object Drawing.Point(40,0); $script:pillLbl.Size = New-Object Drawing.Size(428,46); $script:pill.Controls.Add($script:pillLbl)

$card1 = New-Card 24 140 472 98 'Dock adapter'
Add-Row $card1 'Name'        34 'name'
Add-Row $card1 'Current MAC' 56 'mac' -mono
Add-Row $card1 'Driver'      78 'drv'
$card2 = New-Card 24 250 472 62 'Firmware  (BIOS - ACPI DSDT)'
Add-Row $card2 'Pass-through MAC' 32 'fw' -mono
$card3 = New-Card 24 324 472 62 'Registry'
Add-Row $card3 'Recipe state' 32 'reg'

$note = New-Object Windows.Forms.Label; $note.Text = 'After Enable / Revert: physically unplug and replug the dock  (do NOT Disable/Enable the adapter).'; $note.Font = $script:F.Sub; $note.ForeColor = $script:T.Sub; $note.Location = New-Object Drawing.Point(24,394); $note.Size = New-Object Drawing.Size(472,32); $script:form.Controls.Add($note)

$btnEnable  = New-Button 'Enable'  24  'primary'
$btnRevert  = New-Button 'Revert'  186 'secondary'
$btnRefresh = New-Button 'Refresh' 348 'secondary'

$log = New-Object Windows.Forms.TextBox; $log.Multiline = $true; $log.ReadOnly = $true; $log.ScrollBars = 'Vertical'; $log.BorderStyle = 'FixedSingle'; $log.BackColor = $script:T.Surface; $log.ForeColor = $script:T.Sub; $log.Font = $script:F.Mono
$log.Location = New-Object Drawing.Point(24,480); $log.Size = New-Object Drawing.Size(472,80); $script:form.Controls.Add($log)
function Write-Log([string]$m) { $log.AppendText(('{0}  {1}{2}' -f (Get-Date -Format HH:mm:ss), $m, "`r`n")) }

# ----------------------------------------------------------------------------
#  STATE / ACTIONS
# ----------------------------------------------------------------------------
$script:state = @{ adapter = $null; key = $null; fw = $null; supported = $false }
function Set-Pill([string]$text,[Drawing.Color]$color) { $script:pill.BackColor = $color; $script:pillLbl.Text = $text; $script:pill.Invalidate() }
function Update-Ui {
  if ($Demo) {
    $PT = '00-11-22-33-44-55'; $OWN = 'A0-B1-C2-D3-E4-F5'
    switch ($DemoState) {
      'active-native' {
        $script:UI.name.Text = 'Ethernet 5'; $script:UI.mac.Text = $PT; $script:UI.drv.Text = 'rtu53cx22x64'
        $script:UI.fw.Text = $PT; $script:UI.reg.Text = 'not set   (0 / 4)'
        Set-Pill 'PASS-THROUGH ACTIVE  (native / auto-recognized)' $script:T.Success }
      'ready' {
        $script:UI.name.Text = 'Ethernet 5'; $script:UI.mac.Text = $OWN; $script:UI.drv.Text = 'rtu56cx22x64'
        $script:UI.fw.Text = $PT; $script:UI.reg.Text = 'not set   (0 / 4)'
        Set-Pill 'READY  -  press Enable to apply pass-through' $script:T.Accent }
      { $_ -in 'disabled','bios-disabled' } {
        $script:UI.name.Text = 'Ethernet 5'; $script:UI.mac.Text = $OWN; $script:UI.drv.Text = 'rtump64x64'
        $script:UI.fw.Text = 'supported, OFF in BIOS'; $script:UI.reg.Text = 'not set   (0 / 4)'
        Set-Pill 'BIOS SUPPORTS PASS-THROUGH  -  enable it in BIOS setup' $script:T.Warn }
      { $_ -in 'unsupported','nomac' } {
        $script:UI.name.Text = 'Ethernet 5'; $script:UI.mac.Text = $OWN; $script:UI.drv.Text = 'rtump64x64'
        $script:UI.fw.Text = 'not supported by firmware'; $script:UI.reg.Text = 'not set   (0 / 4)'
        Set-Pill 'BIOS HAS NO PASS-THROUGH  (host firmware, not the dock)' $script:T.Neutral }
      'notfound' {
        foreach ($k in 'name','mac','drv','fw','reg') { $script:UI[$k].Text = '-' }
        $btnEnable.Enabled = $false; $btnRevert.Enabled = $false
        $btnEnable.BackColor = $script:T.SurfAlt; $btnEnable.ForeColor = $script:T.Sub; $btnRevert.ForeColor = $script:T.Sub
        Set-Pill 'DOCK NIC NOT FOUND  -  plug in the dock' $script:T.Neutral }
      default {
        $script:UI.name.Text = 'Ethernet 5'; $script:UI.mac.Text = $PT; $script:UI.drv.Text = 'rtu56cx22x64'
        $script:UI.fw.Text = $PT; $script:UI.reg.Text = 'ENABLED   (4 / 4 keys set)'
        Set-Pill 'PASS-THROUGH ACTIVE  (via this tool)' $script:T.Success }
    }
    return
  }
  $a = Get-DockAdapter; $script:state.adapter = $a
  if (-not $a) {
    foreach ($k in 'name','mac','drv','fw','reg') { $script:UI[$k].Text = '-' }
    Set-Pill 'DOCK NIC NOT FOUND  -  plug in the dock' $script:T.Neutral
    $btnEnable.Enabled = $false; $btnRevert.Enabled = $false
    $btnEnable.BackColor = $script:T.SurfAlt; $btnEnable.ForeColor = $script:T.Sub; $btnRevert.ForeColor = $script:T.Sub
    return
  }
  $btnEnable.Enabled = $true; $btnRevert.Enabled = $true
  $btnEnable.BackColor = $script:T.Success; $btnEnable.ForeColor = $script:T.White; $btnRevert.ForeColor = $script:T.Text
  $script:UI.name.Text = $a.Name; $script:UI.mac.Text = $a.MacAddress
  $script:UI.drv.Text = (Get-PnpDeviceProperty -InstanceId $a.PnPDeviceID -KeyName 'DEVPKEY_Device_Service' -ErrorAction SilentlyContinue).Data
  $dsdt = Get-DsdtInfo; $fw = $dsdt.Mac; $script:state.fw = $fw; $script:state.supported = $dsdt.Supported; $hasFw = [bool]$fw
  if ($fw)                   { $script:UI.fw.Text = (Format-Mac $fw) }
  elseif ($dsdt.Supported)   { $script:UI.fw.Text = 'supported, OFF in BIOS' }
  else                       { $script:UI.fw.Text = 'not supported by firmware' }
  $key = Get-DockKey $a.InterfaceGuid; $script:state.key = $key
  if ($key) { $p = Get-ItemProperty $key.PSPath } else { $p = $null }
  $setN = (@($RECIPE.Keys | Where-Object { $p -and $p.$_ -eq $RECIPE[$_] })).Count
  if ($setN -eq $RECIPE.Count) { $script:UI.reg.Text = "ENABLED   ($setN / $($RECIPE.Count) keys set)" }
  elseif ($setN -eq 0) { $script:UI.reg.Text = "not set   (0 / $($RECIPE.Count))" }
  else { $script:UI.reg.Text = "partial   ($setN / $($RECIPE.Count) keys)" }
  $active = $hasFw -and (($a.MacAddress -replace '-','').ToUpper() -eq $fw.ToUpper())
  if ($active -and $setN -eq $RECIPE.Count) { Set-Pill 'PASS-THROUGH ACTIVE  (via this tool)' $script:T.Success }
  elseif ($active) { Set-Pill 'PASS-THROUGH ACTIVE  (native / auto-recognized)' $script:T.Success }
  elseif ($hasFw) { Set-Pill 'READY  -  press Enable to apply pass-through' $script:T.Accent }
  elseif ($dsdt.Supported) { Set-Pill 'BIOS SUPPORTS PASS-THROUGH  -  enable it in BIOS setup' $script:T.Warn }
  else { Set-Pill 'BIOS HAS NO PASS-THROUGH  (host firmware, not the dock)' $script:T.Neutral }
}
$btnRefresh.Add_Click({ Update-Ui; Write-Log 'refreshed' })
$btnEnable.Add_Click({
  if (-not (Test-Admin)) { [Windows.Forms.MessageBox]::Show('Run this tool as Administrator to change settings.','Not elevated') | Out-Null; return }
  if (-not $script:state.fw) {
    $msg = if ($script:state.supported) { 'BIOS supports MAC Pass-Through but it is OFF. Enable it in BIOS setup (then replug), so firmware publishes the MAC.' }
           else { 'This firmware has no MAC Pass-Through feature (no AMAC/MACA object in ACPI DSDT). It cannot be enabled here; see README for the manual NetworkAddress alternative.' }
    [Windows.Forms.MessageBox]::Show($msg,'Cannot enable') | Out-Null; return }
  try { foreach ($n in $RECIPE.Keys) { New-ItemProperty $script:state.key.PSPath -Name $n -Value $RECIPE[$n] -PropertyType DWord -Force | Out-Null }
        Write-Log 'recipe written - unplug and replug the dock'; Update-Ui } catch { Write-Log "error: $_" }
})
$btnRevert.Add_Click({
  if (-not (Test-Admin)) { [Windows.Forms.MessageBox]::Show('Run this tool as Administrator to change settings.','Not elevated') | Out-Null; return }
  try { foreach ($n in $RECIPE.Keys) { Remove-ItemProperty $script:state.key.PSPath -Name $n -ErrorAction SilentlyContinue }
        Write-Log 'recipe removed - unplug and replug the dock'; Update-Ui } catch { Write-Log "error: $_" }
})

Update-Ui
if (-not (Test-Admin) -and -not $Screenshot) { Write-Log 'Not elevated - Enable/Revert need Administrator.' } else { Write-Log 'ready.' }

if ($Screenshot) {
  $script:form.Opacity = 0; $script:form.ShowInTaskbar = $false; $script:form.Show(); [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 450; [Windows.Forms.Application]::DoEvents()
  $bmp = New-Object Drawing.Bitmap($script:form.Width, $script:form.Height); $script:form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0,0,$script:form.Width,$script:form.Height)))
  $bmp.Save($Screenshot, [Drawing.Imaging.ImageFormat]::Png); $script:form.Close(); Write-Output "saved $Screenshot"
} else { [void]$script:form.ShowDialog() }
