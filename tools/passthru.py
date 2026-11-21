"""Per-layer MAC pass-through verdict from a Realtek USB NIC's registers. Pure logic - no card, no DLL.

Each layer checks a different marker on the card (see docs/how-mac-passthrough-works.md):

  Windows (Realtek driver) : 0xCFDB bit1 (AUX-clone). Chip variant is ignored.
  Pre-boot / PXE           : verified on a Dell with BIOS MAC Pass-Through: 0x03 works, 0x01 does not.
                             Those two cases cannot tell "bit1 alone" from "both bits", so a card with
                             the AUX bit but not bit0 (0x02) is reported as unknown (None / "?").
  Linux (r8152)            : the chip VARIANT first - mainline drivers/net/usb/r8152.c,
                             vendor_mac_passthru_addr_read():
                               Lenovo chip (USB VID 0x17EF)                 -> accepted
                               RTL8153-AD  (USB_MISC_0 & 0xFEE0 == 0x1000) -> needs 0xCFDB bit0 too
                               RTL8153-BND / -BD (USB_MISC_1 bit2 / bit0)  -> accepted, no efuse bit
                               anything else                                -> refused
"""

AD_MASK = 0xFEE0      # r8152: AD_MASK, compared against USB_MISC_0
AD_VALUE = 0x1000
BND_MASK = 0x04       # r8152: BND_MASK, in USB_MISC_1
BD_MASK = 0x01        # r8152: BD_MASK,  in USB_MISC_1
LENOVO_VID = 0x17EF

LAYERS = ("Windows", "PXE", "Linux")


def chip_variant(usb_misc_0: int, usb_misc_1: int, vid: int = 0x0BDA):
    """The r8152 variant the chip identifies as, or None for a plain chip. Same order as the driver."""
    if vid == LENOVO_VID:
        return "Lenovo"
    if (usb_misc_0 & AD_MASK) == AD_VALUE:
        return "AD"
    if usb_misc_1 & BND_MASK:
        return "BND"
    if usb_misc_1 & BD_MASK:
        return "BD"
    return None


def verdict(usb_misc_0: int, usb_misc_1: int, cfdb: int, vid: int = 0x0BDA) -> dict:
    """{'variant': str|None, 'Windows'|'PXE'|'Linux': (ok: bool|None, reason: str)}  - None = not known"""
    aux = (cfdb >> 1) & 1    # AUX-clone  - what the Windows driver reads
    bit0 = cfdb & 1          # RT-clone   - r8152 calls it PASS_THRU; the -AD branch needs it

    win = (True, "AUX-clone bit (0xCFDB bit1) is set") if aux else \
          (False, "AUX-clone bit (0xCFDB bit1) is not set")

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
        lin = (False, "not a chip variant r8152 recognises (no AD / BND / BD marker)")
    elif v == "AD":
        lin = (True, "RTL8153-AD variant, and 0xCFDB bit0 is set") if bit0 else \
              (False, "RTL8153-AD variant, but 0xCFDB bit0 is not set")
    elif v in ("BND", "BD"):
        lin = (True, f"RTL8153-{v} variant (the marker alone is enough)")
    else:
        lin = (True, "Lenovo chip (USB vendor 17EF)")

    return {"variant": v, "Windows": win, "PXE": pxe, "Linux": lin}


def format_lines(result: dict) -> list:
    """Stable text lines for diag.py; the GUI parses them by regex."""
    v = result["variant"] or "none"
    out = [f"  chip variant (r8152) = {v}"]
    for layer in LAYERS:
        ok, why = result[layer]
        word = "YES" if ok is True else ("NO " if ok is False else "?  ")
        out.append(f"PASSTHRU {layer:<7} = {word}  ({why})")
    return out
