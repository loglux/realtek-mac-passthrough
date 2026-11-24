"""Where a Realtek USB NIC keeps its configuration. Pure logic - decodes what diag.py reads.

Per the RTL8153 / RTL8153B datasheets (section 6.4) the chip auto-loads its settings at power-on from
its efuse (on-chip, one-time programmable) and, if the board has one, from an external EEPROM
(93C46/56/66 or TWSI). An SPI flash is something else: on the cards we read it holds the
"driver auto-install" disk image (the card shows up as a CD with the driver on first plug-in) - the
chip does not load settings from it. Verified on a UGREEN RTL8153: a settings record written to its
flash was not applied after a power cycle, and the flash holds an ISO image from 0x1000.

Two probes (read-only unless asked for the EEPROM write test):
- SPI flash: the standard JEDEC ID command (0x9F); no answer (00 00 00 / FF FF FF) = no flash.
- EEPROM: words 0 and 0x38, judged by the rule of Realtek's own tool (CheckEepromType): content is
  recognised when word 0 is not FFFF / 0000 / 8129 and word 0x38 is not 0000 / FFFF. Otherwise there is
  no EEPROM content, so nothing loads from one. Whether such a board has a blank EEPROM or none at all
  is settled only by a write test, as Realtek's tool does it (diag.py --eeprom-test, rtldiag.eeprom_probe):
  a test word is written to word 0 and read back, then the original is put back. A blank EEPROM reads
  FFFF; reading alone cannot tell "none" from "blank", because with no chip the data line reads whatever
  its pull resistor gives.
Byte 0xDC00 is not a storage indicator: 0x40 reads on a card with a flash (UGREEN) and on one without
(RTL8153E dongle). The Windows driver reads it as the board's PCRID on RTL8153B.
"""

FLASH_VENDORS = {0x85: "PUYA", 0xEF: "Winbond", 0xC8: "GigaDevice", 0xC2: "Macronix", 0x1C: "EON",
                 0x0B: "XTX", 0x68: "BOYA", 0x9D: "ISSI", 0x20: "Micron", 0xA1: "Fudan", 0x01: "Spansion"}


def has_flash(jedec: bytes) -> bool:
    return not (jedec[0] in (0x00, 0xFF) and jedec[1] in (0x00, 0xFF))


def flash_name(jedec: bytes) -> str:
    """'PUYA 2 MB' - vendor and size from a JEDEC ID."""
    vendor = FLASH_VENDORS.get(jedec[0], f"vendor 0x{jedec[0]:02X}")
    cap = jedec[2]
    if 0x10 <= cap <= 0x20:
        n = 1 << cap
        size = f"{n // (1024 * 1024)} MB" if n >= 1024 * 1024 else f"{n // 1024} KB"
    else:
        size = "size unknown"
    return f"{vendor} {size}"


def eeprom_has_content(w0: int, w38: int) -> bool:
    """Realtek's tool rule (CheckEepromType)."""
    return w0 not in (0xFFFF, 0x0000, 0x8129) and w38 not in (0x0000, 0xFFFF)


def describe(jedec: bytes, eeprom=None) -> str:
    """One line for the GUI: where the settings live.

    eeprom = (word 0, word 0x38[, fitted]) from rtldiag.eeprom_probe - fitted True/False after the write
    test, None without it - or a string saying why the probe failed.
    """
    if isinstance(eeprom, tuple):
        w0, w38 = eeprom[:2]
        fitted = eeprom[2] if len(eeprom) > 2 else None
        if eeprom_has_content(w0, w38):
            where = f"efuse + external EEPROM (word0 0x{w0:04X})"
        elif fitted is True:
            where = f"efuse only (one-time) - an EEPROM is fitted but blank (write test; word0 0x{w0:04X})"
        elif fitted is False:
            where = "efuse only (one-time) - no EEPROM fitted (write test)"
        else:
            where = f"efuse only (one-time) - no EEPROM content (word0 0x{w0:04X})"
    else:
        where = "efuse (one-time); EEPROM " + (f"probe failed: {eeprom}" if eeprom else "not probed")
    if has_flash(jedec):
        return f"{where}; SPI flash {flash_name(jedec)} holds the driver install disk, not settings"
    return f"{where}; no SPI flash"
