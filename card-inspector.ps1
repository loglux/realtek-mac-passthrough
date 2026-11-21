<#
  RtlPassthru - Realtek USB NIC MAC pass-through: inspect and fix.
  Reads a Realtek USB NIC chip and tells you - in plain English - whether the dock can do MAC
  pass-through, why, and what to do - and can burn the AUX-clone efuse bit to fix it.
  Backend: tools/diag.py (registers) and tools/efuse.py (efuse read/dump/burn), one unified DLL layer.
  Run as ADMIN (Card-Inspector.bat self-elevates):  powershell.exe -STA -File card-inspector.ps1
  -Demo renders the UI with synthetic data (no hardware, no vendor DLL). -Screenshot <png> [-State red|green|dry|efuse]
  saves one state to a PNG (implies -Demo) - used to produce the sanitized screenshots in the docs.
#>
param([switch]$Demo, [string]$Screenshot = '', [ValidateSet('red','green','dry','efuse')][string]$State = 'red')
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$ErrorActionPreference = 'Stop'
$TOOLS = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'tools'
$PY  = 'python'
$Version = '0.1.0'
$script:DemoMode = $Demo.IsPresent -or ($Screenshot -ne '')
$DEMO_RED_GUID   = '{11111111-1111-1111-1111-111111111111}'
$DEMO_GREEN_GUID = '{22222222-2222-2222-2222-222222222222}'

# ---- theme ----
$C_BG     = [Drawing.Color]::FromArgb(246,247,249)
$C_PANEL  = [Drawing.Color]::White
$C_TEXT   = [Drawing.Color]::FromArgb(33,37,41)
$C_MUTED  = [Drawing.Color]::FromArgb(108,114,124)
$C_ACCENT = [Drawing.Color]::FromArgb(37,99,235)
$C_GREEN  = [Drawing.Color]::FromArgb(34,160,80)
$C_RED    = [Drawing.Color]::FromArgb(206,64,64)
$C_AMBER  = [Drawing.Color]::FromArgb(200,150,40)
$F_BODY   = New-Object Drawing.Font('Segoe UI',9)
$F_MONO   = New-Object Drawing.Font('Consolas',9.5)
$F_BTN    = New-Object Drawing.Font('Segoe UI',9,[Drawing.FontStyle]::Bold)

function Get-Cards {
  if ($script:DemoMode) {
    return @(
      [pscustomobject]@{ Name='Ethernet';   Pid='8156'; Status='Up'; Mac='00-11-22-33-44-55'; Guid=$DEMO_RED_GUID;   Desc='Realtek USB 2.5GbE Family Controller' },
      [pscustomobject]@{ Name='Ethernet 3'; Pid='8156'; Status='Up'; Mac='00-11-22-33-44-66'; Guid=$DEMO_GREEN_GUID; Desc='Realtek USB 2.5GbE Family Controller' }
    )
  }
  Get-NetAdapter | Where-Object { $_.PnPDeviceID -match 'VID_0BDA&PID_815' } | ForEach-Object {
    $ppid = ([regex]::Match($_.PnPDeviceID,'PID_(\w+)')).Groups[1].Value
    [pscustomobject]@{ Name=$_.Name; Pid=$ppid; Status=$_.Status; Mac=$_.MacAddress; Guid=$_.InterfaceGuid; Desc=$_.InterfaceDescription }
  }
}

# synthetic tool output for -Demo / -Screenshot: matches the real diag.py / efuse.py / dll_list.py formats
# that the GUI parses, with fully made-up data (no hardware, no real MAC) so docs carry no personal data.
function Demo-Py($script, $argline) {
  $green = $argline -like "*$DEMO_GREEN_GUID*"
  switch -Wildcard ($script) {
    'dll_list.py' { return "new`t216`tok`t5.0.0.2`tdll\new\RtlDirectDiagLib64.dll" }
    'diag.py' {
      # demo chip = an -AD variant (like the WAVLINK RTL8156): green = burned 0x03, red = blank 0x00
      $cf = if ($green) { '0x03' } else { '0x00' }
      $b0 = if ($green) { 1 } else { 0 }; $b1 = $b0
      $yn = if ($green) { 'YES' } else { 'NO ' }
      $aux = if ($green) { 'AUX-clone bit (0xCFDB bit1) is set' } else { 'AUX-clone bit (0xCFDB bit1) is not set' }
      $lin = if ($green) { 'RTL8153-AD variant, and 0xCFDB bit0 is set' } else { 'RTL8153-AD variant, but 0xCFDB bit0 is not set' }
      $pxe = if ($green) { 'both clone bits set - 0x03 verified at pre-boot on a Dell' } else { $aux }
      return (@(
        "GUID (demo)",
        "DLL Direct_API v5.0.0.2 (216 procedures)  dll\new\RtlDirectDiagLib64.dll",
        "bcdDevice(REV) = 0x3000",
        "  0xD81A USB_MISC_0 = 0x1000",
        "  0xD81F USB_MISC_1 = 0x00",
        ("  0xCFDB EFUSE(PASS_THRU) = {0}   bit0(RT-clone)={1}  bit1(AUX-clone)={2}" -f $cf,$b0,$b1),
        "  chip variant (r8152) = AD",
        ("PASSTHRU Windows = {0}  ({1})" -f $yn,$aux),
        ("PASSTHRU PXE     = {0}  ({1})" -f $yn,$pxe),
        ("PASSTHRU Linux   = {0}  ({1})" -f $yn,$lin),
        "  storage DC00 = 0x00   SPI flash ID = 00 00 00",
        "CONFIG STORAGE = efuse only (one-time) - no SPI flash found; EEPROM not probed"
      ) -join "`r`n")
    }
    'efuse.py' {
      if ($argline -like '*--plan*') {
        return (@(
          "append point (dword-aligned): 0x40 (dwaddr 0x10)",
          "current dword @0x40 = 0xFFFFFFFF",
          "record to write: 40 CF DB 03  (0xCFDB = 0x03)",
          "dword to write @0x40: 0x03DBCF40",
          "after burn 0x40..0x43 = 40 CF DB 03, then 0x44=0xFF (0xFF=EOL)"
        ) -join "`r`n")
      }
      $rows = @(
        "0x000: 00 11 22 33 44 66 ff ff ff ff ff ff ff ff ff ff  |.`"3Df..........|",
        "0x010: ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff  |................|",
        "0x040: 40 cf db 03 ff ff ff ff ff ff ff ff ff ff ff ff  |@...............|"
      )
      $recs = @("  0x00: write [00 11 22 33 44 66] -> reg 0xC000  (IDR/MAC)")
      if ($green) { $recs += "  0x40: write [40 CF DB 03] -> reg 0xCFDB  (SW_FEATURE (MAC_CLONE/pass-through))   <<<" }
      return (($rows + 'records:' + $recs) -join "`r`n")
    }
  }
  return ''
}

