<#
  RtlPassthru - Realtek USB NIC MAC pass-through: inspect and fix.
  Main window: three tiles (Windows / Pre-boot / Linux) answer "does it work, and where"; one action card
  offers the fix that fits this card - burn the AUX bit into efuse (permanent) - or says honestly that
  nothing can be done. Details (inline, under the buttons): registers, markers and the settings dump.
  Backend (tools/): diag.py, settings.py, efuse.py, marker.py - one DLL layer (rtldiag.py).
  marker.py (the "Enable Linux" card on a plain RTL8153): proven with the V3 efuse protocol (RTL8153E);
  type 1 is not yet proven - the card says so before a burn.
  Run as ADMIN (Card-Inspector.bat self-elevates):  powershell.exe -STA -File card-inspector.ps1
  -Demo renders with synthetic data (no hardware, no vendor DLL, made-up MACs).
  -Screenshot <png> [-State red|green|plain|dry|details|efuse] saves one state to a PNG (implies -Demo).
#>
param([switch]$Demo, [string]$Screenshot = '',
      [ValidateSet('red','green','plain','dry','efuse','details','adpreview','adburning','addone','bothpreview','basicfunc')][string]$State = 'red')
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$ErrorActionPreference = 'Stop'
$ROOT    = Split-Path -Parent $MyInvocation.MyCommand.Path
$TOOLS   = Join-Path $ROOT 'tools'
$PY      = 'python'
$Version = '0.3.0'
$script:DemoMode = $Demo.IsPresent -or ($Screenshot -ne '')
$DEMO_RED_GUID   = '{11111111-1111-1111-1111-111111111111}'
$DEMO_GREEN_GUID = '{22222222-2222-2222-2222-222222222222}'
$DEMO_PLAIN_GUID = '{33333333-3333-3333-3333-333333333333}'   # a plain RTL8153 with a driver-disk flash
$script:demoAD = $false          # demo: has the -AD marker been "burned" into the plain RTL8153's efuse
$script:demoBare = $false        # demo: the plain RTL8153 without the clone bits (0xCFDB = 0x00) - both records offered
$script:demoBasic = $false       # demo: the burned RTL8156 as a BasicFunc card (USB revision 0x310F, EnableCloneMAC = 0)

# ---------- theme ----------
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
# type scale - the only font sizes the program uses (never a literal size elsewhere)
$FS_XL = 18     # window title, tile verdicts (WORKS / NO)
$FS_L  = 12     # action-card title, section headings in Details
$FS_M  = 10     # all body text: labels, buttons, reasons, results, dumps
$FS_S  = 9      # secondary info: storage line, DLL, status bar
function F($size, [bool]$bold = $false, $fam = 'Segoe UI') {
  New-Object Drawing.Font($fam, $size, $(if ($bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }))
}

# ---------- cards ----------
function Get-Cards {
  if ($script:DemoMode) {
    return @(
      [pscustomobject]@{ Name='Ethernet';   Pid='8156'; Mac='00-11-22-33-44-55'; Guid=$DEMO_RED_GUID;   Desc='Realtek USB 2.5GbE Family Controller' },
      [pscustomobject]@{ Name='Ethernet 3'; Pid='8156'; Mac='00-11-22-33-44-66'; Guid=$DEMO_GREEN_GUID; Desc='Realtek USB 2.5GbE Family Controller' },
      [pscustomobject]@{ Name='Ethernet 4'; Pid='8153'; Mac='00-11-22-33-44-AD'; Guid=$DEMO_PLAIN_GUID; Desc='Realtek USB GbE Family Controller' }
    )
  }
  Get-NetAdapter | Where-Object { $_.PnPDeviceID -match 'VID_0BDA&PID_815' } | ForEach-Object {
    $ppid = ([regex]::Match($_.PnPDeviceID,'PID_(\w+)')).Groups[1].Value
    [pscustomobject]@{ Name=$_.Name; Pid=$ppid; Mac=$_.MacAddress; Guid=$_.InterfaceGuid; Desc=$_.InterfaceDescription }
  }
}
function Chip-Name($p) { switch ($p) { '8156' {'RTL8156 (2.5G)'} '8153' {'RTL8153 (1G)'} default {"RTL$p"} } }

