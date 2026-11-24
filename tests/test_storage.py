"""Config-storage decoding (tools/storage.py), checked against the cards we read on real hardware."""
import storage


def test_ugreen_flash_is_the_driver_disk_not_settings():
    # UGREEN RTL8153: JEDEC ID 85 60 15 (also confirmed by Realtek's own PG tool) = PUYA P25Q16H, 2 MB.
    # Its flash holds the driver auto-install ISO; settings come from efuse (RTL8153 datasheet 6.4).
    assert storage.has_flash(bytes([0x85, 0x60, 0x15]))
    s = storage.describe(bytes([0x85, 0x60, 0x15]), (0xFFFF, 0xFFFF))
    assert s.startswith("efuse only") and "PUYA 2 MB" in s and "not settings" in s


def test_no_flash_no_eeprom_is_efuse_only():
    # WAVLINK RTL8156 / RTL8153E dongle: flash ID 00 00 00, no EEPROM content.
    assert not storage.has_flash(bytes([0x00, 0x00, 0x00]))
    assert not storage.has_flash(bytes([0xFF, 0xFF, 0xFF]))
    s = storage.describe(bytes([0x00, 0x00, 0x00]), (0xFFFF, 0xFFFF))
    assert s.startswith("efuse only") and "no SPI flash" in s and "unknown" not in s


def test_eeprom_rule_is_realteks():
    # CheckEepromType: word0 FFFF/0000/8129 or word 0x38 0000/FFFF = not recognised
    for w0, w38 in ((0xFFFF, 0x1234), (0x0000, 0x1234), (0x8129, 0x1234), (0x8153, 0x0000), (0x8153, 0xFFFF)):
        assert not storage.eeprom_has_content(w0, w38)
    assert storage.eeprom_has_content(0x8153, 0x0001)
    assert storage.describe(bytes(3), (0x8153, 0x0001)).startswith("efuse + external EEPROM")


def test_failed_probe_says_so():
    s = storage.describe(bytes(3), "EEPROM controller (0xDC80) stayed busy - timed out")
    assert "probe failed" in s and "efuse only" not in s
    assert "not probed" in storage.describe(bytes(3))


def test_sizes_and_unknown_vendor():
    assert storage.flash_name(bytes([0xEF, 0x40, 0x13])) == "Winbond 512 KB"
    assert storage.flash_name(bytes([0x42, 0x40, 0x16])) == "vendor 0x42 4 MB"


def test_write_test_wording():
    assert "no EEPROM fitted" in storage.describe(bytes(3), (0x0000, 0x0000, False))
    s = storage.describe(bytes(3), (0xFFFF, 0xFFFF, True))
    assert "fitted but blank" in s and s.startswith("efuse only")


class _FakeEeprom:
    """PLA 0xDC80 as the chip's EEPROM controller: bit31 = read, bit30 = write, low word = data."""

    def __init__(self, words=None):
        self.words, self.reg = words, 0          # words None = no chip: reads give 0000, writes vanish

    def dwrite(self, addr, size, data):
        if addr != 0xDC80:
            return
        v = int.from_bytes(data, "little")
        a = (v >> 16) & 0xFF
        if v & 0x40000000 and self.words is not None:
            self.words[a] = v & 0xFFFF
        self.reg = self.words.get(a, 0xFFFF) if self.words is not None else 0

    def dread(self, addr, size):
        return (self.reg if addr == 0xDC80 else 0).to_bytes(size, "little")


def _probe(fake, **kw):
    from rtldiag import RtlDiag
    c = object.__new__(RtlDiag)
    c.dread, c.dwrite = fake.dread, fake.dwrite
    c.pg_enter = c.pg_leave = lambda: -1
    return c.eeprom_probe(False, **kw)


def test_eeprom_write_test_on_simulated_boards():
    assert _probe(_FakeEeprom()) == (0, 0, None)                       # read only: no judgement
    assert _probe(_FakeEeprom(), write_test=True) == (0, 0, False)     # nothing fitted
    blank = _FakeEeprom({})
    assert _probe(blank, write_test=True) == (0xFFFF, 0xFFFF, True)    # blank chip found...
    assert blank.words[0] == 0xFFFF                                    # ...and word 0 put back