function Run-Py($script, $argline) {
  if ($script:DemoMode) { return (Demo-Py $script $argline) }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $PY
  $psi.Arguments = "-I `"$TOOLS\$script`" $argline"
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $p = [System.Diagnostics.Process]::Start($psi)
  $out = $p.StandardOutput.ReadToEnd(); $err = $p.StandardError.ReadToEnd(); $p.WaitForExit()
  return ($out + $err)
}

function Chip-Name($p) { switch ($p) { '8156' {'RTL8156 (2.5G)'} '8153' {'RTL8153 (1G)'} default {"RTL$p"} } }

function Read-CFDB($guid) {
  $dr = Run-Py 'diag.py' "`"$guid`" --dll $(Burn-Dll)"
  $m = [regex]::Match($dr,'0xCFDB\s+EFUSE[^=]*=\s*(0x[0-9A-Fa-f]+)')
  if ($m.Success) { return [Convert]::ToInt32($m.Groups[1].Value,16) } else { return -1 }
}

function Split-Efuse($out) {
  # efuse.py already decodes the records (efuse_core.parse_autoload_records, covered by pytest);
  # the GUI only splits its output. Hex rows: "0xNNN: ..".  Record lines: "  0xNN: write [..] -> reg 0x..".
  $hex  = ($out -split "`r?`n" | Where-Object { $_ -match '^0x[0-9A-Fa-f]{3}:' }) -join "`r`n"
  $recs = ($out -split "`r?`n" | Where-Object { $_ -match '^\s+0x[0-9A-Fa-f]+:\s+write' }) -join "`r`n"
  return @{ Hex = $hex; Records = $recs }
}

# ---------- UI ----------
function Style-Btn($b,[bool]$primary) {
  $b.FlatStyle='Flat'; $b.Font=$F_BTN; $b.Cursor='Hand'; $b.Height=30
  if ($primary) { $b.BackColor=$C_ACCENT; $b.ForeColor=[Drawing.Color]::White; $b.FlatAppearance.BorderSize=0 }
  else { $b.BackColor=$C_PANEL; $b.ForeColor=$C_ACCENT; $b.FlatAppearance.BorderColor=$C_ACCENT; $b.FlatAppearance.BorderSize=1 }
}

function Set-Status($text,$color) {
  $statusLbl.Text = $text
  $statusLbl.ForeColor = if ($color) { $color } else { $C_TEXT }
  $statusStrip.Refresh()
}

function Set-FixEnabled([bool]$red) {
  $btnDry.Enabled = $red
  $btnBurn.Enabled = $red
  Style-Burn
}

function Style-Burn {
  # gray while locked, filled red once armed - the destructive action clearly lights up when it's live
  if ($btnBurn.Enabled) {
    $btnBurn.BackColor = $C_RED; $btnBurn.ForeColor = [Drawing.Color]::White; $btnBurn.FlatAppearance.BorderColor = $C_RED
  } else {
    $btnBurn.BackColor = [Drawing.Color]::FromArgb(238,240,243); $btnBurn.ForeColor = [Drawing.Color]::FromArgb(160,160,160); $btnBurn.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(205,209,214)
  }
}

# selected Diag DLL from the top picker: 'new'/'old'/'auto', or a quoted explicit path from Locate...
function Sel-Dll {
  $a = if ($cmbDll.SelectedIndex -ge 0 -and $script:dllItems.Count -gt $cmbDll.SelectedIndex) { $script:dllItems[$cmbDll.SelectedIndex].Arg } else { 'auto' }
  if ($a -match '[\\:/]') { '"' + $a + '"' } else { $a }
}
function Burn-Dll     { Sel-Dll }
function Burn-Backend { switch (Sel-Dll) { 'new' {'Direct_API DLL'} 'old' {'API DLL'} 'auto' {'DLL'} default {'custom DLL'} } }
# always 0x03 (both clone bits, like a chip that ships enabled): 0x02 would turn Linux off on -AD chips
function Record-Hex   { '40 CF DB 03' }
function Target-Hex   { '0x03' }

$form = New-Object Windows.Forms.Form
$form.Text = "RtlPassthru $Version"; $form.Size = '788,860'; $form.StartPosition='CenterScreen'
$form.Font = $F_BODY; $form.BackColor=$C_BG; $form.FormBorderStyle='FixedSingle'; $form.MaximizeBox=$false

# window/taskbar icon: blue rounded badge with a white pass-through arrow (drawn, no external .ico needed)
try {
  $ico = New-Object Drawing.Bitmap 64,64
  $ig = [Drawing.Graphics]::FromImage($ico); $ig.SmoothingMode='AntiAlias'; $ig.Clear([Drawing.Color]::Transparent)
  $ipath = New-Object Drawing.Drawing2D.GraphicsPath; $rd=28
  $ipath.AddArc(2,2,$rd,$rd,180,90); $ipath.AddArc(62-$rd,2,$rd,$rd,270,90)
  $ipath.AddArc(62-$rd,62-$rd,$rd,$rd,0,90); $ipath.AddArc(2,62-$rd,$rd,$rd,90,90); $ipath.CloseFigure()
  $igrad = New-Object Drawing.Drawing2D.LinearGradientBrush (New-Object Drawing.Point 0,0), (New-Object Drawing.Point 0,64), $C_ACCENT, ([Drawing.Color]::FromArgb(29,78,216))
  $ig.FillPath($igrad, $ipath)
  $ipen = New-Object Drawing.Pen ([Drawing.Color]::White), 7; $ipen.StartCap='Round'; $ipen.EndCap='Round'
  $ig.DrawLine($ipen, 15,32, 38,32)
  $ihead = @((New-Object Drawing.Point 36,19),(New-Object Drawing.Point 52,32),(New-Object Drawing.Point 36,45))
  $ig.FillPolygon([Drawing.Brushes]::White, $ihead)
  $form.Icon = [Drawing.Icon]::FromHandle($ico.GetHicon())
  $ipen.Dispose(); $igrad.Dispose(); $ipath.Dispose(); $ig.Dispose()
} catch { $null = $_ }  # icon is cosmetic - never let it block startup