# ---------- demo backend: same output formats as the real tools, made-up data ----------
function Demo-Py($script, $argline) {
  $g = if ($argline -like "*$DEMO_GREEN_GUID*") {'green'} elseif ($argline -like "*$DEMO_PLAIN_GUID*") {'plain'} else {'red'}
  switch -Wildcard ($script) {
    'dll_list.py' { return "new`t216`tok`t5.0.0.2`tdll\new\RtlDirectDiagLib64.dll" }
    'diag.py' {
      if ($g -eq 'plain') {
        $m0 = if ($script:demoAD) {'0x1000'} else {'0x0000'}; $var = if ($script:demoAD) {'AD'} else {'none'}
        $lin = if ($script:demoAD) {'YES  (RTL8153-AD variant, and 0xCFDB bit0 is set)'} else {'NO   (not a chip variant r8152 recognises (no AD / BND / BD marker))'}
        $chip = if ($script:demoAD) {'RTL8153E (type 0x3106) + efuse record USB_MISC_0 (0xD81A) = 0x1000 (not a factory value)'} else {'RTL8153E (type 0x3106)'}
        return (@("GUID (demo)","DLL Direct_API v5.0.0.2 (216 procedures)  dll\new\RtlDirectDiagLib64.dll",
          "bcdDevice(REV) = 0x310D",("CHIP = $chip, efuse protocol = type 3 (V3)"),"  0xD81A USB_MISC_0 = $m0","  0xD81F USB_MISC_1 = 0x10",
          $(if ($script:demoBare) { "  0xCFDB EFUSE(PASS_THRU) = 0x00   bit0(RT-clone)=0  bit1(AUX-clone)=0" } else { "  0xCFDB EFUSE(PASS_THRU) = 0x03   bit0(RT-clone)=1  bit1(AUX-clone)=1" }),"  chip variant (r8152) = $var",
          $(if ($script:demoBare) { "PASSTHRU Windows = NO   (AUX-clone bit (0xCFDB bit1) is not set)" } else { "PASSTHRU Windows = YES  (AUX-clone bit (0xCFDB bit1) is set)" }),
          $(if ($script:demoBare) { "PASSTHRU PXE     = NO   (AUX-clone bit (0xCFDB bit1) is not set)" } else { "PASSTHRU PXE     = YES  (both clone bits set - 0x03 verified at pre-boot on a Dell)" }),
          "PASSTHRU Linux   = $lin",
          "  storage DC00 = 0x40   SPI flash ID = 85 60 15",
          "CONFIG STORAGE = efuse (one-time) - the SPI flash (PUYA 2 MB) holds the driver install disk, not settings",
          (DJ @{ tool='diag'; rev=0x310D; cfdb=$(if ($script:demoBare) {0} else {3}); usb_misc_0=$(if ($script:demoAD) {0x1000} else {0}); usb_misc_1=0x10
                 linux_variant=$(if ($script:demoAD) {'AD'} else {$null})
                 chip=@{ name=$chip; type=0x3106; variant=0x216; protocol='type 3 (V3)'; new_chip=$false }
                 dll=@{ family='Direct_API'; version='5.0.0.2'; exports=216; path='dll\new\RtlDirectDiagLib64.dll' }
                 layers=@{ Windows=@{ ok=(-not $script:demoBare); why=$(if ($script:demoBare) {'AUX-clone bit (0xCFDB bit1) is not set'} else {'AUX-clone bit (0xCFDB bit1) is set'}) }
                           PXE=@{ ok=(-not $script:demoBare); why=$(if ($script:demoBare) {'AUX-clone bit (0xCFDB bit1) is not set'} else {'both clone bits set - 0x03 verified at pre-boot on a Dell'}) }
                           Linux=@{ ok=[bool]$script:demoAD; why=($lin -replace '^\w+\s+\(|\)$','') } }
                 storage=@{ dc00=0x40; jedec='85 60 15'; text='efuse (one-time) - the SPI flash (PUYA 2 MB) holds the driver install disk, not settings' } })) -join "`r`n")
      }
      $green = $g -eq 'green'
      $cf = if ($green) {'0x03'} else {'0x00'}; $b = if ($green) {1} else {0}; $yn = if ($green) {'YES'} else {'NO '}
      $aux = if ($green) {'AUX-clone bit (0xCFDB bit1) is set'} else {'AUX-clone bit (0xCFDB bit1) is not set'}
      $lin = if ($green) {'RTL8153-AD variant, and 0xCFDB bit0 is set'} else {'RTL8153-AD variant, but 0xCFDB bit0 is not set'}
      $pxe = if ($green) {'both clone bits set - 0x03 verified at pre-boot on a Dell'} else {$aux}
      $bf = $green -and $script:demoBasic
      $winOk = $green -and -not $bf; $winWhy = if ($bf) {'the Windows driver has MAC clone switched off (EnableCloneMAC = 0, driver profile BasicFunc)'} else {$aux}
      $drv = if ($bf) { @{ profile='BasicFunc'; inf_section='RTL8156Bx64_BasicFunc.ndi.NT'; enable_clone_mac=$false } }
             else { @{ profile='Gaming'; inf_section='RTL8156Bx64.ndi.NT'; enable_clone_mac=$null } }
      return (@("GUID (demo)","DLL Direct_API v5.0.0.2 (216 procedures)  dll\new\RtlDirectDiagLib64.dll",
        ("bcdDevice(REV) = " + $(if ($bf) {'0x310F'} else {'0x3104'})),"CHIP = RTL8156BG (type 0x4102), efuse protocol = type 2 (dword)","  0xD81A USB_MISC_0 = 0x1000","  0xD81F USB_MISC_1 = 0x00",
        ("  0xCFDB EFUSE(PASS_THRU) = {0}   bit0(RT-clone)={1}  bit1(AUX-clone)={1}" -f $cf,$b),"  chip variant (r8152) = AD",
        ("PASSTHRU Windows = {0}  ({1})" -f $(if ($winOk) {'YES'} else {'NO '}),$winWhy),("PASSTHRU PXE     = {0}  ({1})" -f $yn,$pxe),("PASSTHRU Linux   = {0}  ({1})" -f $yn,$lin),
        "  storage DC00 = 0x00   SPI flash ID = 00 00 00","CONFIG STORAGE = efuse (one-time) - no external memory found; EEPROM not probed",
        (DJ @{ tool='diag'; rev=$(if ($bf) {0x310F} else {0x3104}); cfdb=$(if ($green) {3} else {0}); usb_misc_0=0x1000; usb_misc_1=0; linux_variant='AD'; driver=$drv
               chip=@{ name='RTL8156BG (type 0x4102)'; type=0x4102; variant=0x502; protocol='type 2 (dword)'; new_chip=$false }
               dll=@{ family='Direct_API'; version='5.0.0.2'; exports=216; path='dll\new\RtlDirectDiagLib64.dll' }
               layers=@{ Windows=@{ ok=$winOk; why=$winWhy }; PXE=@{ ok=$green; why=$pxe }; Linux=@{ ok=$green; why=$lin } }
               storage=@{ dc00=0; jedec='00 00 00'; text='efuse (one-time) - no external memory found; EEPROM not probed' } })) -join "`r`n")
    }
    'settings.py' {
      if ($g -eq 'plain') {
        # a plain RTL8153E (type 0x3106, efuse protocol V3) - the dongle the -AD marker was proven on, made-up MAC
        $recs = @("  0x000: write [00 11 22 33 44 AD] -> reg 0xC000  (MAC address)","  0x009: write [87 78] -> reg 0xDD90",
          "  0x00E: write [0D 31] -> reg 0xC054","  0x013: write [18 02 05 04] -> reg 0xE818  (programmed with Realtek's tool 2.24, CFG 1029)")
        $ef = if ($script:demoAD) {
          @('0x000: 25 c0 00 00 11 22 33 44 ad 21 dd 90 87 78 41 c0  |%...."3D.!...xA.|','0x010: 54 0d 31 23 e8 18 18 02 05 04 41 d8 1a 00 10 ff  |T.1#......A.....|',
            '0x020-0x0BF: all FF','0x0C0: ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff fe  |................|','records:') + $recs + @(
            "  0x01A: write [00 10] -> reg 0xD81A  (USB_MISC_0 - chip variant (AD marker))","in plain words:",
            "  0x000-0x01E  5 setting record(s), listed above; the chip applies them at power-on",
            "  0x01F-0x0C9  all FF = empty: never written (171 bytes free; FF is the blank state)",
            "  0x0CA-0x0CE  reserved by Realtek's tool - never used for records",
            "  0x0CF        FE = write counter: 1 programming session(s) by Realtek's tool (one bit burned per session)",
            "  MODIFIED: 1 record(s) added after the factory programming (not by Realtek's tool: no new stamp, and the write counter shows no extra session)",
            "  0x01A        added later: 0xD81A = 00 10 - the -AD marker RtlPassthru writes",
            "  no 0xCFDB record - the pass-through bits are the chip's own default",
            "  USB_MISC record - not a factory value: the chip applies it over its own chip-variant value",
            "               (now USB_MISC_0 = 0x1000, USB_MISC_1 = 0x10: Linux sees ""-AD"", Realtek calls the chip itself RTL8153E)")
        } else {
          @('0x000: 25 c0 00 00 11 22 33 44 ad 21 dd 90 87 78 41 c0  |%...."3D.!...xA.|','0x010: 54 0d 31 23 e8 18 18 02 05 04 ff ff ff ff ff ff  |T.1#............|',
            '0x020-0x0BF: all FF','0x0C0: ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff fe  |................|','records:') + $recs + @(
            "in plain words:",
            "  0x000-0x019  4 setting record(s), listed above; the chip applies them at power-on",
            "  0x01A-0x0C9  all FF = empty: never written (176 bytes free; FF is the blank state)",
            "  0x0CA-0x0CE  reserved by Realtek's tool - never used for records",
            "  0x0CF        FE = write counter: 1 programming session(s) by Realtek's tool (one bit burned per session)",
            "  FACTORY STATE: no records after the stamp of Realtek's tool - nothing was added since",
            "  no 0xCFDB record - the pass-through bits are the chip's own default",
            "  no USB_MISC record - the chip-variant value comes from the chip itself, not from these records",
            "               (USB_MISC_0 = 0x0000, USB_MISC_1 = 0x10: Linux sees a plain chip, Realtek calls it RTL8153E)")
        }
        $ff = 'ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff  |................|'
        $chip = if ($script:demoAD) {'RTL8153E (type 0x3106) + efuse record USB_MISC_0 (0xD81A) = 0x1000 (not a factory value)'} else {'RTL8153E (type 0x3106)'}
        return (@("GUID (demo)  (DLL: Direct_API v5.0.0.2, 216 procedures)","CHIP $chip","STORAGE efuse = responding (type 3 (V3) protocol)",
          "STORAGE flash = PUYA 2 MB - holds the driver install disk, not chip settings","",
          "=== EFUSE (208 bytes - the whole address space, one-time programmable) ===") + $ef + @("",
          "=== SPI FLASH (first 256 bytes) - driver install disk, not chip settings ===",
          "0x000: 06 02 00 00 00 08 00 00 ff ff ff ff ff ff ff ff  |................|","0x010: $ff","in plain words:",
          "  0x000-0x007  06 02 00 00 00 08 00 00  header of the driver install disk",
          "  0x008-...    FF = empty; the disk image itself starts at 0x1000 (not shown)",
          "  the chip does not load settings from this flash (RTL8153 datasheet 6.4: efuse or EEPROM only)") -join "`r`n")
      }
      # generated by settings.py from the demo efuse: made-up MAC, Realtek's stamp last, then (green) our 0xCFDB record
      $lines = @("GUID (demo)  (DLL: Direct_API v5.0.0.2, 216 procedures)","CHIP RTL8156BG (type 0x4102)","STORAGE efuse = responding (type 2 (dword) protocol)","STORAGE flash = none","",
        "=== EFUSE (2048 bytes - the whole address space, one-time programmable) ===")
      $lines += $(if ($g -eq 'green') { @(
        '0x000: 25 c0 00 00 11 22 33 44 66 42 d8 22 98 b3 a3 42  |%...."3DfB."...B|',
        '0x010: cf dc 20 00 64 40 cf db 01 23 d3 a0 13 02 04 04  |.. .d@...#......|',
        '0x020: 40 cf db 03 ff ff ff ff ff ff ff ff ff ff ff ff  |@...............|',
        '0x030-0x4FF: all FF',
        '0x500: ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff fe  |................|',
        '0x510-0x7FF: all FF',
        'records:',
        '  0x000: write [00 11 22 33 44 66] -> reg 0xC000  (MAC address)',
        '  0x009: write [98 B3 A3] -> reg 0xD822',
        '  0x00F: write [20 00 64] -> reg 0xCFDC',
        '  0x015: write [01] -> reg 0xCFDB  (SW_FEATURE - MAC clone / pass-through bits)',
        '  0x019: write [13 02 04 04] -> reg 0xD3A0  (programmed with Realtek''s tool 2.19, CFG 1028)',
        '  0x020: write [03] -> reg 0xCFDB  (SW_FEATURE - MAC clone / pass-through bits)',
        '  => 0xCFDB ends up as 0x03 (the last record wins)',
        'in plain words:',
        '  0x000-0x023  6 setting record(s), listed above; the chip applies them at power-on',
        '  0x024-0x507  all FF = empty: never written (1252 bytes free; FF is the blank state)',
        '  0x508-0x50E  reserved by Realtek''s tool - never used for records',
        '  0x50F        FE = write counter: 1 programming session(s) by Realtek''s tool (one bit burned per session)',
        '  MODIFIED: 1 record(s) added after the factory programming (not by Realtek''s tool: no new stamp, and the write counter shows no extra session)',
        '  0x020        added later: 0xCFDB = 03 - the pass-through bits RtlPassthru writes',
        '  no USB_MISC record - the chip-variant value comes from the chip itself, not from these records',
        '               (USB_MISC_0 = 0x1000, USB_MISC_1 = 0x00: Linux sees "-AD", Realtek calls it RTL8156BG)') }
                  else { @(
        '0x000: 25 c0 00 00 11 22 33 44 66 42 d8 22 98 b3 a3 42  |%...."3DfB."...B|',
        '0x010: cf dc 20 00 64 40 cf db 01 23 d3 a0 13 02 04 04  |.. .d@...#......|',
        '0x020-0x4FF: all FF',
        '0x500: ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff fe  |................|',
        '0x510-0x7FF: all FF',
        'records:',
        '  0x000: write [00 11 22 33 44 66] -> reg 0xC000  (MAC address)',
        '  0x009: write [98 B3 A3] -> reg 0xD822',
        '  0x00F: write [20 00 64] -> reg 0xCFDC',
        '  0x015: write [01] -> reg 0xCFDB  (SW_FEATURE - MAC clone / pass-through bits)',
        '  0x019: write [13 02 04 04] -> reg 0xD3A0  (programmed with Realtek''s tool 2.19, CFG 1028)',
        '  => 0xCFDB ends up as 0x01 (the last record wins)',
        'in plain words:',
        '  0x000-0x01F  5 setting record(s), listed above; the chip applies them at power-on',
        '  0x020-0x507  all FF = empty: never written (1256 bytes free; FF is the blank state)',
        '  0x508-0x50E  reserved by Realtek''s tool - never used for records',
        '  0x50F        FE = write counter: 1 programming session(s) by Realtek''s tool (one bit burned per session)',
        '  FACTORY STATE: no records after the stamp of Realtek''s tool - nothing was added since',
        '  no USB_MISC record - the chip-variant value comes from the chip itself, not from these records',
        '               (USB_MISC_0 = 0x1000, USB_MISC_1 = 0x00: Linux sees "-AD", Realtek calls it RTL8156BG)') })
      return ($lines -join "`r`n")
    }
    'marker.py' {
      $mj = @{ tool='marker'; burn=@{}; plan=@{ result='OK'; reason=''; record='41 D8 1A 00 10'; at=0x1A; protocol='type 3 (V3)'; proven=$true
                                                   records=@(@{ name='ad'; record='41 D8 1A 00 10'; at=0x1A }) } }
      if ($argline -like '*--records rev*') {
        $mj.plan = @{ result='OK'; reason=''; record='41 C0 0C 02 31'; at=0x24; protocol='type 2 (dword)'; proven=$false; experimental=$true
                      rev=@{ now=0x310F; new=0x3102; register=0xC00C }; records=@(@{ name='rev'; record='41 C0 0C 02 31'; at=0x24 }) }
        return ("PLAN rev = USB revision 0x310F -> 0x3102 in register 0xC00C`r`nPLAN RESULT = OK`r`n(read-only - nothing was written)`r`n" + (DJ $mj))
      }
      if ($script:demoBare -and $argline -like '*cfdb,ad*') {
        $mj.plan = @{ result='OK'; reason=''; record='40 CF DB 03  +  41 D8 1A 00 10'; at=0x1A; protocol='type 3 (V3)'; proven=$true
                      records=@(@{ name='cfdb'; record='40 CF DB 03'; at=0x1A }, @{ name='ad'; record='41 D8 1A 00 10'; at=0x1E }) }
        return ("PLAN record = 40 CF DB 03  at 0x1A`r`nPLAN record = 41 D8 1A 00 10  at 0x1E`r`nPLAN RESULT = OK`r`n(read-only - nothing was written)`r`n" + (DJ $mj))
      }
      if ($script:demoAD) {
        $mj.plan = @{ result='NOT_NEEDED'; reason='the chip already reports the -AD marker' }
        return ("USB_MISC_0 now = 0x1000   0xCFDB now = 0x03`r`nPLAN RESULT = NOT NEEDED (the chip already reports the -AD marker)`r`n" + (DJ $mj))
      }
      $plan = @("USB_MISC_0 now = 0x0000   0xCFDB now = 0x03","CHIP RTL8153E (type 0x3106), efuse protocol = type 3 (V3)","EFUSE = 208 bytes (type 3 (V3) protocol), records = 4, non-FF bytes = 27",
        "PLAN record = 41 D8 1A 00 10  (USB_MISC_0 = 0x1000, the -AD marker)","PLAN at = 0x1A",
        "PLAN byte 0x1B = 0xD8   0xDD00 <- 0x400DD8FF","PLAN byte 0x1C = 0x1A   0xDD00 <- 0x400EFF1A",
        "PLAN byte 0x1D = 0x00   0xDD00 <- 0x400E00FF","PLAN byte 0x1E = 0x10   0xDD00 <- 0x400FFF10",
        "PLAN byte 0x1A = 0x41   0xDD00 <- 0x400DFF41   (header, burned last - activates the record)",
        "PLAN V3 per byte (Realtek's tool 2.0.30): 0xE85B.0x10 and USB 0xD380 |= 0x0C for the session; efuse on; 0xDD00 bit27, wait; command, wait bit30; bit28, wait; efuse off; read back",
        "PLAN PROTOCOL = type 3 (V3) - proven on hardware","PLAN RESULT = OK")
      if ($argline -like '*--burn*') {
        $script:demoAD = $true
        return (($plan + "BURN byte 0x1B = 0xD8, read back 0xD8  OK" + "BURN byte 0x1C = 0x1A, read back 0x1A  OK" +
          "BURN byte 0x1D = 0x00, read back 0x00  OK" + "BURN byte 0x1E = 0x10, read back 0x10  OK" + "BURN byte 0x1A = 0x41, read back 0x41  OK" +
          "BURN RESULT = OK (record burned and verified at 0x1A; unplug and re-plug the card to load it)") -join "`r`n") + "`r`n" +
          (DJ $(& { $mj.burn = @{ result='OK'; reason='record burned and verified at 0x1A; unplug and re-plug the card to load it' }; $mj }))
      }
      return (($plan + "(read-only - nothing was written)" + (DJ $mj)) -join "`r`n")
    }
    'efuse.py' {
      $plan = @("append point (dword-aligned): 0x20 (dwaddr 0x8)","current dword @0x20 = 0xFFFFFFFF",
        "record to write: 40 CF DB 03  (0xCFDB = 0x03)","dword to write @0x20: 0x03DBCF40","after burn 0x20..0x23 = 40 CF DB 03, then 0x24=0xFF (0xFF=EOL)")
      $ej = @{ tool='efuse'; result='ready'; plan=@{ at=0x20; dwaddr=8; current=0xFFFFFFFF; dword=0x03DBCF40; record='40 CF DB 03'; free=$true; gap=$false } }
      if ($argline -like '*--burn*') {
        $ej.result = 'ok'; $ej.read_back = 0x03DBCF40
        return (($plan + "=== BURN (irreversible) ===" + "read-back @0x20 = 0x03DBCF40" + "RESULT: OK, matches" + (DJ $ej)) -join "`r`n")
      }
      return (($plan + "=== DRY RUN: nothing written. Add --burn to write. ===" + (DJ $ej)) -join "`r`n")
    }
  }
  return ''
}

