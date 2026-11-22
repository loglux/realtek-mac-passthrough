<#
  Registry Fix - turn on MAC pass-through in Windows without changing the card.
  For a Realtek USB network card (dock or dongle) on a laptop whose BIOS publishes a pass-through MAC
  (_AUXMAC_ in the ACPI DSDT, e.g. Dell "MAC Address Pass-Through"). Four driver settings in the card's
  registry key make the Realtek driver use that MAC. Windows only (not pre-boot, not Linux); fully reversible.
  No Python, no vendor DLL: WinForms, the registry, Get-NetAdapter and GetSystemFirmwareTable (kernel32).
  Run as ADMIN (Registry-Fix.bat self-elevates):  powershell.exe -STA -File registry-fix.ps1
  -Demo shows made-up data.  -Screenshot <png> [-State <name>] saves one demo state to a PNG.
#>
param([switch]$Demo, [string]$Screenshot = '',
      [ValidateSet('ready','preview','applied','works-fix','works-native','not-loaded','bios-off','no-feature','ms-driver','no-card','details')]
      [string]$State = 'ready')
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$ErrorActionPreference = 'Stop'
$Version = '1.0.0'
$script:DemoMode = $Demo.IsPresent -or ($Screenshot -ne '')

# ---------- the fix: four DWORD values in the card's driver key ----------
$RECIPE = [ordered]@{ EnableManualCloneMAC = 1; AUXMacType = 3; AUXMacSupportVer = 1; EnableCloneMAC = 1 }
$CLASS  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'

# ---------- theme (same as Card-Inspector) ----------
function rgb($r,$g,$b) { [Drawing.Color]::FromArgb($r,$g,$b) }
$C_WHITE   = [Drawing.Color]::White
$C_SOFT    = rgb 243 244 246
$C_LINE    = rgb 208 215 222
$C_TEXT    = rgb 31 35 40
$C_MUTED   = rgb 89 99 110
$C_ACCENT  = rgb 31 111 235
$C_GREEN   = rgb 46 139 62
$C_GREENBG = rgb 233 246 236
$C_RED     = rgb 209 56 61
$C_REDBG   = rgb 253 236 236
$C_AMBER   = rgb 178 106 0
$C_AMBERBG = rgb 255 244 224
$C_IDLE    = rgb 150 156 164
$C_INFOBG  = rgb 232 240 254
$FS_XL = 18; $FS_L = 12; $FS_M = 10; $FS_S = 9
function F($size, [bool]$bold = $false, $fam = 'Segoe UI') {
  $st = if ($bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }
  New-Object Drawing.Font($fam, [single]$size, $st)
}

# ---------- reading the system (live, nothing hard-coded) ----------
function Test-Admin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator) }
function Format-Mac([string]$hex) { if (-not $hex) { return '' }; (($hex -replace '[-:]','') -replace '(..)(..)(..)(..)(..)(..)', '$1-$2-$3-$4-$5-$6').ToUpper() }

function Get-Firmware {
  # The laptop's ACPI DSDT, read with the standard Windows API. Mac = the pass-through MAC the BIOS publishes;
  # Supported = the firmware has the feature at all (Dell AMAC / Lenovo MACA, or an _AUXMAC_ marker).
  if (-not ('Fw.Pt' -as [type])) {
    Add-Type -Namespace Fw -Name Pt -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern uint GetSystemFirmwareTable(uint p, uint t, byte[] b, uint s);'
  }
  $sz = [Fw.Pt]::GetSystemFirmwareTable(0x41435049, 0x54445344, $null, 0)    # 'ACPI', 'DSDT'
  if ($sz -le 0) { return @{ Mac = ''; Supported = $false } }
  $b = New-Object byte[] $sz; [void][Fw.Pt]::GetSystemFirmwareTable(0x41435049, 0x54445344, $b, $sz)
  $t = [Text.Encoding]::ASCII.GetString($b)
  $m = [regex]::Match($t, '_AUXMAC_#([0-9A-Fa-f]{12})#')
  $mac = if ($m.Success) { $m.Groups[1].Value } else { '' }
  @{ Mac = $mac; Supported = [bool]($mac -or $t.Contains('AMAC') -or $t.Contains('MACA') -or $t.Contains('_AUXMAC_')) }
}