$title = New-Object Windows.Forms.Label
$title.Text='Realtek MAC Pass-Through'; $title.Location='16,12'; $title.Size='560,30'
$title.Font=New-Object Drawing.Font('Segoe UI',15,[Drawing.FontStyle]::Bold); $title.ForeColor=$C_TEXT
$form.Controls.Add($title)

$sub = New-Object Windows.Forms.Label
$sub.Text = 'Check whether a USB dock can clone the host''s MAC, and enable it when it can''t.'
$sub.Location='18,47'; $sub.Size='748,16'; $sub.ForeColor=$C_MUTED
$form.Controls.Add($sub)

$lbl = New-Object Windows.Forms.Label; $lbl.Text='Card'; $lbl.Location='16,80'; $lbl.AutoSize=$true; $lbl.ForeColor=$C_MUTED
$cmb = New-Object Windows.Forms.ComboBox; $cmb.Location='56,76'; $cmb.Size='496,26'; $cmb.DropDownStyle='DropDownList'; $cmb.FlatStyle='Flat'; $cmb.Font=$F_BODY
$btnRefresh = New-Object Windows.Forms.Button; $btnRefresh.Text='Rescan'; $btnRefresh.Location='560,74'; $btnRefresh.Size='78,30'
$btnRead = New-Object Windows.Forms.Button; $btnRead.Text='Read card'; $btnRead.Location='646,74'; $btnRead.Size='120,30'
Style-Btn $btnRefresh $false; Style-Btn $btnRead $true
$form.Controls.AddRange(@($lbl,$cmb,$btnRefresh,$btnRead))

# owner-draw the combo so the closed field is dark-on-white (readable), dropdown selection is accent/white
$cmb.DrawMode='OwnerDrawFixed'; $cmb.ItemHeight=18
$cmb.Add_DrawItem({
  param($s,$e)
  if ($e.Index -lt 0) { return }
  $isEdit = ($e.State -band [Windows.Forms.DrawItemState]::ComboBoxEdit) -ne 0
  $sel = (-not $isEdit) -and (($e.State -band [Windows.Forms.DrawItemState]::Selected) -ne 0)
  $bg = if ($sel) { $C_ACCENT } else { [Drawing.Color]::White }
  $fg = if ($sel) { [Drawing.Color]::White } else { $C_TEXT }
  $e.Graphics.FillRectangle((New-Object Drawing.SolidBrush $bg), $e.Bounds)
  [Windows.Forms.TextRenderer]::DrawText($e.Graphics, [string]$s.Items[$e.Index], $s.Font, $e.Bounds, $fg, ([Windows.Forms.TextFormatFlags]::Left -bor [Windows.Forms.TextFormatFlags]::VerticalCenter))
})

# --- Diag DLL row (which DLL to use for reading + efuse; auto-detected by command set, or Locate...) ---
$lblDll = New-Object Windows.Forms.Label; $lblDll.Text='Diag DLL'; $lblDll.Location='16,116'; $lblDll.AutoSize=$true; $lblDll.ForeColor=$C_MUTED
$cmbDll = New-Object Windows.Forms.ComboBox; $cmbDll.Location='84,112'; $cmbDll.Size='300,24'; $cmbDll.DropDownStyle='DropDownList'; $cmbDll.FlatStyle='Flat'; $cmbDll.Font=$F_BODY
$btnLocate = New-Object Windows.Forms.Button; $btnLocate.Text='Locate...'; $btnLocate.Location='392,111'; $btnLocate.Size='90,26'
Style-Btn $btnLocate $false
$lblDllHint = New-Object Windows.Forms.Label; $lblDllHint.Text='auto-detected by command set'; $lblDllHint.Location='492,116'; $lblDllHint.AutoSize=$true; $lblDllHint.ForeColor=$C_MUTED
$form.Controls.AddRange(@($lblDll,$cmbDll,$btnLocate,$lblDllHint))
$cmbDll.DrawMode='OwnerDrawFixed'; $cmbDll.ItemHeight=18
$cmbDll.Add_DrawItem({
  param($s,$e)
  if ($e.Index -lt 0) { return }
  $isEdit = ($e.State -band [Windows.Forms.DrawItemState]::ComboBoxEdit) -ne 0
  $sel = (-not $isEdit) -and (($e.State -band [Windows.Forms.DrawItemState]::Selected) -ne 0)
  $bg = if ($sel) { $C_ACCENT } else { [Drawing.Color]::White }
  $fg = if ($sel) { [Drawing.Color]::White } else { $C_TEXT }
  $e.Graphics.FillRectangle((New-Object Drawing.SolidBrush $bg), $e.Bounds)
  [Windows.Forms.TextRenderer]::DrawText($e.Graphics, [string]$s.Items[$e.Index], $s.Font, $e.Bounds, $fg, ([Windows.Forms.TextFormatFlags]::Left -bor [Windows.Forms.TextFormatFlags]::VerticalCenter))
})

$banner = New-Object Windows.Forms.Label
$banner.Location='16,152'; $banner.Size='750,40'; $banner.TextAlign='MiddleCenter'
$banner.Font=New-Object Drawing.Font('Segoe UI',12.5,[Drawing.FontStyle]::Bold); $banner.Text=''; $banner.BackColor=$C_BG
$form.Controls.Add($banner)

$grid = New-Object Windows.Forms.RichTextBox
$grid.Location='16,202'; $grid.Size='750,286'; $grid.ReadOnly=$true
$grid.Font=New-Object Drawing.Font('Segoe UI',10); $grid.BackColor=$C_PANEL; $grid.BorderStyle='FixedSingle'
$form.Controls.Add($grid)

function Add-Txt($rtb,$text,$color,[bool]$bold,$size,[bool]$mono=$false) {
  $rtb.SelectionStart = $rtb.TextLength; $rtb.SelectionLength = 0
  $rtb.SelectionColor = $color
  $fs  = if ($bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }
  $fam = if ($mono) { 'Consolas' } else { 'Segoe UI' }
  $rtb.SelectionFont = New-Object Drawing.Font($fam, $size, $fs)
  $rtb.AppendText($text)
}

$btnEf = New-Object Windows.Forms.Button; $btnEf.Text='Show efuse dump'; $btnEf.Location='16,496'; $btnEf.Size='190,30'
Style-Btn $btnEf $false
$btnSave = New-Object Windows.Forms.Button; $btnSave.Text='Save report'; $btnSave.Location='216,496'; $btnSave.Size='150,30'
Style-Btn $btnSave $false
$form.Controls.AddRange(@($btnEf,$btnSave))

