"""Per-layer MAC pass-through verdict from a Realtek USB NIC's registers. Pure logic - no card, no DLL.

Each layer checks a different marker on the card (see docs/how-mac-passthrough-works.md):

  Windows (Realtek driver) : 0xCFDB bit1 (AUX-clone). The Linux markers are ignored.
  Pre-boot / PXE           : verified on a Dell with BIOS MAC Pass-Through: 0x03 works, 0x01 does not.
                             Those two cases cannot tell "bit1 alone" from "both bits", so a card with
                             the AUX bit but not bit0 (0x02) is reported as unknown (None / "?").
  Linux (r8152)            : a MARKER register first - mainline drivers/net/usb/r8152.c,
                             vendor_mac_passthru_addr_read():
                               Lenovo chip (USB VID 0x17EF)                 -> accepted
                               AD marker   (USB_MISC_0 & 0xFEE0 == 0x1000) -> needs 0xCFDB bit0 too
                               BND / BD marker (USB_MISC_1 bit2 / bit0)     -> accepted, no efuse bit
                               anything else                                -> refused
                             r8152's comments name these after RTL8153 variants (-AD / -BND / -BD), but it
                             tests the registers on every chip it drives - an RTL8156 with the AD marker
                             passes (verified). So the reasons name the marker, never a chip.
"""

AD_MASK = 0xFEE0      # r8152: AD_MASK, compared against USB_MISC_0
AD_VALUE = 0x1000
BND_MASK = 0x04       # r8152: BND_MASK, in USB_MISC_1
BD_MASK = 0x01        # r8152: BD_MASK,  in USB_MISC_1
LENOVO_VID = 0x17EF

LAYERS = ("Windows", "PXE", "Linux")


def chip_variant(usb_misc_0: int, usb_misc_1: int, vid: int = 0x0BDA):
    """The r8152 marker the card carries ('AD' / 'BND' / 'BD' / 'Lenovo'), or None. Same order as the driver."""
    if vid == LENOVO_VID:
        return "Lenovo"
    if (usb_misc_0 & AD_MASK) == AD_VALUE:
        return "AD"
    if usb_misc_1 & BND_MASK:
        return "BND"
    if usb_misc_1 & BD_MASK:
        return "BD"
    return None


# The Windows driver profile. Realtek's INF (rtump64x64, 10.68) picks an install section per card from the low
# byte of its USB revision (bcdDevice) - a value the card maker burns into the efuse. Low nibble = the profile,
# for the low bytes 0x00-0x0F, 0xE0-0xEF ("Enterprise" name) and 0xF0-0xFF; other low bytes are one-off
# sections (e.g. RTL8156B 0x3110-0x3131) and not named here. Only BasicFunc touches pass-through: its
# DisableMACClone_Hide.reg writes EnableCloneMAC = 0 (and hides it from the adapter's Advanced tab).
PROFILES = {0x0: "standard", 0x1: "S5Wol", 0x2: "Mapt", 0x3: "S5Wol_Hide", 0x4: "Gaming", 0x5: "Gaming S5Wol",
            0x7: "S5Wol", 0x8: "RM10MbE", 0xD: "Sta", 0xE: "Dbg", 0xF: "BasicFunc"}


def driver_profile(rev: int):
    """The Windows driver profile a USB revision selects ('Sta', 'BasicFunc', ...), or None if not in the table."""
    low = rev & 0xFF
    if low >> 4 not in (0x0, 0xE, 0xF) or (low & 0xF) not in PROFILES:
        return None
    name = PROFILES[low & 0xF]
    if low >> 4 == 0xE:
        name = name.replace("Gaming", "standard") + " (Enterprise)"
    return name


def verdict(usb_misc_0: int, usb_misc_1: int, cfdb: int, vid: int = 0x0BDA, clone=None, profile=None) -> dict:
    """{'variant': str|None, 'Windows'|'PXE'|'Linux': (ok: bool|None, reason: str)}  - None = not known.

    clone = the adapter's EnableCloneMAC in the registry (True / False, None = not set: the driver's default,
    on); profile = driver_profile() of its USB revision. Both only matter to Windows."""
    aux = (cfdb >> 1) & 1    # AUX-clone  - what the Windows driver reads
    bit0 = cfdb & 1          # RT-clone   - r8152 calls it PASS_THRU; the -AD branch needs it

    basic = bool(profile) and profile.startswith("BasicFunc")
    if not aux:
        win = (False, "AUX-clone bit (0xCFDB bit1) is not set")
    elif clone is False:
        win = (False, "the Windows driver has MAC clone switched off (EnableCloneMAC = 0"
                      + (", driver profile BasicFunc" if basic else "") + ")")
    elif clone is None and basic:
        win = (False, "the driver profile BasicFunc switches MAC clone off (EnableCloneMAC = 0)")
    else:
        win = (True, "AUX-clone bit (0xCFDB bit1) is set")

    if aux and bit0:
        pxe = (True, "both clone bits set - 0x03 verified at pre-boot on a Dell")
    elif aux:
        pxe = (None, "AUX bit set, RT bit not - pre-boot was only verified with both bits (0x03)")
    elif bit0:
        pxe = (False, "AUX-clone bit not set - 0x01 verified to fail at pre-boot on a Dell")
    else:
        pxe = (False, "AUX-clone bit (0xCFDB bit1) is not set")

    v = chip_variant(usb_misc_0, usb_misc_1, vid)
    if v is None:
        lin = (False, "no marker r8152 accepts (AD / BND / BD)")
    elif v == "AD":
        lin = (True, "AD marker (USB_MISC_0 = 0x1000), and 0xCFDB bit0 is set") if bit0 else \
              (False, "AD marker (USB_MISC_0 = 0x1000), but 0xCFDB bit0 is not set")
    elif v in ("BND", "BD"):
        lin = (True, f"{v} marker (USB_MISC_1 bit{2 if v == 'BND' else 0}) - the marker alone is enough")
    else:
        lin = (True, "Lenovo chip (USB vendor 17EF)")

    return {"variant": v, "Windows": win, "PXE": pxe, "Linux": lin}


def format_lines(result: dict) -> list:
    """Text lines for diag.py (for people; the GUI reads the JSON line instead)."""
    v = result["variant"] or "none"
    out = [f"  r8152 marker = {v}"]
    for layer in LAYERS:
        ok, why = result[layer]
        word = "YES" if ok is True else ("NO " if ok is False else "?  ")
        out.append(f"PASSTHRU {layer:<7} = {word}  ({why})")
    return out