function Get-Cards {
  # Realtek USB network cards (USB vendor 0BDA) - docks and dongles
  @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.PnPDeviceID -match '^USB\\VID_0BDA' } | Sort-Object Name)
}

function Get-CardInfo($a) {
  $svc = ''; $chip = ''
  try { $svc = [string](Get-PnpDeviceProperty -InstanceId $a.PnPDeviceID -KeyName 'DEVPKEY_Device_Service').Data } catch { $svc = '' }
  $m = [regex]::Match($a.PnPDeviceID, 'PID_([0-9A-Fa-f]{4})')
  if ($m.Success) { $chip = 'RTL' + $m.Groups[1].Value.ToUpper() }
  $key = Get-ChildItem $CLASS -ErrorAction SilentlyContinue | Where-Object {
    (Get-ItemProperty $_.PSPath -Name NetCfgInstanceId -ErrorAction SilentlyContinue).NetCfgInstanceId -eq $a.InterfaceGuid } | Select-Object -First 1
  $vals = [ordered]@{}; $na = ''
  if ($key) {
    $p = Get-ItemProperty $key.PSPath
    foreach ($n in $RECIPE.Keys) { $vals[$n] = $p.$n }
    $na = [string]$p.NetworkAddress
  }
  $setN = @($RECIPE.Keys | Where-Object { $vals[$_] -eq $RECIPE[$_] }).Count
  @{ Adapter = $a; Name = $a.Name; Desc = $a.InterfaceDescription; Mac = (Format-Mac $a.MacAddress)
     Chip = $chip; Service = $svc; Realtek = ($svc -match '^rtu'); Key = $key; Values = $vals; SetN = $setN
     ManualMac = (Format-Mac $na); Link = $(if ($a.MediaConnectionState -eq 'Connected') { "connected, $($a.LinkSpeed)" } else { 'no cable' }) }
}

# ---------- demo data (made-up MACs) ----------
function Demo-State($s) {
  $fwMac = '00-11-22-33-44-55'; $own = 'A0-B1-C2-D3-E4-F5'
  $vals = [ordered]@{ EnableManualCloneMAC = $null; AUXMacType = $null; AUXMacSupportVer = $null; EnableCloneMAC = $null }
  $fix = $s -in 'works-fix','not-loaded','applied'
  if ($fix) { foreach ($n in $RECIPE.Keys) { $vals[$n] = $RECIPE[$n] } }
  $card = @{ Adapter = $null; Name = 'Ethernet 2'; Desc = 'Realtek USB 2.5GbE Family Controller'; Chip = 'RTL8156'
             Mac = $(if ($s -in 'works-fix','works-native') { $fwMac } else { $own }); Service = 'rtump64x64'; Realtek = $true
             Key = @{ PSChildName = '0019' }; Values = $vals; SetN = $(if ($fix) { 4 } else { 0 }); ManualMac = ''; Link = 'connected, 2.5 Gbps' }
  if ($s -eq 'ms-driver') { $card.Service = 'UsbNcm'; $card.Realtek = $false }
  $fw = switch ($s) { 'bios-off' { @{ Mac = ''; Supported = $true } } 'no-feature' { @{ Mac = ''; Supported = $false } } default { @{ Mac = '001122334455'; Supported = $true } } }
  $list = New-Object System.Collections.ArrayList
  if ($s -ne 'no-card') { [void]$list.Add($card) }
  @{ Cards = $list; Fw = $fw }
}