# --- Permanent fix: value radios (row A) + two explicit steps with an arming checkbox (row B) ---
$grpFix = New-Object Windows.Forms.GroupBox
$grpFix.Text = 'Permanent fix  -  burn the AUX bit into efuse  (OTP, one-time, IRREVERSIBLE)'
$grpFix.Location='16,534'; $grpFix.Size='738,88'; $grpFix.ForeColor=$C_TEXT
# row A: what gets written (fixed - no choice to get wrong on an irreversible burn)
$lblVal = New-Object Windows.Forms.Label; $lblVal.Text='Writes 0xCFDB = 0x03  (AUX + RT, as on a chip that ships enabled - Windows, pre-boot, and Linux on -AD chips)'; $lblVal.Location='12,26'; $lblVal.AutoSize=$true; $lblVal.ForeColor=$C_TEXT
# row B: the two steps
$btnDry = New-Object Windows.Forms.Button; $btnDry.Text='1.  Dry run (no burn)'; $btnDry.Location='12,54'; $btnDry.Size='180,26'
Style-Btn $btnDry $false
$btnBurn = New-Object Windows.Forms.Button; $btnBurn.Text='2.  Burn AUX bit'; $btnBurn.Location='556,54'; $btnBurn.Size='170,26'
$btnBurn.FlatStyle='Flat'; $btnBurn.Font=$F_BTN; $btnBurn.Cursor='Hand'; $btnBurn.FlatAppearance.BorderSize=1
$btnDry.Enabled=$false; $btnBurn.Enabled=$false
$grpFix.Controls.AddRange(@($lblVal,$btnDry,$btnBurn))
$form.Controls.Add($grpFix)

$ef = New-Object Windows.Forms.TextBox
$ef.Location='16,630'; $ef.Size='738,150'; $ef.Multiline=$true; $ef.ScrollBars='Vertical'
$ef.Font=$F_MONO; $ef.ReadOnly=$true; $ef.Visible=$false; $ef.BackColor=$C_PANEL; $ef.BorderStyle='FixedSingle'
$form.Controls.Add($ef)

$statusStrip = New-Object Windows.Forms.StatusStrip
$statusLbl = New-Object Windows.Forms.ToolStripStatusLabel
$statusLbl.Text = 'Ready - pick a card and press Read card.'
$statusStrip.Items.Add($statusLbl) | Out-Null
$form.Controls.Add($statusStrip)

function Load-Dlls {
  $cmbDll.Items.Clear(); $script:dllItems = @()
  $out = Run-Py 'dll_list.py' ''
  foreach ($line in ($out -split "`r?`n")) {
    $p = $line -split "`t"
    if ($p.Count -ge 5 -and ($p[0] -eq 'new' -or $p[0] -eq 'old')) {
      $famTxt = if ($p[0] -eq 'new') { 'Direct_API' } else { 'API' }
      $stat = if ($p[2] -eq 'ok') { "all 8 commands present ($($p[1]) exports)" } else { $p[2] }
      $script:dllItems += @{ Label = "$famTxt  -  v$($p[3])  -  $stat"; Arg = $p[0] }
    }
  }
  foreach ($it in $script:dllItems) { [void]$cmbDll.Items.Add($it.Label) }
  if ($cmbDll.Items.Count) { $cmbDll.SelectedIndex=0 }
  else { [void]$cmbDll.Items.Add('no diag DLL found - use Locate...'); $script:dllItems=@(@{Label='none';Arg='auto'}); $cmbDll.SelectedIndex=0 }
}

