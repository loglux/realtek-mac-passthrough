"""Where a Realtek USB NIC keeps its configuration. Pure logic - decodes what diag.py reads.

At power-on the chip loads its settings from efuse (always present, one-time programmable) and then,
if the board has one, from an external memory - an SPI flash or a small EEPROM - which is rewritable.
An SPI flash answers the standard JEDEC ID command (0x9F); no answer (00 00 00 / FF FF FF) = no flash.
EEPROM detection is not implemented: no card with an EEPROM was available to verify it against.
"""

FLASH_VENDORS = {0x85: "PUYA", 0xEF: "Winbond", 0xC8: "GigaDevice", 0xC2: "Macronix", 0x1C: "EON",
                 0x0B: "XTX", 0x68: "BOYA", 0x9D: "ISSI", 0x20: "Micron", 0xA1: "Fudan", 0x01: "Spansion"}


def has_flash(jedec: bytes) -> bool:
    return not (jedec[0] in (0x00, 0xFF) and jedec[1] in (0x00, 0xFF))


def describe(jedec: bytes, dc00: int = 0) -> str:
    """One line for the GUI: which store holds the settings, and whether it can be rewritten.

    dc00 = the chip's storage-status byte (0xDC00): 0x40 was read on a card with an SPI flash, 0x00 on a
    card with none. If it reports external memory but the flash did not answer, say so - never claim
    "efuse only" on contradictory evidence.
    """
    if not has_flash(jedec):
        if dc00 & 0x40:
            return f"external memory reported (0xDC00=0x{dc00:02X}) but the SPI flash did not answer - unknown"
        return "efuse only (one-time) - no SPI flash found; EEPROM not probed"
    vendor = FLASH_VENDORS.get(jedec[0], f"vendor 0x{jedec[0]:02X}")
    cap = jedec[2]
    if 0x10 <= cap <= 0x20:
        n = 1 << cap
        size = f"{n // (1024 * 1024)} MB" if n >= 1024 * 1024 else f"{n // 1024} KB"
    else:
        size = "size unknown"
    return f"SPI flash, {vendor} {size} (rewritable)"