# ---------- UI helpers ----------
function New-Lbl($parent, $text, $x, $y, $w, $h, $font, $color, $align = 'TopLeft') {
  $l = New-Object Windows.Forms.Label
  $l.Text = $text; $l.Location = "$x,$y"; $l.Size = "$w,$h"; $l.Font = $font; $l.ForeColor = $color
  $l.BackColor = [Drawing.Color]::Transparent; $l.TextAlign = $align; $l.UseMnemonic = $false
  $parent.Controls.Add($l); $l
}
function New-Btn($parent, $text, $x, $y, $w, $h) {
  $b = New-Object Windows.Forms.Button
  $b.Text = $text; $b.Location = "$x,$y"; $b.Size = "$w,$h"; $b.FlatStyle = 'Flat'; $b.Font = F $FS_M $true; $b.Cursor = 'Hand'
  $parent.Controls.Add($b); $b
}
function Style-Btn($b, $kind) {
  $b.FlatAppearance.BorderSize = 1
  if (-not $b.Enabled) { $b.BackColor = rgb 238 240 243; $b.ForeColor = rgb 160 164 170; $b.FlatAppearance.BorderColor = rgb 214 218 223; return }
  switch ($kind) {
    'primary' { $b.BackColor = $C_ACCENT; $b.ForeColor = $C_WHITE; $b.FlatAppearance.BorderColor = $C_ACCENT }
    'link'    { $b.BackColor = $C_WHITE;  $b.ForeColor = $C_ACCENT; $b.FlatAppearance.BorderSize = 0; $b.FlatAppearance.MouseOverBackColor = $C_SOFT }
    default   { $b.BackColor = $C_WHITE;  $b.ForeColor = $C_ACCENT; $b.FlatAppearance.BorderColor = $C_ACCENT }
  }
}
function Set-Btn($b, $text, $kind, [bool]$enabled, [bool]$visible = $true) { $b.Text = $text; $b.Tag = $kind; $b.Visible = $visible; $b.Enabled = $enabled; Style-Btn $b $kind }
function New-Box($parent, $x, $y, $w, $h, $bg, $border) {
  $p = New-Object Windows.Forms.Panel
  $p.Location = "$x,$y"; $p.Size = "$w,$h"; $p.BackColor = $bg; $p.Tag = $border
  $p.Add_Paint({ param($s,$e) if ($s.Tag) { $pen = New-Object Drawing.Pen($s.Tag, 1); $e.Graphics.DrawRectangle($pen, 0, 0, $s.Width-1, $s.Height-1); $pen.Dispose() } })
  $parent.Controls.Add($p); $p
}

# ---------- main window ----------
$form = New-Object Windows.Forms.Form
$form.Text = "Registry Fix $Version"; $form.ClientSize = '760,566'; $form.StartPosition = 'CenterScreen'
$form.Font = F $FS_M; $form.BackColor = $C_WHITE; $form.FormBorderStyle = 'FixedSingle'; $form.MaximizeBox = $false
try {   # window icon: green rounded badge with a white pass-through arrow (drawn, no .ico needed)
  $ico = New-Object Drawing.Bitmap 64,64
  $ig = [Drawing.Graphics]::FromImage($ico); $ig.SmoothingMode = 'AntiAlias'; $ig.Clear([Drawing.Color]::Transparent)
  $ipath = New-Object Drawing.Drawing2D.GraphicsPath; $rd = 28
  $ipath.AddArc(2,2,$rd,$rd,180,90); $ipath.AddArc(62-$rd,2,$rd,$rd,270,90); $ipath.AddArc(62-$rd,62-$rd,$rd,$rd,0,90); $ipath.AddArc(2,62-$rd,$rd,$rd,90,90); $ipath.CloseFigure()
  $ig.FillPath((New-Object Drawing.SolidBrush $C_GREEN), $ipath)
  $ipen = New-Object Drawing.Pen ([Drawing.Color]::White), 7; $ipen.StartCap = 'Round'; $ipen.EndCap = 'Round'
  $ig.DrawLine($ipen, 15,32, 38,32)
  $ig.FillPolygon([Drawing.Brushes]::White, @((New-Object Drawing.Point 36,19),(New-Object Drawing.Point 52,32),(New-Object Drawing.Point 36,45)))
  $form.Icon = [Drawing.Icon]::FromHandle($ico.GetHicon())
} catch { $null = $_ }