function Locate-Dll {
  $dlg = New-Object Windows.Forms.OpenFileDialog
  $dlg.Filter = 'RtlDirectDiagLib64.dll|RtlDirectDiagLib64.dll|DLL files (*.dll)|*.dll'
  $start = Join-Path (Split-Path $TOOLS -Parent) 'dll'
  $dlg.InitialDirectory = if (Test-Path $start) { $start } else { Split-Path $TOOLS -Parent }
  if ($dlg.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return }
  $path = $dlg.FileName
  # classify the chosen file by its command set (same logic as auto-detect) - no meaningless "Custom"
  $p = (((Run-Py 'dll_list.py' "`"$path`"") -split "`r?`n")[0]) -split "`t"
  if ($p.Count -ge 5 -and ($p[0] -eq 'new' -or $p[0] -eq 'old') -and $p[2] -eq 'ok') {
    $famTxt = if ($p[0] -eq 'new') { 'Direct_API' } else { 'API' }
    $script:dllItems += @{ Label = "$famTxt (located)  -  v$($p[3])  -  all 8 commands present ($($p[1]) exports)"; Arg = $path }
    [void]$cmbDll.Items.Add($script:dllItems[-1].Label)
    $cmbDll.SelectedIndex = $cmbDll.Items.Count - 1
    $script:rpt=$null; Set-FixEnabled $false
    Set-Status ("Located {0} DLL: {1}" -f $famTxt, $path) $C_GREEN
  } elseif ($p.Count -ge 5 -and ($p[0] -eq 'new' -or $p[0] -eq 'old')) {
    $fam = if ($p[0] -eq 'new') { 'Direct_API' } else { 'API' }
    [Windows.Forms.MessageBox]::Show(("This looks like the {0} diag API, but required commands are missing:`n  {1}`n`nNot usable - pick a complete RtlDirectDiagLib64.dll." -f $fam, ($p[2] -replace '^missing:','')), 'Locate DLL', 'OK', 'Warning') | Out-Null
    Set-Status 'Located DLL is incomplete (missing commands).' $C_AMBER
  } else {
    [Windows.Forms.MessageBox]::Show("That file is not a Realtek diag DLL (it has neither the API_ nor the Direct_API_ command set).`n`n$path", 'Locate DLL', 'OK', 'Warning') | Out-Null
    Set-Status 'Located file is not a diag DLL.' $C_AMBER
  }
}

function Refresh-List {
  $script:rpt=$null; if ($btnDry) { Set-FixEnabled $false }
  $cmb.Items.Clear()
  $banner.Text='scanning cards...'; $banner.BackColor=[Drawing.Color]::Gainsboro; $banner.ForeColor=$C_TEXT; $form.Refresh()
  $script:cards = @(Get-Cards)
  foreach ($c in $script:cards) {
    $cf = Read-CFDB $c.Guid
    $pt = if ($cf -lt 0) {'(unread - run as admin)'} elseif ((($cf -shr 1) -band 1) -eq 1) {"PASS-THROUGH: YES  (0xCFDB=0x{0:X2})" -f $cf} else {"needs burn  (0xCFDB=0x{0:X2})" -f $cf}
    [void]$cmb.Items.Add(("{0}  |  {1}  |  {2}" -f ($c.Desc -replace ' Family Controller',''),$c.Mac,$pt))
  }
  $banner.Text=''; $banner.BackColor=$C_BG
  if ($cmb.Items.Count) { $cmb.SelectedIndex=0 }
}

function Read-Card {
  if ($cmb.SelectedIndex -lt 0) { return }
  $c = $script:cards[$cmb.SelectedIndex]
  $banner.Text='reading...'; $banner.BackColor=[Drawing.Color]::Gainsboro; $banner.ForeColor=$C_TEXT
  $grid.Text=''; $ef.Text=''; $ef.Visible=$false; Set-Status 'Reading the card...' $C_TEXT; $form.Refresh()

  $dr = Run-Py 'diag.py' "`"$($c.Guid)`" --dll $(Burn-Dll)"
  $rev  = ([regex]::Match($dr,'bcdDevice\(REV\)\s*=\s*(0x[0-9A-Fa-f]+)')).Groups[1].Value
  $cfdb = ([regex]::Match($dr,'0xCFDB\s+EFUSE[^=]*=\s*(0x[0-9A-Fa-f]+)')).Groups[1].Value
  $m0   = ([regex]::Match($dr,'0xD81A\s+USB_MISC_0\s*=\s*(0x[0-9A-Fa-f]+)')).Groups[1].Value
  $m1   = ([regex]::Match($dr,'0xD81F\s+USB_MISC_1\s*=\s*(0x[0-9A-Fa-f]+)')).Groups[1].Value

  $cf = -1; if ($cfdb) { $cf=[Convert]::ToInt32($cfdb,16) }
  if ($cf -lt 0) {
    $banner.Text='READ FAILED  (run as admin? card connected?)'; $banner.BackColor=$C_AMBER; $banner.ForeColor=[Drawing.Color]::White
    $grid.Text = $dr; $script:rpt=$null; Set-FixEnabled $false; Set-Status 'Read failed - run as admin and check the card is connected.' $C_AMBER; return
  }
  $bit0 = $cf -band 1; $bit1 = ($cf -shr 1) -band 1
  $pass = ($bit1 -eq 1)        # Windows / PXE gate = the AUX bit, the one thing this tool can fix

  # per-layer verdict from diag.py (passthru.py): each layer checks a different marker
  $variant = ([regex]::Match($dr,'chip variant \(r8152\)\s*=\s*(\S+)')).Groups[1].Value
  $layers = [ordered]@{}
  foreach ($mm in [regex]::Matches($dr,'PASSTHRU\s+(\w+)\s*=\s*(YES|NO|\?)\s+\((.*)\)')) {
    $v = $mm.Groups[2].Value          # YES / NO / ? (not measured)
    $layers[$mm.Groups[1].Value] = @{ Ok = ($v -eq 'YES'); Val = $v; Why = $mm.Groups[3].Value }
  }
  $lin = if ($layers.Contains('Linux')) { $layers['Linux'].Ok } else { $false }
  $stor = ([regex]::Match($dr,'CONFIG STORAGE\s*=\s*(.+)')).Groups[1].Value.Trim()
  if (-not $stor) { $stor = '(not reported)' }
  $vtxt = switch ($variant) { 'AD' {'RTL8153-AD'} 'BND' {'RTL8153-BND'} 'BD' {'RTL8153-BD'} 'Lenovo' {'Lenovo chip'} default {'none (a plain chip)'} }

  $banner.Text = if ($pass -and $lin) {'SUPPORTS MAC PASS-THROUGH  -  Windows, PXE and Linux'}
                 elseif ($pass)       {'SUPPORTS MAC PASS-THROUGH  -  Windows and PXE (not Linux)'}
                 else                 {'NOT SUPPORTED on Windows / PXE  -  AUX clone bit missing (needs burn)'}
  $banner.BackColor = if ($pass) {$C_GREEN} else {$C_RED}
  $banner.ForeColor = [Drawing.Color]::White

  $grid.Clear()
  # --- plain-language headline ---
  if ($pass) { Add-Txt $grid "This dock CAN take your laptop's network identity (MAC).`r`n`r`n" $C_GREEN $true 13 $false }
  else       { Add-Txt $grid "This dock CANNOT do it yet - it needs a one-time fix.`r`n`r`n"     $C_RED   $true 13 $false }

  # --- the summary first: one line per layer ---
  if ($layers.Count -gt 0) {
    Add-Txt $grid "PASS-THROUGH BY SYSTEM`r`n" $C_ACCENT $true 10.5 $false
    Add-Txt $grid "  each layer checks a different marker on the card`r`n" $C_MUTED $false 9 $false
    foreach ($k in @('Windows','PXE','Linux')) {
      if (-not $layers.Contains($k)) { continue }
      $L = $layers[$k]
      $label = if ($k -eq 'PXE') {'Pre-boot/PXE'} else {$k}
      $col = switch ($L.Val) { 'YES' {$C_GREEN} '?' {$C_AMBER} default {$C_RED} }
      Add-Txt $grid ("  {0,-13}{1,-5}{2}`r`n" -f $label, $L.Val, $L.Why) $col $true 10 $true
    }
    Add-Txt $grid "`r`n" $C_TEXT $false 6 $false
  }

  # --- device ---
  Add-Txt $grid "DEVICE`r`n" $C_ACCENT $true 10.5 $false
  Add-Txt $grid ("  {0}`r`n" -f $c.Desc)                         $C_TEXT $false 10 $true
  Add-Txt $grid ("  Windows name : {0}`r`n" -f $c.Name)          $C_TEXT $false 10 $true
  Add-Txt $grid ("  MAC address  : {0}`r`n" -f $c.Mac)           $C_TEXT $false 10 $true
  Add-Txt $grid ("  Chip         : {0}, rev {1}`r`n" -f (Chip-Name $c.Pid),$rev) $C_TEXT $false 10 $true
  Add-Txt $grid ("  Settings in  : {0}`r`n`r`n" -f $stor) $C_TEXT $false 10 $true

  # --- capability byte, full breakdown ---
  Add-Txt $grid "CAPABILITY  -  register 0xCFDB`r`n" $C_ACCENT $true 10.5 $false
  Add-Txt $grid "  the chip's MAC-clone capability byte, loaded from efuse at every power-on`r`n" $C_MUTED $false 9 $false
  Add-Txt $grid ("  0xCFDB = {0}`r`n" -f $cfdb) $C_TEXT $false 10 $true
  Add-Txt $grid ("  bit0  RT-clone  = {0}   Realtek's own clone mode; also the bit Linux checks on -AD chips`r`n" -f $bit0) $C_TEXT $false 10 $true
  if ($pass) { Add-Txt $grid ("  bit1  AUX-clone = {0}   standard firmware pass-through  <= THIS is the one that matters`r`n" -f $bit1) $C_GREEN $true 10 $true }
  else       { Add-Txt $grid ("  bit1  AUX-clone = {0}   standard firmware pass-through  <= MISSING (this is why it fails)`r`n" -f $bit1) $C_RED   $true 10 $true }
  $concl = if ($pass) {'  => AUX-clone is SET: Windows and pre-boot take the host (laptop) MAC automatically.'} `
                 else {'  => AUX-clone is NOT set: Windows and pre-boot keep the dock''s own MAC.'}
  Add-Txt $grid ($concl + "`r`n`r`n") $C_TEXT $false 10 $true

  # --- the second marker: chip variant (what Linux checks) ---
  Add-Txt $grid "CHIP VARIANT  -  what Linux (r8152) checks`r`n" $C_ACCENT $true 10.5 $false
  Add-Txt $grid "  set at the factory in the USB_MISC registers - a different marker from 0xCFDB`r`n" $C_MUTED $false 9 $false
  Add-Txt $grid ("  USB_MISC_0 = {0}    USB_MISC_1 = {1}`r`n" -f $m0,$m1) $C_TEXT $false 10 $true
  $vcol = if ($variant -and $variant -ne 'none') {$C_GREEN} else {$C_TEXT}
  Add-Txt $grid ("  variant    = {0}`r`n`r`n" -f $vtxt) $vcol $true 10 $true

  # --- verdict / what to do ---
  Add-Txt $grid "VERDICT`r`n" $C_ACCENT $true 10.5 $false
  if ($pass -and $lin) {
    Add-Txt $grid "  SUPPORTS MAC pass-through on Windows, pre-boot/PXE and Linux - no action needed." $C_GREEN $true 10.5 $false
  } elseif ($pass) {
    Add-Txt $grid "  SUPPORTS MAC pass-through on Windows and pre-boot/PXE - no action needed there.`r`n" $C_GREEN $true 10.5 $false
    Add-Txt $grid "  Linux: r8152 only accepts factory chip variants (-AD / -BND / -BD / Lenovo). This chip is not one of them, and that marker is set at the factory - the burn here cannot add it." $C_TEXT $false 10 $false
  } else {
    Add-Txt $grid "  NOT supported on Windows / pre-boot - the AUX-clone bit is not set in the chip.`r`n" $C_RED $true 10.5 $false
    Add-Txt $grid "  To fix permanently: burn the AUX-clone bit with the 'Permanent fix' box below (one-time, IRREVERSIBLE)." $C_TEXT $false 10 $false
    if ($variant -eq 'AD') {
      Add-Txt $grid "`r`n  This is an -AD chip: the burn writes 0x03 (both bits), so Linux will accept it too." $C_TEXT $false 10 $false
    }
  }

  $lay = ($layers.Keys | ForEach-Object { '{0}={1}' -f $_, $layers[$_].Val }) -join '  '
  $script:rpt = [ordered]@{ Desc=$c.Desc; Name=$c.Name; Mac=$c.Mac; Chip=(Chip-Name $c.Pid); Rev=$rev; Cfdb=$cfdb; Bit0=$bit0; Bit1=$bit1; M0=$m0; M1=$m1; Pass=$pass; Guid=$c.Guid; Variant=$vtxt; Layers=$lay; Storage=$stor }
  Set-FixEnabled (-not $pass)
  if ($pass) { Set-Status ("Read OK: 0xCFDB=$cfdb - pass-through supported, nothing to do.") $C_GREEN }
  else       { Set-Status ("Read OK: 0xCFDB=$cfdb - pass-through OFF. Use the 'Permanent fix' area below to burn the AUX bit.") $C_RED }
}

function Show-Efuse {
  if ($cmb.SelectedIndex -lt 0) { return }
  $c = $script:cards[$cmb.SelectedIndex]
  $ef.Visible=$true; $ef.Text='reading efuse...'; $form.Refresh()
  $out = Run-Py 'efuse.py' "`"$($c.Guid)`" 160 --dll $(Burn-Dll)"
  $s = Split-Efuse $out
  $decoded = if ($s.Records) { $s.Records } else { '(no efuse records - run as admin? card connected?)' }
  $ef.Text = "DECODED  (each line = a value the chip writes into a register at power-on; <<< marks the pass-through byte):`r`n$decoded`r`n`r`nRAW HEX:`r`n$($s.Hex)"
}

function Save-Report {
  if (-not $script:rpt) { Read-Card }
  if (-not $script:rpt) { Set-Status 'Nothing to save - read a card first.' $C_AMBER; return }
  $r = $script:rpt
  Set-Status 'Building report (reading efuse)...' $C_TEXT
  $efout = Run-Py 'efuse.py' "`"$($r.Guid)`" 160 --dll $(Burn-Dll)"
  $s = Split-Efuse $efout
  $decoded = if ($s.Records) { $s.Records } else { '(efuse not read)' }
  $hex = $s.Hex
  $verdict = if ($r.Pass) { 'SUPPORTS MAC pass-through - no action needed.' } else { 'NOT supported - AUX-clone bit (0xCFDB bit1) missing; needs an efuse burn.' }
  $txt = @"
RtlPassthru $Version - report
Generated : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

DEVICE     : $($r.Desc)
Windows    : $($r.Name)
MAC        : $($r.Mac)
Chip       : $($r.Chip), rev $($r.Rev)
Settings in: $($r.Storage)

0xCFDB     = $($r.Cfdb)
  bit0 RT-clone  = $($r.Bit0)   (Realtek's own clone mode; also the bit Linux checks on -AD chips)
  bit1 AUX-clone = $($r.Bit1)   (standard _AUXMAC_ pass-through; what Windows and pre-boot check)
USB_MISC_0 = $($r.M0)    USB_MISC_1 = $($r.M1)
CHIP VARIANT (r8152) : $($r.Variant)
PASS-THROUGH         : $($r.Layers)

VERDICT    : $verdict

--- efuse (decoded) ---
$decoded

--- efuse (raw hex) ---
$hex
"@
  $dlg = New-Object Windows.Forms.SaveFileDialog
  $dlg.Filter = 'Text file (*.txt)|*.txt'
  $dlg.FileName = ("card-report-{0}-{1}.txt" -f ($r.Mac -replace '[:-]',''), (Get-Date -Format 'yyyyMMdd-HHmm'))
  if ($dlg.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
    [IO.File]::WriteAllText($dlg.FileName, $txt, (New-Object Text.UTF8Encoding($false)))
    Set-Status ("Report saved: {0}" -f $dlg.FileName) $C_GREEN
  } else {
    Set-Status 'Save cancelled.' $C_TEXT
  }
}

function Dry-Run {
  if (-not $script:rpt -or $script:rpt.Pass) { return }
  $r = $script:rpt
  Set-Status ("Dry run via {0} - reading efuse, locating the free slot (nothing is written)..." -f (Burn-Backend)) $C_TEXT
  $dry = Run-Py 'efuse.py' "`"$($r.Guid)`" --plan --dll $(Burn-Dll)"
  $cur = ([regex]::Match($dry,'@0x[0-9A-Fa-f]+ = (0x[0-9A-Fa-f]{8})')).Groups[1].Value
  $dwd = ([regex]::Match($dry,'@0x[0-9A-Fa-f]+: (0x[0-9A-Fa-f]{8})')).Groups[1].Value
  $rng = ([regex]::Match($dry,'(0x[0-9A-Fa-f]+)\.\.0x[0-9A-Fa-f]+ =')).Groups[1].Value
  $ef.Visible=$true
  if ($cur -eq '0xFFFFFFFF' -and $rng -and $dwd) {
    $ef.Text = @(
      "DRY RUN   -   backend: $(Burn-Backend)   -   nothing was written.",
      "",
      "Append point  : $rng   (dword-aligned, at the end of autoload)",
      "Current value : $cur   (0xFFFFFFFF = free -> OK to write here)",
      "Would write   : dword $dwd  =  record  $(Record-Hex)   ->  0xCFDB = $(Target-Hex)",
      "",
      "Nothing burned. To proceed: press '2. Burn AUX bit' (you'll confirm once more in a dialog)."
    ) -join "`r`n"
    Set-Status "Dry run OK: would append $(Record-Hex) at $rng (slot is free). Nothing burned." $C_TEXT
  } else {
    $ef.Text = "DRY RUN - could not confirm a free slot (append point not 0xFFFFFFFF, or read failed).`r`n`r`n(raw tool output)`r`n$dry"
    Set-Status 'Dry run: append point is not free or read failed - see efuse panel.' $C_AMBER
  }
}

function Burn-Card {
  if (-not $script:rpt -or $script:rpt.Pass) { return }
  $r = $script:rpt

  # re-check the free slot right before burning
  Set-Status 'Checking the free slot before burn...' $C_TEXT
  $dry = Run-Py 'efuse.py' "`"$($r.Guid)`" --plan --dll $(Burn-Dll)"
  $cur = ([regex]::Match($dry,'@0x[0-9A-Fa-f]+ = (0x[0-9A-Fa-f]{8})')).Groups[1].Value
  $dwd = ([regex]::Match($dry,'@0x[0-9A-Fa-f]+: (0x[0-9A-Fa-f]{8})')).Groups[1].Value
  $rng = ([regex]::Match($dry,'(0x[0-9A-Fa-f]+)\.\.0x[0-9A-Fa-f]+ =')).Groups[1].Value
  if (-not $cur -or -not $dwd -or $cur -ne '0xFFFFFFFF') {
    $ef.Visible=$true; $ef.Text="BURN - could not confirm a free slot (append point not 0xFFFFFFFF, or read failed).`r`n`r`n(raw tool output)`r`n$dry"
    Set-Status 'Cannot burn - append point not free (see efuse panel).' $C_RED
    [Windows.Forms.MessageBox]::Show("Can't burn: the append point is not free (0xFFFFFFFF), or the read failed.`n`nDetails are in the efuse panel.", 'Burn', 'OK', 'Warning') | Out-Null
    return
  }

  $msg = "About to BURN the AUX-clone bit into this card's efuse.`n`n" +
         "Card    : $($r.Desc)`n" +
         "MAC     : $($r.Mac)`n" +
         "Now     : 0xCFDB = $($r.Cfdb)   (pass-through OFF)`n" +
         "Backend : $(Burn-Backend)`n`n" +
         "It will append the record  $(Record-Hex)  at efuse offset $rng`n" +
         "(writes dword $dwd into free space; factory data is NOT touched).`n`n" +
         "This is a ONE-TIME, IRREVERSIBLE write (OTP efuse).`n" +
         "Keep the card plugged in and still until it finishes.`n`n" +
         "Proceed with the burn?"
  $ans = [Windows.Forms.MessageBox]::Show($msg, 'Confirm efuse burn (IRREVERSIBLE)', 'YesNo', 'Warning', 'Button2')
  if ($ans -ne [Windows.Forms.DialogResult]::Yes) { Set-Status 'Burn cancelled.' $C_TEXT; return }

  $btnDry.Enabled=$false; $btnBurn.Enabled=$false; Style-Burn
  $btnRead.Enabled=$false; $btnRefresh.Enabled=$false; $btnSave.Enabled=$false
  Set-Status ("BURNING via {0} - do NOT unplug the card..." -f (Burn-Backend)) $C_RED
  $out = Run-Py 'efuse.py' "`"$($r.Guid)`" --burn --dll $(Burn-Dll)"
  $btnRead.Enabled=$true; $btnRefresh.Enabled=$true; $btnSave.Enabled=$true
  $ef.Visible=$true
  $back = ([regex]::Match($out,'read-back @0x[0-9A-Fa-f]+ = (0x[0-9A-Fa-f]{8})')).Groups[1].Value
  if ($back -and $back -eq $dwd) {
    $ef.Text = @(
      "BURN   -   backend: $(Burn-Backend)   -   OK.",
      "",
      "Wrote record $(Record-Hex) at $rng.",
      "Read-back = $back   ->   matches (0xCFDB will load as $(Target-Hex) after re-plug).",
      "",
      "Now UNPLUG and re-plug the card, then press Rescan."
    ) -join "`r`n"
    Set-Status 'Burn verified OK. UNPLUG and re-plug the card, then press Rescan.' $C_GREEN
    [Windows.Forms.MessageBox]::Show("Burn verified OK - the efuse now carries 0xCFDB = $(Target-Hex).`n`nUNPLUG and re-plug the card (power-cycle) so it reloads the efuse, then press Rescan. It should read as SUPPORTED.", 'Burn complete', 'OK', 'Information') | Out-Null
  } else {
    $ef.Text = "BURN did NOT verify (read-back '$back' did not match '$dwd').`r`n`r`n(raw tool output)`r`n$out"
    Set-FixEnabled $true
    Set-Status 'Burn did NOT verify - see efuse panel.' $C_RED
    [Windows.Forms.MessageBox]::Show("The burn did not verify (read-back did not match).`n`nThe card is not harmed - writes go only to free space. You can re-plug and try again.`n`nOutput is in the efuse panel.", 'Burn failed', 'OK', 'Warning') | Out-Null
  }
}

$btnRefresh.Add_Click({ try { Refresh-List } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'Rescan error') } })
$btnRead.Add_Click({ try { Read-Card } catch { $grid.Text = "ERROR: $($_.Exception.Message)" } })
$btnEf.Add_Click({ try { Show-Efuse } catch { $ef.Visible=$true; $ef.Text="ERROR: $($_.Exception.Message)" } })
$btnSave.Add_Click({ try { Save-Report } catch { Set-Status "Save error: $($_.Exception.Message)" $C_RED } })
$btnDry.Add_Click({ try { Dry-Run } catch { $ef.Visible=$true; $ef.Text="ERROR: $($_.Exception.Message)" } })
$btnBurn.Add_Click({ try { Burn-Card } catch { $btnRead.Enabled=$true; $btnRefresh.Enabled=$true; $btnSave.Enabled=$true; Set-Status "Burn error: $($_.Exception.Message)" $C_RED } })
$cmb.Add_SelectedIndexChanged({ $script:rpt=$null; Set-FixEnabled $false })
$cmbDll.Add_SelectedIndexChanged({ $script:rpt=$null; Set-FixEnabled $false })
$btnLocate.Add_Click({ try { Locate-Dll } catch { Set-Status "Locate error: $($_.Exception.Message)" $C_RED } })

if ($Screenshot) {
  # render one demo state to a PNG for the docs. DrawToBitmap renders every standard control reliably but
  # leaves a RichTextBox blank, so we paint the RichTextBox ($grid) ourselves with EM_FORMATRANGE (the Win32
  # way to print a rich-edit to a DC). Fully off-screen and private - it never captures the desktop.
  Add-Type @'
using System; using System.Runtime.InteropServices;
public static class RtbPrint {
  [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, IntPtr l);
  [DllImport("gdi32.dll")] static extern int GetDeviceCaps(IntPtr hdc, int idx);
  [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] struct CHARRANGE { public int cpMin, cpMax; }
  [StructLayout(LayoutKind.Sequential)] struct FORMATRANGE { public IntPtr hdc, hdcTarget; public RECT rc, rcPage; public CHARRANGE chrg; }
  const int EM_FORMATRANGE = 0x0439; const int LOGPIXELSX = 88; const int LOGPIXELSY = 90;
  public static void Paint(IntPtr hwnd, IntPtr hdc, int l, int t, int r, int b) {
    int dx = GetDeviceCaps(hdc, LOGPIXELSX); if (dx <= 0) dx = 96;
    int dy = GetDeviceCaps(hdc, LOGPIXELSY); if (dy <= 0) dy = 96;
    var fr = new FORMATRANGE();
    fr.hdc = hdc; fr.hdcTarget = hdc;
    fr.rc = new RECT { Left = l*1440/dx, Top = t*1440/dy, Right = r*1440/dx, Bottom = b*1440/dy }; fr.rcPage = fr.rc;
    fr.chrg = new CHARRANGE { cpMin = 0, cpMax = -1 };
    IntPtr p = Marshal.AllocHGlobal(Marshal.SizeOf(fr));
    Marshal.StructureToPtr(fr, p, false);
    SendMessage(hwnd, EM_FORMATRANGE, (IntPtr)1, p);
    SendMessage(hwnd, EM_FORMATRANGE, IntPtr.Zero, IntPtr.Zero);
    Marshal.FreeHGlobal(p);
  }
}
'@
  $cmb.DrawMode='Normal'; $cmbDll.DrawMode='Normal'   # native render = clean static capture
  $form.StartPosition='Manual'; $form.Location = New-Object Drawing.Point -3200,-3200
  $form.Show(); [Windows.Forms.Application]::DoEvents()
  Load-Dlls; Refresh-List; [Windows.Forms.Application]::DoEvents()
  switch ($State) {
    'green' { $cmb.SelectedIndex = 1; Read-Card }
    'dry'   { $cmb.SelectedIndex = 0; Read-Card; Dry-Run }
    'efuse' { $cmb.SelectedIndex = 1; Read-Card; Show-Efuse }
    default { $cmb.SelectedIndex = 0; Read-Card }
  }
  $form.ActiveControl = $null                          # drop the combo's focus highlight
  $form.Refresh(); [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 150; [Windows.Forms.Application]::DoEvents()
  # DrawToBitmap renders the whole window (title bar + border), so the client area is offset inside the bitmap;
  # EM_FORMATRANGE must paint the RichTextBox at that same offset or it rides up onto the banner.
  $ww = $form.Width; $wh = $form.Height
  $bmp = New-Object Drawing.Bitmap $ww, $wh
  $form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle 0,0,$ww,$wh))
  $pt = $form.PointToScreen([Drawing.Point]::new(0,0)); $ox = $pt.X - $form.Left; $oy = $pt.Y - $form.Top
  $g = [Drawing.Graphics]::FromImage($bmp); $hdc = $g.GetHdc()
  [RtbPrint]::Paint($grid.Handle, $hdc, ($grid.Left+$ox), ($grid.Top+$oy), ($grid.Right+$ox), ($grid.Bottom+$oy))
  $g.ReleaseHdc($hdc); $g.Dispose()
  $bmp.Save($Screenshot, [Drawing.Imaging.ImageFormat]::Png)
  $form.Close()
  return
}

try {
  Load-Dlls
  Refresh-List
  [void]$form.ShowDialog()
} catch {
  [Windows.Forms.MessageBox]::Show(($_.Exception.Message + "`n`n" + $_.ScriptStackTrace), 'Card Inspector - startup error')
}