function Run-Py($script, $argline) {
  if ($script:DemoMode) { return (Demo-Py $script $argline) }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $PY
  $psi.Arguments = "-I -u `"$TOOLS\$script`" $argline"            # -u: lines arrive as they are printed
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $p = [System.Diagnostics.Process]::Start($psi)
  # keep the window alive while the tool runs: read line by line, pump messages in between
  $errTask = $p.StandardError.ReadToEndAsync()
  $sb = New-Object System.Text.StringBuilder
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $lt = $p.StandardOutput.ReadLineAsync()
  while ($true) {
    if ($lt.IsCompleted) {
      $line = $lt.Result
      if ($null -eq $line) { break }
      [void]$sb.AppendLine($line)
      $m = [regex]::Match($line, '^STEP = (.+)$')
      if ($m.Success) { $script:progStep = $m.Groups[1].Value; $sw.Restart() }
      $lt = $p.StandardOutput.ReadLineAsync()
      continue
    }
    if ($script:progStep -and $aProg.Visible) { $aProgText.Text = "{0}   {1} s" -f $script:progStep, [int]$sw.Elapsed.TotalSeconds }
    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 40
  }
  $p.WaitForExit()
  return ($sb.ToString() + $errTask.Result)
}
function Rx($text, $pattern) { $m = [regex]::Match($text, $pattern); if ($m.Success) { $m.Groups[1].Value.Trim() } else { '' } }

# ---------- reading diag.py ----------
# The tools print human text, then (with --json) one last line "JSON {...}". Only that line is read here -
# by field name - so the wording of the human text can change without breaking the window.
function Get-Json($out) {
  $line = @(($out -split "`r?`n") | Where-Object { $_ -like 'JSON {*' }) | Select-Object -Last 1
  if (-not $line) { return $null }
  try { return ($line.Substring(5) | ConvertFrom-Json) } catch { return $null }
}
# demo: the JSON line a tool would print, from a hashtable
function DJ($h) { 'JSON ' + (ConvertTo-Json $h -Compress -Depth 6) }
# a tool that fails before it can report prints "ERROR: ..." (no JSON line) - shown to the user as is
function Tool-Error($out) { $m = [regex]::Match($out, '(?m)^ERROR: (.*)$'); if ($m.Success) { $m.Groups[1].Value.Trim() } else { '' } }
function Hex($n, $w) { if ($null -eq $n) { '' } else { '0x' + ([int64]$n).ToString("X$w") } }

function Parse-Diag($dr) {
  $d = [ordered]@{ Raw=$dr; Ok=$false }
  $j = Get-Json $dr
  if (-not $j -or $j.tool -ne 'diag') { return $d }
  $d.Ok = $true; $d.Cf = [int]$j.cfdb; $d.CfdbHex = Hex $j.cfdb 2
  $d.Bit0 = $d.Cf -band 1; $d.Bit1 = ($d.Cf -shr 1) -band 1
  $d.Rev = Hex $j.rev 4
  $d.Chip = $j.chip.name; $d.Proto = $(if ($j.chip.protocol) { $j.chip.protocol } else { 'unknown' })
  $d.M0 = Hex $j.usb_misc_0 4; $d.M1 = Hex $j.usb_misc_1 2
  $d.Variant = $(if ($j.linux_variant) { $j.linux_variant } else { 'none' })
  $d.Storage = $(if ($j.storage.text) { $j.storage.text } else { 'not reported' })
  $d.Dll = "$($j.dll.family) v$($j.dll.version) ($($j.dll.exports) procedures)"
  $d.Profile = $(if ($j.driver -and $j.driver.profile) { $j.driver.profile } else { '' })
  $d.InfSection = $(if ($j.driver -and $j.driver.inf_section) { $j.driver.inf_section } else { '' })
  $d.Clone = $(if ($j.driver) { $j.driver.enable_clone_mac } else { $null })
  $d.Layers = [ordered]@{}
  foreach ($k in 'Windows','PXE','Linux') {
    $L = $j.layers.$k
    $d.Layers[$k] = @{ Val = $(if ($L.ok -eq $true) { 'YES' } elseif ($L.ok -eq $false) { 'NO' } else { '?' }); Why = $L.why }
  }
  return $d
}

# plain-language reason under each tile
function Tile-Reason($layer, $d) {
  switch ($layer) {
    'Windows' { if (-not $d.Bit1) {'AUX bit is not set'} elseif ($d.Layers['Windows'].Val -eq 'NO') {'off in the driver (BasicFunc)'} else {'AUX bit is set'} }
    'PXE'     { if ($d.Bit1 -and $d.Bit0) {'AUX bit is set'} elseif ($d.Bit1) {'not tested with this value'} else {'AUX bit is not set'} }
    'Linux'   {
      if ($d.Layers.Contains('Linux') -and $d.Layers['Linux'].Val -eq 'YES') {
        switch ($d.Variant) { 'AD' {'recognised chip (RTL8153-AD)'} 'BND' {'recognised chip (RTL8153-BND)'} 'BD' {'recognised chip (RTL8153-BD)'} 'Lenovo' {'recognised Lenovo chip'} default {'recognised chip'} }
      } elseif ($d.Variant -eq 'AD') { '-AD chip, but bit 0 is not set' }
      else { 'chip variant not recognised' }
    }
  }
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
  if (-not $b.Enabled) {
    $b.BackColor = rgb 238 240 243; $b.ForeColor = rgb 160 164 170; $b.FlatAppearance.BorderColor = rgb 214 218 223; return
  }
  switch ($kind) {
    'primary' { $b.BackColor = $C_ACCENT; $b.ForeColor = $C_WHITE; $b.FlatAppearance.BorderColor = $C_ACCENT }
    'danger'  { $b.BackColor = $C_RED;    $b.ForeColor = $C_WHITE; $b.FlatAppearance.BorderColor = $C_RED }
    'link'    { $b.BackColor = $C_WHITE;  $b.ForeColor = $C_ACCENT; $b.FlatAppearance.BorderSize = 0; $b.FlatAppearance.MouseOverBackColor = $C_SOFT }
    default   { $b.BackColor = $C_WHITE;  $b.ForeColor = $C_ACCENT; $b.FlatAppearance.BorderColor = $C_ACCENT }
  }
}
function Set-Btn($b, $text, $kind, [bool]$enabled, [bool]$visible = $true) {
  $b.Text = $text; $b.Tag = $kind; $b.Visible = $visible; $b.Enabled = $enabled; Style-Btn $b $kind
}
function New-Box($parent, $x, $y, $w, $h, $bg, $border) {
  $p = New-Object Windows.Forms.Panel
  $p.Location = "$x,$y"; $p.Size = "$w,$h"; $p.BackColor = $bg; $p.Tag = $border
  $p.Add_Paint({ param($s,$e) if ($s.Tag) { $pen = New-Object Drawing.Pen($s.Tag, 1); $e.Graphics.DrawRectangle($pen, 0, 0, $s.Width-1, $s.Height-1); $pen.Dispose() } })
  $parent.Controls.Add($p); $p
}
function OwnerDraw-Combo($cb) {
  $cb.DrawMode = 'OwnerDrawFixed'; $cb.ItemHeight = 20
  $cb.Add_DrawItem({
    param($s,$e)
    if ($e.Index -lt 0) { return }
    $isEdit = ($e.State -band [Windows.Forms.DrawItemState]::ComboBoxEdit) -ne 0
    $sel = (-not $isEdit) -and (($e.State -band [Windows.Forms.DrawItemState]::Selected) -ne 0)
    $bg = if ($sel) { $C_ACCENT } else { $C_WHITE }; $fg = if ($sel) { $C_WHITE } else { $C_TEXT }
    $e.Graphics.FillRectangle((New-Object Drawing.SolidBrush $bg), $e.Bounds)
    [Windows.Forms.TextRenderer]::DrawText($e.Graphics, [string]$s.Items[$e.Index], $s.Font, $e.Bounds, $fg,
      ([Windows.Forms.TextFormatFlags]::Left -bor [Windows.Forms.TextFormatFlags]::VerticalCenter))
  })
}

# ---------- main window ----------
$form = New-Object Windows.Forms.Form
$form.Text = "RtlPassthru $Version"; $form.ClientSize = '760,606'; $form.StartPosition = 'CenterScreen'
$form.Font = F $FS_M; $form.BackColor = $C_WHITE; $form.FormBorderStyle = 'FixedSingle'; $form.MaximizeBox = $false

# window/taskbar icon: blue rounded badge with a white pass-through arrow (drawn, no .ico needed)
try {
  $ico = New-Object Drawing.Bitmap 64,64
  $ig = [Drawing.Graphics]::FromImage($ico); $ig.SmoothingMode = 'AntiAlias'; $ig.Clear([Drawing.Color]::Transparent)
  $ipath = New-Object Drawing.Drawing2D.GraphicsPath; $rd = 28
  $ipath.AddArc(2,2,$rd,$rd,180,90); $ipath.AddArc(62-$rd,2,$rd,$rd,270,90)
  $ipath.AddArc(62-$rd,62-$rd,$rd,$rd,0,90); $ipath.AddArc(2,62-$rd,$rd,$rd,90,90); $ipath.CloseFigure()
  $igrad = New-Object Drawing.Drawing2D.LinearGradientBrush (New-Object Drawing.Point 0,0), (New-Object Drawing.Point 0,64), $C_ACCENT, (rgb 29 78 216)
  $ig.FillPath($igrad, $ipath)
  $ipen = New-Object Drawing.Pen ([Drawing.Color]::White), 7; $ipen.StartCap = 'Round'; $ipen.EndCap = 'Round'
  $ig.DrawLine($ipen, 15,32, 38,32)
  $ig.FillPolygon([Drawing.Brushes]::White, @((New-Object Drawing.Point 36,19),(New-Object Drawing.Point 52,32),(New-Object Drawing.Point 36,45)))
  $form.Icon = [Drawing.Icon]::FromHandle($ico.GetHicon())
  $ipen.Dispose(); $igrad.Dispose(); $ipath.Dispose(); $ig.Dispose()
} catch { $null = $_ }   # cosmetic - never block startup

New-Lbl $form 'Realtek MAC Pass-Through' 22 12 600 38 (F $FS_XL $true) $C_TEXT | Out-Null
New-Lbl $form "Shows where a dock or dongle can take the laptop's MAC - and fixes it where it can." 24 52 700 22 (F $FS_M) $C_MUTED | Out-Null
New-Lbl $form 'Card' 24 88 44 28 (F $FS_M) $C_MUTED 'MiddleLeft' | Out-Null
$cmb = New-Object Windows.Forms.ComboBox
$cmb.Location = '70,88'; $cmb.Size = '540,28'; $cmb.DropDownStyle = 'DropDownList'; $cmb.FlatStyle = 'Standard'; $cmb.Font = F $FS_M
OwnerDraw-Combo $cmb; $form.Controls.Add($cmb)
$btnRescan = New-Btn $form 'Rescan' 620 86 116 32; Set-Btn $btnRescan 'Rescan' 'outline' $true

# three tiles
$script:tiles = [ordered]@{}
$tileNames = [ordered]@{ Windows='Windows'; PXE='Pre-boot / PXE'; Linux='Linux' }
$i = 0
foreach ($k in $tileNames.Keys) {
  $p = New-Box $form (20 + $i*244) 132 232 114 $C_SOFT $C_LINE
  $script:tiles[$k] = @{
    Box  = $p
    Name = (New-Lbl $p $tileNames[$k] 14 10 210 22 (F $FS_M $true) $C_TEXT)
    Big  = (New-Lbl $p '' 14 34 210 40 (F $FS_XL $true) $C_IDLE)
    Why  = (New-Lbl $p '' 14 80 210 22 (F $FS_M) $C_MUTED)
  }
  $i++
}

# the action card
$act = New-Box $form 20 262 720 222 $C_WHITE $C_LINE
$aTitle  = New-Lbl $act '' 16 14 680 28 (F $FS_L $true) $C_TEXT
$aBody   = New-Lbl $act '' 16 46 690 42 (F $FS_M) $C_TEXT
$aNote   = New-Lbl $act '' 16 90 690 22 (F $FS_M) $C_MUTED
$btnA1   = New-Btn $act 'Preview' 16 118 120 34
$btnA2   = New-Btn $act 'Write'   146 118 160 34
# "Enable pass-through" on an RTL8153-family card: what to burn - one record, or both in one burn
function New-Chk($text, $y) {
  $k = New-Object Windows.Forms.CheckBox; $k.Text = $text; $k.Location = New-Object Drawing.Point(326, $y)
  $k.Size = New-Object Drawing.Size(380, 22); $k.Font = F $FS_M; $k.ForeColor = $C_TEXT; $k.Visible = $false
  $act.Controls.Add($k); $k
}
$chkWin = New-Chk 'Windows + pre-boot    (0xCFDB = 0x03)' 112
$chkLin = New-Chk 'Linux    (the -AD chip-variant marker)' 134

# result banner: tinted background, coloured bar on the left, icon, bold headline + one detail line
$aRes = New-Object Windows.Forms.Panel; $aRes.Location = '16,162'; $aRes.Size = '688,48'; $aRes.Visible = $false; $aRes.Tag = $C_ACCENT
$aRes.Add_Paint({ param($s,$e) $br = New-Object Drawing.SolidBrush($s.Tag); $e.Graphics.FillRectangle($br, 0, 0, 4, $s.Height); $br.Dispose() })
$act.Controls.Add($aRes)
$aResIcon = New-Lbl $aRes '' 12 0 26 48 (F $FS_L $true) $C_ACCENT 'MiddleCenter'
$aResHead = New-Lbl $aRes '' 42 5 640 20 (F $FS_M $true) $C_TEXT
$aResText = New-Lbl $aRes '' 42 25 640 20 (F $FS_M) $C_MUTED

$lblStore = New-Lbl $form '' 24 494 712 20 (F $FS_S) $C_MUTED

$btnDetails = New-Btn $form 'Details' 16 520 110 32;  Set-Btn $btnDetails ('Details  ' + [char]0x25BE) 'link' $true
$btnSave    = New-Btn $form 'Save report' 132 520 120 32; Set-Btn $btnSave 'Save report' 'link' $true
$lblDll     = New-Lbl $form '' 300 526 340 20 (F $FS_S) $C_MUTED 'MiddleRight'
$btnLocate  = New-Btn $form 'Locate...' 646 520 100 32; Set-Btn $btnLocate 'Locate...' 'link' $true

# progress strip: same place as the result banner, shown while a tool talks to the card
$aProg = New-Object Windows.Forms.Panel; $aProg.Location = '16,162'; $aProg.Size = '688,48'; $aProg.Visible = $false; $aProg.BackColor = $C_SOFT
$act.Controls.Add($aProg)
$aProgText = New-Lbl $aProg '' 14 4 660 20 (F $FS_M $true) $C_TEXT
$aProgBar = New-Object Windows.Forms.ProgressBar; $aProgBar.Location = '14,28'; $aProgBar.Size = '660,10'
$aProgBar.Style = 'Marquee'; $aProgBar.MarqueeAnimationSpeed = 30; $aProg.Controls.Add($aProgBar)

function Show-Progress($step, [bool]$critical = $false) {
  $script:progStep = $step; $script:critical = $critical
  $aRes.Visible = $false; $aProgText.Text = $step; $aProg.Visible = $true; $aProg.BringToFront()
  [Windows.Forms.Application]::DoEvents()
}
function Hide-Progress { $script:progStep = $null; $script:critical = $false; $aProg.Visible = $false }

function Set-Result($kind, $head = '', $text = '') {
  Hide-Progress
  if (-not $kind) { $aRes.Visible = $false; return }
  $map = @{
    ok   = @($C_GREEN,  $C_GREENBG,     [char]0x2714)
    info = @($C_ACCENT, $C_INFOBG,      [char]0x2192)
    warn = @($C_AMBER,  $C_AMBERBG,     '!')
    err  = @($C_RED,    $C_REDBG,       [char]0x2716)
    hint = @($C_MUTED,  $C_SOFT,        'i')
  }
  $c = $map[$kind]
  $aRes.Tag = $c[0]; $aRes.BackColor = $c[1]; $aResIcon.ForeColor = $c[0]; $aResIcon.Text = [string]$c[2]
  $aResHead.Text = $head; $aResHead.ForeColor = $c[0]; $aResText.Text = $text; $aResText.ForeColor = $C_TEXT
  $aRes.Visible = $true; $aRes.Invalidate()
}

# Details: an inline panel under the buttons - the window grows to show it, nothing pops up over it
$BASE_H = 606
$detPanel = New-Object Windows.Forms.Panel; $detPanel.Location = '16,560'; $detPanel.Size = '728,320'; $detPanel.Visible = $false
$form.Controls.Add($detPanel)
$detTabs = New-Object Windows.Forms.TabControl; $detTabs.Dock = 'Fill'; $detTabs.Font = F $FS_M; $detPanel.Controls.Add($detTabs)
$detT1 = New-Object Windows.Forms.TabPage 'Markers & registers'; $detT2 = New-Object Windows.Forms.TabPage 'Settings dump'
$detTabs.TabPages.AddRange(@($detT1,$detT2))
$detRtb = New-Object Windows.Forms.RichTextBox; $detRtb.Dock = 'Fill'; $detRtb.ReadOnly = $true; $detRtb.BorderStyle = 'None'; $detRtb.BackColor = $C_WHITE
$detT1.Controls.Add($detRtb)
$detDump = New-Object Windows.Forms.TextBox; $detDump.Dock = 'Fill'; $detDump.Multiline = $true; $detDump.ScrollBars = 'Vertical'
$detDump.ReadOnly = $true; $detDump.Font = F $FS_M $false 'Consolas'; $detDump.BackColor = $C_WHITE; $detDump.BorderStyle = 'None'
$detT2.Controls.Add($detDump)
$script:detOpen = $false

$statusStrip = New-Object Windows.Forms.StatusStrip; $statusStrip.SizingGrip = $false; $statusStrip.BackColor = $C_SOFT; $statusStrip.Font = F $FS_S
$statusLbl = New-Object Windows.Forms.ToolStripStatusLabel; $statusLbl.Text = 'Ready.'
$statusStrip.Items.Add($statusLbl) | Out-Null; $form.Controls.Add($statusStrip)

function Set-Status($text, $color) { $statusLbl.Text = $text; $statusLbl.ForeColor = $(if ($color) { $color } else { $C_TEXT }); $statusStrip.Refresh() }

# ---------- the Realtek diag DLL: found automatically; Locate... points at a copy elsewhere ----------
$script:dllArg = 'auto'
function Sel-Dll { if ($script:dllArg -match '[\\:/]') { '"' + $script:dllArg + '"' } else { $script:dllArg } }
function Load-Dlls {
  $found = @()
  foreach ($line in ((Run-Py 'dll_list.py' '') -split "`r?`n")) {
    $p = $line -split "`t"
    if ($p.Count -ge 5 -and ($p[0] -eq 'new' -or $p[0] -eq 'old') -and $p[2] -eq 'ok') { $found += ,$p }
  }
  if ($found.Count) {
    $script:dllArg = 'auto'                                  # the tools pick the same one (newest command set first)
    $lblDll.Text = "Realtek DLL:  v$($found[0][3])"; $lblDll.ForeColor = $C_MUTED
  } else {
    $lblDll.Text = 'Realtek DLL not found - use Locate...'; $lblDll.ForeColor = $C_RED
  }
}
function Locate-Dll {
  $dlg = New-Object Windows.Forms.OpenFileDialog
  $dlg.Filter = 'RtlDirectDiagLib64.dll|RtlDirectDiagLib64.dll|DLL files (*.dll)|*.dll'
  $start = Join-Path $ROOT 'dll'; $dlg.InitialDirectory = if (Test-Path $start) { $start } else { $ROOT }
  if ($dlg.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return }
  $path = $dlg.FileName
  $p = (((Run-Py 'dll_list.py' "`"$path`"") -split "`r?`n")[0]) -split "`t"
  if ($p.Count -ge 5 -and ($p[0] -eq 'new' -or $p[0] -eq 'old') -and $p[2] -eq 'ok') {
    $script:dllArg = $path
    $lblDll.Text = "Realtek DLL:  v$($p[3])  (located)"; $lblDll.ForeColor = $C_MUTED
    if ($script:cards -and $cmb.SelectedIndex -ge 0) { Read-Card }
  } else {
    [Windows.Forms.MessageBox]::Show("That file is not a complete Realtek diag DLL.`n`n$path", 'Locate DLL', 'OK', 'Warning') | Out-Null
  }
}

# ---------- state rendering ----------
function Set-Tile($key, $state, $why) {
  $t = $script:tiles[$key]
  switch ($state) {
    'yes'  { $t.Box.BackColor = $C_GREENBG; $t.Box.Tag = $C_GREEN; $t.Big.ForeColor = $C_GREEN; $t.Big.Text = ([char]0x2714 + '  WORKS') }
    'no'   { $t.Box.BackColor = $C_REDBG;   $t.Box.Tag = $C_RED;   $t.Big.ForeColor = $C_RED;   $t.Big.Text = ([char]0x2716 + '  NO') }
    'unk'  { $t.Box.BackColor = $C_AMBERBG; $t.Box.Tag = $C_AMBER; $t.Big.ForeColor = $C_AMBER; $t.Big.Text = '?  UNKNOWN' }
    default { $t.Box.BackColor = $C_SOFT;   $t.Box.Tag = $C_LINE;  $t.Big.ForeColor = $C_IDLE;  $t.Big.Text = $state }
  }
  $t.Why.Text = $why; $t.Box.Invalidate()
}

function Show-Action($kind) {
  $script:action = $kind; $script:previewOk = $false; Set-Result ''
  $aTitle.ForeColor = $C_TEXT; $aNote.Text = ''; $aNote.ForeColor = $C_MUTED; $aBody.Text = ''
  $d = $script:rpt
  Set-Btn $btnA1 '1   Preview' 'outline' $false $false; Set-Btn $btnA2 '' 'primary' $false $false
  $script:syncing = $true; $chkWin.Visible = $false; $chkLin.Visible = $false; $script:syncing = $false
  switch ($kind) {
    'burn' {
      $all = $d.Variant -eq 'AD'
      $aTitle.Text = if ($all) { 'Enable pass-through  (Windows, pre-boot and Linux)' } else { 'Enable pass-through  (Windows and pre-boot)' }
      $aBody.Text = 'Burns the AUX bit into the chip''s efuse (writes 0x03).' +
                    $(if ($all) { ' On this -AD chip that switches on all three systems at once.' } else { ' Linux also needs a recognised chip variant, which this chip is not.' })
      $aNote.Text = ([char]0x26A0 + '  Permanent - efuse can be written once and never undone.'); $aNote.ForeColor = $C_RED
      Set-Btn $btnA1 '1   Preview' 'outline' $true; Set-Btn $btnA2 '2   Burn AUX bit' 'danger' $false
      Set-Result 'hint' 'Start with Preview' 'It checks the card and shows exactly what would be burned - nothing is written. Burn unlocks after it.'
    }
    'enable' {
      $nw = -not ($d.Bit1 -and $d.Bit0); $nl = [bool]$script:needLin      # 0xCFDB is only ever written whole, as 0x03
      $aTitle.Text = if ($nw -and $nl) { 'Enable pass-through' } elseif ($nl) { 'Enable Linux' } else { 'Enable pass-through  (Windows and pre-boot)' }
      $aBody.Text = if ($nw -and $nl) { 'Burns what you tick into the chip''s efuse. Both together: one burn, one re-plug.' }
                    elseif ($nl) { 'Burns the -AD chip-variant marker into the chip''s efuse, so the Linux r8152 driver accepts it. Windows and pre-boot are not affected.' }
                    elseif ($d.Variant -eq 'AD') { 'Burns both clone bits into the chip''s efuse (0xCFDB = 0x03). On this -AD chip that switches on Linux too.' }
                    else { 'Burns both clone bits into the chip''s efuse (0xCFDB = 0x03).' }
      $aNote.Text = ([char]0x26A0 + '  Permanent - efuse can be written once and never undone.'); $aNote.ForeColor = $C_RED
      $script:syncing = $true
      $script:offer = @($(if ($nw) { 'cfdb' }), $(if ($nl) { 'ad' })) | Where-Object { $_ }
      $both = $nw -and $nl                       # a checkbox only when there is something to choose
      $chkWin.Visible = $both; $chkWin.Checked = $true; $chkLin.Visible = $both; $chkLin.Checked = $true
      $script:syncing = $false
      Sync-Choice
    }
    'ok' {
      $aTitle.Text = 'Nothing to do'; $aTitle.ForeColor = $C_GREEN
      $aBody.Text = 'This card passes the laptop''s MAC through on Windows, pre-boot and Linux.'
    }
    'drvoff' {
      $aTitle.Text = 'Windows: switched off in the driver'
      $basic = $d.Profile -like 'BasicFunc*'
      if ($basic) {
        $aBody.Text = 'Its maker chose the BasicFunc driver profile (EnableCloneMAC = 0). Experimental: burn a new USB revision ' +
                      'to get the Mapt (pass-through) profile - or use Registry Fix, reversible.'
        $aNote.Text = ([char]0x26A0 + '  Permanent, not yet proven on hardware. Windows then sets the adapter up as a new device.'); $aNote.ForeColor = $C_RED
        $script:offer = @('rev')
        Set-Btn $btnA1 '1   Preview' 'outline' $true; Set-Btn $btnA2 '2   Burn new profile' 'danger' $false
        Set-Result 'hint' 'Start with Preview' 'It shows the new USB revision and where it goes - nothing is written. Burn unlocks after it.'
      } else {
        $aBody.Text = 'The card has the pass-through bits, but the driver setting EnableCloneMAC is 0 for this adapter. ' +
                      'Registry Fix (in the release) turns it back on - reversible, nothing burned.'
        $aNote.Text = 'Pre-boot and Linux do not use this switch.'
      }
    }
    'nolinux' {
      $aTitle.Text = 'Linux: not on this card'
      $aBody.Text = 'Linux only accepts recognised chip variants (-AD, -BND, -BD or Lenovo). This chip isn''t one, and this tool has no proven way to change that.'
      $aNote.Text = 'Windows and pre-boot work and are not affected.'
    }
    'error' {
      $aTitle.Text = 'Could not read this card'; $aTitle.ForeColor = $C_RED
      $aBody.Text = 'Run as administrator, check the card is plugged in, and that the Realtek DLL is found (Locate... below).'
    }
    'reading' { $aTitle.Text = 'Reading the card...'; $aTitle.ForeColor = $C_MUTED }
  }
}

function Selected-Records {
  # one option offered: that one; two: the ticked ones
  $o = @($script:offer)
  if ($o.Count -lt 2) { return $o }
  @($(if ($chkWin.Checked) { 'cfdb' }), $(if ($chkLin.Checked) { 'ad' })) | Where-Object { $_ }
}
function Burn-Label {
  $r = @(Selected-Records)
  if ($r -contains 'rev') { '2   Burn new profile' } elseif ($r.Count -eq 2) { '2   Burn both' } elseif ($r -contains 'ad') { '2   Burn -AD marker' } else { '2   Burn AUX bit' }
}
function Sync-Choice {
  # Linux needs 0xCFDB bit0 too: without it on the chip, the -AD marker only makes sense together with 0xCFDB = 0x03
  if ($script:syncing) { return }
  $script:syncing = $true
  try {
    $d = $script:rpt; $bit0 = $d -and $d.Bit0
    if ($chkLin.Visible) {
      $ok = $bit0 -or $chkWin.Checked
      $chkLin.Enabled = $ok; if (-not $ok) { $chkLin.Checked = $false }
    }
    $script:previewOk = $false
    $any = @(Selected-Records).Count -gt 0
    Set-Btn $btnA1 '1   Preview' 'outline' $any; Set-Btn $btnA2 (Burn-Label) 'danger' $false
    if (-not $any) { Set-Result 'hint' 'Tick what to switch on' 'Then Preview shows exactly what would be burned.' }
    elseif ($chkLin.Visible -and -not $chkLin.Enabled) { Set-Result 'hint' 'Start with Preview' 'Linux also needs 0xCFDB bit0, which this chip lacks - tick Windows + pre-boot to enable Linux too.' }
    else { Set-Result 'hint' 'Start with Preview' 'It checks the card and shows exactly what would be burned - nothing is written. Burn unlocks after it.' }
  } finally { $script:syncing = $false }
}

function Set-Busy([bool]$busy) {
  $script:busy = $busy                     # click handlers ignore presses while a tool is running
  foreach ($b in @($btnRescan,$btnDetails,$btnSave,$btnLocate)) { $b.Enabled = -not $busy; Style-Btn $b $b.Tag }
  $cmb.Enabled = -not $busy
  $form.Cursor = if ($busy) { 'WaitCursor' } else { 'Default' }
  [Windows.Forms.Application]::DoEvents()
}

function Refresh-List {
  $script:rpt = $null; $script:reading = $true
  $cmb.Items.Clear()
  foreach ($k in $script:tiles.Keys) { Set-Tile $k '' '' }
  Show-Action 'reading'; $aTitle.Text = 'Looking for cards...'; $lblStore.Text = ''
  Set-Status 'Scanning for Realtek USB cards...'; $form.Refresh()
  $script:cards = @(Get-Cards)
  foreach ($c in $script:cards) {
    [void]$cmb.Items.Add(("{0}  |  {1}  |  {2}" -f ($c.Desc -replace ' Family Controller',''), $c.Mac, (Chip-Name $c.Pid)))
  }
  $script:reading = $false
  if ($cmb.Items.Count) { $cmb.SelectedIndex = 0 }
  else {
    $aTitle.Text = 'No Realtek USB card found'; $aBody.Text = 'Plug in the dock or dongle, then press Rescan.'
    Set-Status 'No Realtek USB card found.' $C_AMBER
  }
}

function Read-Card {
  if ($script:reading -or $cmb.SelectedIndex -lt 0) { return }
  $c = $script:cards[$cmb.SelectedIndex]
  foreach ($k in $script:tiles.Keys) { Set-Tile $k '...' 'reading' }
  Show-Action 'reading'; $lblStore.Text = ''; Set-Status 'Reading the card...'
  Set-Busy $true
  try { $d = Parse-Diag (Run-Py 'diag.py' "`"$($c.Guid)`" --json --dll $(Sel-Dll)") } finally { Set-Busy $false }
  $d.Guid = $c.Guid; $d.Card = $c
  $script:rpt = $d
  if (-not $d.Ok) {
    foreach ($k in $script:tiles.Keys) { Set-Tile $k 'unk' 'could not read' }
    Show-Action 'error'; Set-Status 'Read failed - run as administrator and check the card.' $C_AMBER; return
  }
  foreach ($k in @('Windows','PXE','Linux')) {
    $v = if ($d.Layers.Contains($k)) { $d.Layers[$k].Val } else { '?' }
    Set-Tile $k $(switch ($v) { 'YES' {'yes'} 'NO' {'no'} default {'unk'} }) (Tile-Reason $k $d)
  }
  $fl = [regex]::Match($d.Storage, 'SPI flash \(([^)]+)\)')
  $pretty = if ($d.Storage -like 'efuse*') { 'efuse  -  one-time, permanent' + $(if ($fl.Success) { "      (the SPI flash, $($fl.Groups[1].Value), holds the driver install disk)" } else { '' }) }
            else { $d.Storage }
  $lblStore.Text = 'Settings stored in:  ' + $pretty
  $lin = $d.Layers.Contains('Linux') -and $d.Layers['Linux'].Val -eq 'YES'
  # RTL8153 family (efuse type 1 / V3): marker.py burns 0xCFDB = 0x03 and/or the -AD marker - the user picks.
  # RTL8156 family (dword): the proven efuse.py burn of 0xCFDB. A plain RTL8153 is what Linux lacks a marker on.
  $byteProto = $d.Proto -like 'type 1*' -or $d.Proto -like 'type 3*'
  $script:needLin = (-not $lin) -and ($d.Card.Pid -eq '8153') -and ($d.Variant -eq 'none') -and $byteProto
  $winOff = $d.Bit1 -and $d.Layers['Windows'].Val -eq 'NO'      # the AUX bit is there, the driver profile says no
  $kind = if ($byteProto -and ((-not $d.Bit1) -or $script:needLin)) { 'enable' } elseif (-not $d.Bit1) { 'burn' }
          elseif ($winOff) { 'drvoff' } elseif ($lin) { 'ok' } else { 'nolinux' }
  Show-Action $kind
  $msg = switch ($kind) {
    'burn'    { 'Pass-through is off - see the card below.' }
    'enable'  { if ($d.Bit1) { 'Windows and pre-boot: yes. Linux: no - it can be enabled below.' } else { 'Pass-through is off - see the card below.' } }
    'nolinux' { 'Windows and pre-boot: yes. Linux: not on this chip.' }
    'drvoff'  { 'Windows: switched off by the driver profile - see the card below.' }
    default   { 'Works on Windows, pre-boot and Linux.' }
  }
  Set-Status $msg $(if (-not $d.Bit1) { $C_RED } else { $C_TEXT })
  if ($script:detOpen) { Fill-Details }
}

# ---------- actions ----------
function Preview {
  $d = $script:rpt; if (-not $d) { return }
  Set-Busy $true
  Show-Progress 'Checking the efuse...'
  try {
    if ($script:action -eq 'burn') {
      $j = Get-Json (Run-Py 'efuse.py' "`"$($d.Guid)`" --plan --json --dll $(Sel-Dll)")
      $res = if ($j) { $j.result } else { '' }
      if ($res -eq 'unavailable') {
        Set-Result 'err' 'Can''t burn this chip  -  nothing written' 'Its efuse does not use the dword protocol of the RTL8156 family, the only one this tool writes.'
      } elseif ($res -eq 'ready') {
        $script:previewOk = $true
        Set-Result 'info' 'Ready to burn  -  nothing written yet' ("Record $($j.plan.record)  at efuse offset $(Hex $j.plan.at 2)   " + [char]0x00B7 + '   free slot, factory data untouched')
        Set-Btn $btnA2 '2   Burn AUX bit' 'danger' $true
      } elseif ($res -eq 'gap') {
        Set-Result 'err' 'Can''t burn  -  nothing written' 'The records on this card end mid-block; a record there would never load. Details shows the efuse.'
      } else {
        Set-Result 'err' 'Can''t burn  -  nothing written' 'No free efuse slot was found, or the read failed. Details shows the efuse.'
      }
    } elseif ($script:action -in 'enable','drvoff') {
      $sel = (@(Selected-Records) -join ',')
      $out = Run-Py 'marker.py' "`"$($d.Guid)`" --plan --records $sel --json --dll $(Sel-Dll)"
      $j = Get-Json $out
      $res = if ($j) { $j.plan.result } else { '' }; $why = if ($j) { $j.plan.reason } else { '' }
      $n = @($j.plan.records).Count; $rec = $j.plan.record; $at = Hex $j.plan.at 2; $proto = $j.plan.protocol; $proven = [bool]$j.plan.proven
      $dot = '   ' + [char]0x00B7 + '   '; $what = if ($n -gt 1) { "Records $rec" } else { "Record $rec" }
      if ($res -eq 'OK') {
        $script:previewOk = $true; $script:plan = $j.plan; $script:planSel = $sel
        if ($j.plan.experimental) {
          $rv = $j.plan.rev
          Set-Result 'warn' 'Ready to burn  -  experimental, nothing written yet' ("$what  at offset $at" + $dot + "USB revision $(Hex $rv.now 4) -> $(Hex $rv.new 4)" + $dot + 'not yet proven on hardware')
        } elseif ($proven) {
          Set-Result 'info' 'Ready to burn  -  nothing written yet' ("$what  at efuse offset $at" + $dot + 'blank space' + $dot + 'data first, header last')
        } else {
          Set-Result 'warn' 'Ready to burn  -  nothing written yet' ("$what  at offset $at" + $dot + "efuse $proto" + $dot + 'protocol not yet proven on hardware')
        }
        Set-Btn $btnA2 (Burn-Label) 'danger' $true
      } elseif ($res -eq 'NOT_NEEDED') {
        Set-Result 'warn' 'Already on the chip' ("Nothing to burn ($why). Press Rescan if the tiles have not caught up.")
      } else {
        Set-Result 'err' 'Can''t burn  -  nothing written' $(if ($why) { $why } else { Tool-Error $out })
      }
    }
  } finally { if ($aProg.Visible) { Hide-Progress }; Set-Busy $false }
}

function Burn-Card {
  $d = $script:rpt; if (-not $d -or -not $script:previewOk) { return }
  Set-Busy $true; Show-Progress 'Checking the efuse again...'
  try { $j = Get-Json (Run-Py 'efuse.py' "`"$($d.Guid)`" --plan --json --dll $(Sel-Dll)") } finally { Hide-Progress; Set-Busy $false }   # re-check right before burning
  $dwd = if ($j -and $j.plan) { [int64]$j.plan.dword } else { $null }; $rng = if ($j -and $j.plan) { Hex $j.plan.at 2 } else { '' }
  if (-not $j -or $j.result -ne 'ready' -or $null -eq $dwd) {
    Set-Result 'err' 'Not burned' 'The free slot could not be confirmed again. Run Preview.'
    Set-Btn $btnA2 '2   Burn AUX bit' 'danger' $false; return
  }
  $msg = "Burn the AUX bit into this card's efuse?`n`nCard : $($d.Card.Desc)`nMAC  : $($d.Card.Mac)`n`n" +
         "Adds the record 40 CF DB 03 at efuse offset $rng (free space; factory data is not touched).`n`n" +
         "This is PERMANENT - efuse can be written once and never undone.`nKeep the card plugged in until it finishes."
  if ([Windows.Forms.MessageBox]::Show($msg, 'Burn the AUX bit - permanent', 'YesNo', 'Warning', 'Button2') -ne 'Yes') { Set-Status 'Burn cancelled.'; return }
  Set-Busy $true; Set-Btn $btnA1 '1   Preview' 'outline' $false; Set-Btn $btnA2 '2   Burn AUX bit' 'danger' $false
  Set-Status 'Burning - do not unplug the card...' $C_RED
  Show-Progress 'Burning the AUX bit - do not unplug the card...' $true
  try { $j = Get-Json (Run-Py 'efuse.py' "`"$($d.Guid)`" --burn --json --dll $(Sel-Dll)") } finally { Hide-Progress; Set-Busy $false }
  $back = if ($j -and $null -ne $j.read_back) { Hex $j.read_back 8 } else { '' }
  if ($j -and $j.result -eq 'ok' -and [int64]$j.read_back -eq $dwd) {
    Set-Result 'ok' 'Burned and verified' 'Unplug and re-plug the card so it reloads its efuse, then press Rescan.'
    Set-Status 'Burn verified. Re-plug the card, then Rescan.' $C_GREEN
    [Windows.Forms.MessageBox]::Show("Burned and verified.`n`nUnplug and re-plug the card so it loads the new setting, then press Rescan.", 'Done', 'OK', 'Information') | Out-Null
  } else {
    Set-Result 'err' "The burn did not verify  (read back '$back')" 'The card is not harmed - writes only go to free space. Re-plug and try again.'
    Set-Btn $btnA1 '1   Preview' 'outline' $true; Set-Status 'Burn did not verify.' $C_RED
  }
}

function Burn-Marker {
  $d = $script:rpt; if (-not $d -or -not $script:previewOk) { return }
  $sel = $script:planSel; $lbl = Burn-Label
  $names = @{ cfdb = '0xCFDB = 0x03 (Windows and pre-boot)'; ad = 'USB_MISC_0 = 0x1000, the -AD marker (Linux)'
              rev = 'new USB revision: driver profile BasicFunc -> Mapt (EXPERIMENTAL; Windows sets the adapter up anew)' }
  $lines = (@($script:plan.records) | ForEach-Object { "  $($_.record)   at efuse offset $(Hex $_.at 2)   $($names[$_.name])" }) -join "`n"
  $msg = "Burn into this card's efuse?`n`nCard : $($d.Card.Desc)`nMAC  : $($d.Card.Mac)`n`n$lines`n`n" +
         "Blank space only. Per record the data bytes go first; the header that switches it on`n" +
         "is burned last, only if they all verified.`n`n" +
         "This is PERMANENT - efuse can be written once and never undone.`nKeep the card plugged in until it finishes."
  if ([Windows.Forms.MessageBox]::Show($msg, 'Burn - permanent', 'YesNo', 'Warning', 'Button2') -ne 'Yes') { Set-Status 'Burn cancelled.'; return }
  Set-Busy $true; Set-Btn $btnA1 '1   Preview' 'outline' $false; Set-Btn $btnA2 $lbl 'danger' $false
  $chkWin.Enabled = $false; $chkLin.Enabled = $false
  Set-Status 'Burning - do not unplug the card...' $C_RED
  Show-Progress 'Checking the efuse again...' $true                 # marker.py re-runs every check before it burns
  try { $out = Run-Py 'marker.py' "`"$($d.Guid)`" --burn --records $sel --json --dll $(Sel-Dll)" } finally { Hide-Progress; Set-Busy $false }
  $j = Get-Json $out
  $res = if ($j) { $j.burn.result } else { '' }; $why = if ($j) { $j.burn.reason } else { '' }
  if ($res -eq 'OK') {
    Set-Result 'ok' 'Burned and verified' 'Unplug and re-plug the card so it loads the new settings, then press Rescan - the tiles should turn green.'
    Set-Status 'Burn verified. Re-plug the card, then Rescan.' $C_GREEN
    [Windows.Forms.MessageBox]::Show("Burned and verified.`n`nUnplug and re-plug the card so it loads the new settings, then press Rescan.", 'Done', 'OK', 'Information') | Out-Null
  } elseif ($res -eq 'STOPPED') {
    Set-Result 'err' 'Burn stopped' $why
    Set-Btn $btnA1 '1   Preview' 'outline' $true; $chkWin.Enabled = $true; Sync-Choice; Set-Result 'err' 'Burn stopped' $why
    Set-Status 'Burn stopped - see the card.' $C_RED
  } else {
    $plan = if ($j) { $j.plan.reason } else { '' }; $err = Tool-Error $out
    Set-Result 'err' 'Not burned' $(if ($plan) { $plan } elseif ($err) { $err } else { 'The tool did not report a result. Details shows the efuse.' })
    Set-Btn $btnA1 '1   Preview' 'outline' $true; Set-Status 'Not burned.' $C_RED
  }
}

# ---------- details window ----------
function Add-Txt($rtb, $text, $color, [bool]$bold = $false, $size = $FS_M, [bool]$mono = $false) {
  $rtb.SelectionStart = $rtb.TextLength; $rtb.SelectionLength = 0; $rtb.SelectionColor = $color
  $rtb.SelectionFont = F $size $bold $(if ($mono) { 'Consolas' } else { 'Segoe UI' }); $rtb.AppendText($text)
}
function Fill-Details {
  $d = $script:rpt
  $rtb = $detRtb; $rtb.Clear(); $detDump.Text = ''
  if (-not $d -or -not $d.Ok) { $detDump.Text = '(read a card first)'; return }
  Add-Txt $rtb "DEVICE`r`n" $C_ACCENT $true $FS_L
  Add-Txt $rtb ("  {0}`r`n  Windows name : {1}`r`n  MAC address  : {2}`r`n  Chip         : {3}, rev {4}`r`n  Efuse        : {7} protocol`r`n  Settings in  : {5}`r`n  Diag DLL     : {6}`r`n`r`n" -f `
    $d.Card.Desc, $d.Card.Name, $d.Card.Mac, $(if ($d.Chip) { $d.Chip } else { Chip-Name $d.Card.Pid }), $d.Rev, $d.Storage, $d.Dll, $(if ($d.Proto) { $d.Proto } else { 'unknown' })) $C_TEXT $false $FS_M $true
  if ($d.Profile -or $d.InfSection) {
    $cl = if ($null -eq $d.Clone) { 'not set (on: the driver''s default)' } elseif ($d.Clone) { '1 (on)' } else { '0 (off)' }
    Add-Txt $rtb ("  Driver       : profile {0} (from the USB revision){1}`r`n  EnableCloneMAC = {2}`r`n`r`n" -f `
      $(if ($d.Profile) { $d.Profile } else { 'not in the table' }), $(if ($d.InfSection) { ", installed as $($d.InfSection)" } else { '' }), $cl) $C_TEXT $false $FS_M $true
  }
  Add-Txt $rtb "PASS-THROUGH BY SYSTEM  -  each one checks a different marker`r`n" $C_ACCENT $true $FS_L
  foreach ($k in @('Windows','PXE','Linux')) {
    if (-not $d.Layers.Contains($k)) { continue }
    $L = $d.Layers[$k]; $col = switch ($L.Val) { 'YES' {$C_GREEN} '?' {$C_AMBER} default {$C_RED} }
    Add-Txt $rtb ("  {0,-9}{1,-5}{2}`r`n" -f $k, $L.Val, $L.Why) $col $true $FS_M $true
  }
  Add-Txt $rtb "`r`nTHE MARKERS ON THIS CARD`r`n" $C_ACCENT $true $FS_L
  Add-Txt $rtb ("  0xCFDB = {0}   capability byte, loaded at every power-on`r`n" -f $d.CfdbHex) $C_TEXT $false $FS_M $true
  Add-Txt $rtb ("    bit1 AUX-clone = {0}   what Windows and pre-boot check`r`n" -f $d.Bit1) $(if ($d.Bit1) {$C_GREEN} else {$C_RED}) $true $FS_M $true
  Add-Txt $rtb ("    bit0 RT-clone  = {0}   Linux checks it too, on -AD chips only`r`n" -f $d.Bit0) $C_TEXT $false $FS_M $true
  Add-Txt $rtb ("  USB_MISC_0 = {0}   USB_MISC_1 = {1}   chip variant, what Linux checks first`r`n" -f $d.M0, $d.M1) $C_TEXT $false $FS_M $true
  $v = if ($d.Variant -and $d.Variant -ne 'none') { "RTL8153-$($d.Variant)" -replace 'RTL8153-Lenovo','Lenovo chip' } else { 'none - a plain chip' }
  Add-Txt $rtb ("    variant = {0}`r`n" -f $v) $(if ($d.Variant -and $d.Variant -ne 'none') {$C_GREEN} else {$C_TEXT}) $true $FS_M $true
  Add-Txt $rtb "`r`nHow these markers work: docs/how-mac-passthrough-works.md`r`n" $C_MUTED $false $FS_S
  $detDump.Text = 'reading the card''s settings (efuse, and the SPI flash if there is one)...'; [Windows.Forms.Application]::DoEvents()
  Set-Busy $true
  try { $out = Run-Py 'settings.py' "`"$($d.Guid)`" --dll $(Sel-Dll)" } finally { Set-Busy $false }
  $detDump.Text = if ($out) { $out -replace "`r?`n", "`r`n" } else { '(nothing read)' }
}

function Toggle-Details([bool]$open) {
  $script:detOpen = $open
  if ($open) {
    # grow the window downwards, but never past the bottom of the screen (laptops at 125-150% scaling)
    $wa = [Windows.Forms.Screen]::FromControl($form).WorkingArea
    $chrome = $form.Height - $form.ClientSize.Height
    $room = $wa.Bottom - $form.Top - $chrome - $BASE_H - 12
    $h = [Math]::Max(220, [Math]::Min(360, $room))
    $detPanel.Height = $h; $detPanel.Visible = $true
    $form.ClientSize = New-Object Drawing.Size(760, ($BASE_H + $h + 12))
    if ($form.Bottom -gt $wa.Bottom) { $form.Top = [Math]::Max($wa.Top, $wa.Bottom - $form.Height) }
    Set-Btn $btnDetails ('Details  ' + [char]0x25B4) 'link' $true
    Fill-Details
  } else {
    $detPanel.Visible = $false; $form.ClientSize = New-Object Drawing.Size(760, $BASE_H)
    Set-Btn $btnDetails ('Details  ' + [char]0x25BE) 'link' $true
  }
}

function Save-Report {
  $d = $script:rpt; if (-not $d -or -not $d.Ok) { Set-Status 'Nothing to save - read a card first.' $C_AMBER; return }
  Set-Status 'Building the report (reading the card''s settings)...'
  $st = Run-Py 'settings.py' "`"$($d.Guid)`" --dll $(Sel-Dll)"
  $lay = ($d.Layers.Keys | ForEach-Object { '{0} = {1}  ({2})' -f $_, $d.Layers[$_].Val, $d.Layers[$_].Why }) -join "`r`n  "
  $txt = @"
RtlPassthru $Version - report
Generated : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

DEVICE     : $($d.Card.Desc)
Windows    : $($d.Card.Name)
MAC        : $($d.Card.Mac)
Chip       : $(if ($d.Chip) { $d.Chip } else { Chip-Name $d.Card.Pid }), rev $($d.Rev), efuse protocol $($d.Proto)
Settings in: $($d.Storage)

PASS-THROUGH BY SYSTEM
  $lay

MARKERS
  0xCFDB     = $($d.CfdbHex)   (bit1 AUX-clone = $($d.Bit1), bit0 RT-clone = $($d.Bit0))
  USB_MISC_0 = $($d.M0)    USB_MISC_1 = $($d.M1)    chip variant = $($d.Variant)

--- settings: efuse raw + decoded (and the start of an SPI flash, if any) ---
$($st -replace "`r?`n", "`r`n")
"@
  $dlg = New-Object Windows.Forms.SaveFileDialog
  $dlg.Filter = 'Text file (*.txt)|*.txt'
  $dlg.FileName = ("card-report-{0}-{1}.txt" -f ($d.Card.Mac -replace '[:-]',''), (Get-Date -Format 'yyyyMMdd-HHmm'))
  if ($dlg.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
    [IO.File]::WriteAllText($dlg.FileName, $txt, (New-Object Text.UTF8Encoding($false)))
    Set-Status ("Report saved: {0}" -f $dlg.FileName) $C_GREEN
  } else { Set-Status 'Save cancelled.' }
}

# ---------- wiring ----------
$cmb.Add_SelectedIndexChanged({ try { Read-Card } catch { Set-Status "Read error: $($_.Exception.Message)" $C_RED } })
$btnRescan.Add_Click({ try { Refresh-List } catch { Set-Status "Scan error: $($_.Exception.Message)" $C_RED } })
$form.Add_FormClosing({
  if ($script:critical) { $_.Cancel = $true; Set-Status 'Writing to the card - wait until it finishes, do not close or unplug.' $C_RED }
})
$btnA1.Add_Click({ if ($script:busy) { return }; try { Preview } catch { Set-Busy $false; Set-Status "Preview error: $($_.Exception.Message)" $C_RED } })
$chkWin.Add_CheckedChanged({ Sync-Choice }); $chkLin.Add_CheckedChanged({ Sync-Choice })
$btnA2.Add_Click({ if ($script:busy) { return }; try { if ($script:action -in 'enable','drvoff') { Burn-Marker } else { Burn-Card } } catch { Set-Busy $false; Set-Status "Error: $($_.Exception.Message)" $C_RED } })
$btnDetails.Add_Click({ try { Toggle-Details (-not $script:detOpen) } catch { Set-Busy $false; Set-Status "Details error: $($_.Exception.Message)" $C_RED } })
$btnSave.Add_Click({ try { Save-Report } catch { Set-Status "Save error: $($_.Exception.Message)" $C_RED } })
$btnLocate.Add_Click({ try { Locate-Dll } catch { Set-Status "Locate error: $($_.Exception.Message)" $C_RED } })

function Save-Png($f, $path) {
  $f.ActiveControl = $null; $f.Refresh(); [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 120; [Windows.Forms.Application]::DoEvents()
  $bmp = New-Object Drawing.Bitmap $f.Width, $f.Height
  $f.DrawToBitmap($bmp, (New-Object Drawing.Rectangle 0,0,$f.Width,$f.Height))   # off-screen, never the desktop
  $bmp.Save($path, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
}

if ($Screenshot) {
  $cmb.DrawMode = 'Normal'
  $form.StartPosition = 'Manual'; $form.Location = New-Object Drawing.Point -3200,-3200; $form.ShowInTaskbar = $false
  $form.Show(); [Windows.Forms.Application]::DoEvents()
  Load-Dlls; Refresh-List
  switch ($State) {
    'green' { $cmb.SelectedIndex = 1 }
    'plain' { $cmb.SelectedIndex = 2 }
    'adpreview' { $cmb.SelectedIndex = 2; Preview }
    'adburning' {
      $cmb.SelectedIndex = 2; Preview; Set-Btn $btnA1 '1   Preview' 'outline' $false; Set-Btn $btnA2 '2   Burn -AD marker' 'danger' $false
      Show-Progress 'Burning byte 3 of 5...' $true; $aProgText.Text = 'Burning byte 3 of 5...   1 s'; Set-Status 'Burning - do not unplug the card...' $C_RED
    }
    'addone' { $script:demoAD = $true; $cmb.SelectedIndex = 2 }
    'bothpreview' { $script:demoBare = $true; $cmb.SelectedIndex = 2; Preview }
    'basicfunc' { $script:demoBasic = $true; $cmb.SelectedIndex = 1; Preview }
    'dry'   { $cmb.SelectedIndex = 0; Preview }
    { $_ -in 'efuse','details' } {
      $cmb.SelectedIndex = 1
      $script:detOpen = $true; $detPanel.Height = 320; $detPanel.Visible = $true
      $form.ClientSize = New-Object Drawing.Size(760, ($BASE_H + 332))
      Set-Btn $btnDetails ('Details  ' + [char]0x25B4) 'link' $true
      Fill-Details
      $detTabs.SelectedIndex = $(if ($State -eq 'efuse') { 1 } else { 0 })
    }
  }
  Save-Png $form $Screenshot; $form.Close(); return
}

try {
  Load-Dlls
  $form.Add_Shown({ try { Refresh-List } catch { Set-Status "Scan error: $($_.Exception.Message)" $C_RED } })
  [void]$form.ShowDialog()
} catch {
  [Windows.Forms.MessageBox]::Show(($_.Exception.Message + "`n`n" + $_.ScriptStackTrace), 'RtlPassthru - startup error') | Out-Null
}