New-Lbl $form 'Windows MAC Pass-Through' 22 12 600 38 (F $FS_XL $true) $C_TEXT | Out-Null
New-Lbl $form "Lets the dock or dongle take the laptop's MAC in Windows - a driver setting, the card itself is not changed." 24 52 712 22 (F $FS_M) $C_MUTED | Out-Null
New-Lbl $form 'Card' 24 88 44 28 (F $FS_M) $C_MUTED 'MiddleLeft' | Out-Null
$cmb = New-Object Windows.Forms.ComboBox
$cmb.Location = '70,88'; $cmb.Size = '540,28'; $cmb.DropDownStyle = 'DropDownList'; $cmb.Font = F $FS_M; $form.Controls.Add($cmb)
$btnRescan = New-Btn $form 'Rescan' 620 86 116 32; Set-Btn $btnRescan 'Rescan' 'outline' $true

$script:tiles = [ordered]@{}
$tileNames = [ordered]@{ Laptop = 'Laptop (BIOS)'; Driver = 'Card driver'; Result = 'In Windows now' }
$i = 0
foreach ($k in $tileNames.Keys) {
  $p = New-Box $form (20 + $i*244) 132 232 114 $C_SOFT $C_LINE
  $script:tiles[$k] = @{ Box = $p; Name = (New-Lbl $p $tileNames[$k] 14 10 210 22 (F $FS_M $true) $C_TEXT)
                         Big = (New-Lbl $p '' 14 34 210 40 (F $FS_XL $true) $C_IDLE); Why = (New-Lbl $p '' 14 80 210 22 (F $FS_M) $C_MUTED) }
  $i++
}

$act = New-Box $form 20 262 720 222 $C_WHITE $C_LINE
$aTitle = New-Lbl $act '' 16 14 680 28 (F $FS_L $true) $C_TEXT
$aBody  = New-Lbl $act '' 16 46 690 42 (F $FS_M) $C_TEXT
$aNote  = New-Lbl $act '' 16 90 690 22 (F $FS_M) $C_MUTED
$btnA1  = New-Btn $act '1   Preview' 16 118 120 34
$btnA2  = New-Btn $act '2   Apply fix' 146 118 160 34
$btnA3  = New-Btn $act 'Remove fix' 584 118 120 34

$aRes = New-Object Windows.Forms.Panel; $aRes.Location = '16,162'; $aRes.Size = '688,48'; $aRes.Visible = $false; $aRes.Tag = $C_ACCENT
$aRes.Add_Paint({ param($s,$e) $br = New-Object Drawing.SolidBrush($s.Tag); $e.Graphics.FillRectangle($br, 0, 0, 4, $s.Height); $br.Dispose() })
$act.Controls.Add($aRes)
$aResIcon = New-Lbl $aRes '' 12 0 26 48 (F $FS_L $true) $C_ACCENT 'MiddleCenter'
$aResHead = New-Lbl $aRes '' 42 5 640 20 (F $FS_M $true) $C_TEXT
$aResText = New-Lbl $aRes '' 42 25 640 20 (F $FS_M) $C_MUTED

$lblScope = New-Lbl $form 'Windows only: pre-boot / PXE and Linux need the card itself to carry the marker (see RtlPassthru).' 24 494 712 20 (F $FS_S) $C_MUTED
$btnDetails = New-Btn $form 'Details' 16 520 110 32; Set-Btn $btnDetails ('Details  ' + [char]0x25BE) 'link' $true
$btnSave    = New-Btn $form 'Save report' 132 520 120 32; Set-Btn $btnSave 'Save report' 'link' $true

$BASE_H = 566
$detBox = New-Object Windows.Forms.RichTextBox; $detBox.Location = '20,560'; $detBox.Size = '720,300'; $detBox.ReadOnly = $true
$detBox.BorderStyle = 'FixedSingle'; $detBox.BackColor = $C_WHITE; $detBox.Visible = $false; $form.Controls.Add($detBox)

$statusStrip = New-Object Windows.Forms.StatusStrip; $statusStrip.SizingGrip = $false; $statusStrip.BackColor = $C_SOFT; $statusStrip.Font = F $FS_S
$statusLbl = New-Object Windows.Forms.ToolStripStatusLabel; $statusLbl.Text = 'Ready.'
$statusStrip.Items.Add($statusLbl) | Out-Null; $form.Controls.Add($statusStrip)
function Set-Status($text, $color) { $statusLbl.Text = $text; $statusLbl.ForeColor = $(if ($color) { $color } else { $C_TEXT }); $statusStrip.Refresh() }

function Set-Result($kind, $head = '', $text = '') {
  if (-not $kind) { $aRes.Visible = $false; return }
  $map = @{ ok = @($C_GREEN, $C_GREENBG, [char]0x2714); info = @($C_ACCENT, $C_INFOBG, [char]0x2192)
            warn = @($C_AMBER, $C_AMBERBG, '!'); err = @($C_RED, $C_REDBG, [char]0x2716); hint = @($C_MUTED, $C_SOFT, 'i') }
  $c = $map[$kind]
  $aRes.Tag = $c[0]; $aRes.BackColor = $c[1]; $aResIcon.ForeColor = $c[0]; $aResIcon.Text = [string]$c[2]
  $aResHead.Text = $head; $aResHead.ForeColor = $c[0]; $aResText.Text = $text; $aResText.ForeColor = $C_TEXT
  $aRes.Visible = $true; $aRes.Invalidate()
}
function Set-Tile($key, $state, $big, $why) {
  $t = $script:tiles[$key]
  switch ($state) {
    'yes'  { $t.Box.BackColor = $C_GREENBG; $t.Box.Tag = $C_GREEN; $t.Big.ForeColor = $C_GREEN; $t.Big.Text = ([char]0x2714 + '  ' + $big) }
    'no'   { $t.Box.BackColor = $C_REDBG;   $t.Box.Tag = $C_RED;   $t.Big.ForeColor = $C_RED;   $t.Big.Text = ([char]0x2716 + '  ' + $big) }
    'warn' { $t.Box.BackColor = $C_AMBERBG; $t.Box.Tag = $C_AMBER; $t.Big.ForeColor = $C_AMBER; $t.Big.Text = ('!  ' + $big) }
    default { $t.Box.BackColor = $C_SOFT;   $t.Box.Tag = $C_LINE;  $t.Big.ForeColor = $C_IDLE;  $t.Big.Text = $big }
  }
  $t.Why.Text = $why; $t.Box.Invalidate()
}

# ---------- state ----------
function Read-All {
  if ($script:DemoMode) { $d = Demo-State $script:demoState; $script:cards = $d.Cards; $script:fw = $d.Fw }
  else { $script:cards = @(Get-Cards | ForEach-Object { Get-CardInfo $_ }); $script:fw = Get-Firmware }
}
function Current { if ($script:cards.Count -and $cmb.SelectedIndex -ge 0) { $script:cards[$cmb.SelectedIndex] } else { $null } }

function Show-State {
  $c = Current; $fw = $script:fw
  Set-Result ''; $aTitle.ForeColor = $C_TEXT; $aNote.ForeColor = $C_MUTED; $aNote.Text = ''
  Set-Btn $btnA1 '1   Preview' 'outline' $false $false; Set-Btn $btnA2 '2   Apply fix' 'primary' $false $false; Set-Btn $btnA3 'Remove fix' 'outline' $false $false
  # laptop
  if ($fw.Mac) { Set-Tile 'Laptop' 'yes' 'PUBLISHES' ('its MAC  ' + (Format-Mac $fw.Mac)) }
  elseif ($fw.Supported) { Set-Tile 'Laptop' 'warn' 'TURNED OFF' 'switch it on in BIOS setup' }
  else { Set-Tile 'Laptop' 'no' 'NO' 'no pass-through in this BIOS' }
  if (-not $c) {
    Set-Tile 'Driver' 'idle' '-' 'no Realtek USB card found'; Set-Tile 'Result' 'idle' '-' ''
    $aTitle.Text = 'Plug in the dock or dongle'; $aBody.Text = 'No Realtek USB network card is connected. Plug it in and press Rescan.'
    Set-Status 'No card.' $C_MUTED; return
  }
  if ($c.Realtek) { Set-Tile 'Driver' 'yes' 'REALTEK' $c.Service } else { Set-Tile 'Driver' 'no' 'OTHER' ($c.Service + ' - needs Realtek''s') }
  $works = $fw.Mac -and ($c.Mac -eq (Format-Mac $fw.Mac))
  $fix = $c.SetN -eq $RECIPE.Count
  if ($works) { Set-Tile 'Result' 'yes' 'WORKS' "the card has the laptop's MAC" }
  elseif ($fw.Mac) { Set-Tile 'Result' 'no' 'NO' "the card has its own MAC" }
  else { Set-Tile 'Result' 'idle' '-' "the card has its own MAC" }
  if ($c.ManualMac) { $aNote.Text = "Note: a manual MAC ($($c.ManualMac)) is set for this card in its driver settings - it overrides pass-through."; $aNote.ForeColor = $C_AMBER }

  if ($works -and $fix) {
    $aTitle.Text = 'Works - with the fix'; $aTitle.ForeColor = $C_GREEN
    $aBody.Text = "The fix is set for this card and the card has the laptop's MAC. Remove it to go back to the card's own MAC."
    Set-Btn $btnA3 'Remove fix' 'outline' $true; Set-Status 'Works, with the fix.' $C_GREEN
  } elseif ($works) {
    $aTitle.Text = 'Nothing to do'; $aTitle.ForeColor = $C_GREEN
    $aBody.Text = "The card already takes the laptop's MAC on its own - no fix needed."
    Set-Status 'Works without the fix.' $C_GREEN
  } elseif (-not $fw.Mac) {
    if ($fw.Supported) {
      $aTitle.Text = 'Switch it on in BIOS first'
      $aBody.Text = "This laptop can do pass-through, but it is turned off. Enable 'MAC Address Pass-Through' in BIOS setup, restart, then press Rescan."
    } else {
      $aTitle.Text = 'This laptop has no MAC pass-through'
      $aBody.Text = "Its BIOS publishes no pass-through MAC, so there is nothing for the card to take. The card is not the problem; the fix cannot help here."
    }
    if ($fix) { Set-Btn $btnA3 'Remove fix' 'outline' $true; $aNote.Text = 'The fix is still set for this card - it does nothing here; you can remove it.' }
    Set-Status 'Waiting for the BIOS.' $C_AMBER
  } elseif (-not $c.Realtek) {
    $aTitle.Text = 'Needs the Realtek driver'
    $aBody.Text = "The card runs on '$($c.Service)'. The fix is a Realtek driver setting - install Realtek's USB Ethernet driver (Windows Update usually offers it), then Rescan."
    Set-Status 'Needs the Realtek driver.' $C_AMBER
  } elseif ($fix) {
    $aTitle.Text = 'The fix is set - re-plug the card'
    $aBody.Text = 'The driver reads these settings when the card starts. Unplug the dock or dongle, plug it back in, then press Rescan.'
    Set-Btn $btnA3 'Remove fix' 'outline' $true
    Set-Result 'hint' 'Not taken up yet' 'Do not disable / enable the adapter in Windows - unplug and re-plug the card.'
    Set-Status 'Fix set, waiting for a re-plug.' $C_AMBER
  } else {
    $aTitle.Text = "Turn on pass-through in Windows"
    $aBody.Text = "The laptop publishes its MAC, but this card's driver does not take it. The fix sets four Realtek driver values for this card only."
    $aNote.Text = 'Reversible: Remove fix puts the card back. Windows only.'
    Set-Btn $btnA1 '1   Preview' 'outline' $true; Set-Btn $btnA2 '2   Apply fix' 'primary' $false
    Set-Result 'hint' 'Start with Preview' 'It shows the registry key and the four values - nothing is written. Apply unlocks after it.'
    Set-Status 'Ready to apply the fix.' $C_ACCENT
  }
}

function Refresh-All {
  $form.Cursor = 'WaitCursor'; Set-Status 'Reading...' $C_MUTED
  try {
    Read-All
    $sel = $cmb.SelectedIndex; $cmb.Items.Clear()
    foreach ($c in $script:cards) { [void]$cmb.Items.Add(("{0}  |  {1}  |  {2}" -f ($c.Desc -replace ' Family Controller',''), $c.Mac, $c.Chip)) }
    if ($cmb.Items.Count) { $cmb.SelectedIndex = [Math]::Max(0, [Math]::Min($sel, $cmb.Items.Count - 1)) } else { Show-State }
  } finally { $form.Cursor = 'Default' }
  if ($script:detOpen) { Fill-Details }
}

function Key-Path($c) { if ($c.Key.PSChildName) { "HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-...}\$($c.Key.PSChildName)" } else { '(not found)' } }

function Preview {
  $c = Current; if (-not $c) { return }
  if (-not $c.Key) { Set-Result 'err' 'The driver key of this card was not found' 'Nothing written.'; return }
  $script:previewOk = $true
  Set-Result 'info' ('Ready to apply  -  nothing written yet') ("Key \" + $c.Key.PSChildName + "   " + [char]0x00B7 + "   EnableManualCloneMAC=1, AUXMacType=3, AUXMacSupportVer=1, EnableCloneMAC=1")
  Set-Btn $btnA2 '2   Apply fix' 'primary' $true
}
function Apply-Fix {
  $c = Current; if (-not $c -or -not $script:previewOk) { return }
  if (-not (Test-Admin) -and -not $script:DemoMode) { Set-Result 'err' 'Not running as administrator' 'Start it with Registry-Fix.bat - nothing written.'; return }
  try {
    if (-not $script:DemoMode) { foreach ($n in $RECIPE.Keys) { New-ItemProperty $c.Key.PSPath -Name $n -Value $RECIPE[$n] -PropertyType DWord -Force | Out-Null } }
    Refresh-All
    Set-Result 'ok' 'Fix applied' 'Now unplug the dock or dongle and plug it back in, then press Rescan.'
  } catch { Set-Result 'err' 'Could not write the fix' "$_" }
}
function Remove-Fix {
  $c = Current; if (-not $c -or -not $c.Key) { return }
  if (-not (Test-Admin) -and -not $script:DemoMode) { Set-Result 'err' 'Not running as administrator' 'Start it with Registry-Fix.bat - nothing changed.'; return }
  $r = [Windows.Forms.MessageBox]::Show("Remove the fix from this card?`n`nThe four Realtek driver values are deleted; after a re-plug the card uses its own MAC again.", 'Remove fix', 'YesNo', 'Question')
  if ($r -ne [Windows.Forms.DialogResult]::Yes) { return }
  try {
    if (-not $script:DemoMode) { foreach ($n in $RECIPE.Keys) { Remove-ItemProperty $c.Key.PSPath -Name $n -ErrorAction SilentlyContinue } }
    Refresh-All
    Set-Result 'ok' 'Fix removed' 'Unplug and re-plug the card to go back to its own MAC.'
  } catch { Set-Result 'err' 'Could not remove the fix' "$_" }
}

# ---------- details and report ----------
function Detail-Text {
  $c = Current; $fw = $script:fw; $nl = "`r`n"
  $s = "LAPTOP (BIOS, ACPI DSDT)$nl"
  $s += "  pass-through feature : " + $(if ($fw.Mac) { 'on' } elseif ($fw.Supported) { 'present, turned off' } else { 'not present' }) + $nl
  $s += "  published MAC        : " + $(if ($fw.Mac) { Format-Mac $fw.Mac } else { '-' }) + "$nl$nl"
  if (-not $c) { return $s + "CARD$nl  none found$nl" }
  $s += "CARD$nl  $($c.Desc)$nl  Windows name  : $($c.Name)$nl  chip (USB ID) : $($c.Chip)$nl  MAC now       : $($c.Mac)$nl"
  $s += "  driver        : $($c.Service)" + $(if ($c.Realtek) { '  (Realtek)' } else { '  (not Realtek - the fix needs it)' }) + $nl
  $s += "  link          : $($c.Link)$nl"
  if ($c.ManualMac) { $s += "  manual MAC    : $($c.ManualMac)  (NetworkAddress - overrides pass-through)$nl" }
  $s += "${nl}THE FIX (this card's driver key)$nl  $(Key-Path $c)$nl"
  foreach ($n in $RECIPE.Keys) {
    $v = $c.Values[$n]; $cur = if ($null -eq $v) { 'not set' } else { "$v" }
    $s += ("  {0,-22} = {1,-8} (fix: {2})" -f $n, $cur, $RECIPE[$n]) + $nl
  }
  $s += "  -> $($c.SetN) of $($RECIPE.Count) set$nl"
  $s
}
function Fill-Details { $detBox.Font = F $FS_M $false 'Consolas'; $detBox.Text = Detail-Text }
function Toggle-Details([bool]$open) {
  $script:detOpen = $open; $detBox.Visible = $open
  $form.ClientSize = "760,$(if ($open) { $BASE_H + 304 } else { $BASE_H })"
  $btnDetails.Text = 'Details  ' + $(if ($open) { [char]0x25B4 } else { [char]0x25BE })
  if ($open) { Fill-Details }
}
function Save-Report {
  $dlg = New-Object Windows.Forms.SaveFileDialog; $dlg.Filter = 'Text (*.txt)|*.txt'; $dlg.FileName = "registry-fix-report-$(Get-Date -Format yyyyMMdd-HHmm).txt"
  if ($dlg.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return }
  $txt = "Registry Fix $Version  -  $(Get-Date -Format 'yyyy-MM-dd HH:mm')`r`n`r`n" + (Detail-Text)
  [IO.File]::WriteAllText($dlg.FileName, $txt); Set-Status "Report saved: $($dlg.FileName)" $C_GREEN
}

# ---------- events ----------
$cmb.Add_SelectedIndexChanged({ $script:previewOk = $false; Show-State; if ($script:detOpen) { Fill-Details } })
$btnRescan.Add_Click({ Refresh-All })
$btnA1.Add_Click({ Preview })
$btnA2.Add_Click({ Apply-Fix })
$btnA3.Add_Click({ Remove-Fix })
$btnDetails.Add_Click({ Toggle-Details (-not $script:detOpen) })
$btnSave.Add_Click({ Save-Report })

# ---------- start ----------
$script:demoState = $(switch ($State) { 'preview' { 'ready' } 'applied' { 'not-loaded' } 'details' { 'works-fix' } default { $State } })
$script:detOpen = $false; $script:previewOk = $false
Refresh-All
if (-not $script:DemoMode -and -not (Test-Admin)) { Set-Status 'Not running as administrator - reading only. Start it with Registry-Fix.bat to apply or remove the fix.' $C_AMBER }

if ($Screenshot) {
  switch ($State) {
    'preview' { Preview }
    'applied' { $script:previewOk = $true; Set-Result 'ok' 'Fix applied' 'Now unplug the dock or dongle and plug it back in, then press Rescan.' }
    'details' { Toggle-Details $true }
  }
  $form.Opacity = 0; $form.ShowInTaskbar = $false; $form.Show(); [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 300; [Windows.Forms.Application]::DoEvents()
  $bmp = New-Object Drawing.Bitmap($form.Width, $form.Height); $form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)))
  $bmp.Save($Screenshot, [Drawing.Imaging.ImageFormat]::Png); $form.Close(); Write-Output "saved $Screenshot"
} else { [void]$form.ShowDialog() }
