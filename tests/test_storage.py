"""Config-storage decoding (tools/storage.py), checked against the two cards we read on real hardware."""
import storage


def test_ugreen_has_puya_flash():
    # UGREEN RTL8153: JEDEC ID 85 60 15 (also confirmed by Realtek's own PG tool) = PUYA P25Q16H, 2 MB.
    assert storage.has_flash(bytes([0x85, 0x60, 0x15]))
    assert storage.describe(bytes([0x85, 0x60, 0x15])) == "SPI flash, PUYA 2 MB (rewritable)"


def test_wavlink_has_no_flash():
    # WAVLINK RTL8156: ID 00 00 00 -> settings live in efuse only.
    assert not storage.has_flash(bytes([0x00, 0x00, 0x00]))
    assert storage.describe(bytes([0x00, 0x00, 0x00])).startswith("efuse only")
    assert not storage.has_flash(bytes([0xFF, 0xFF, 0xFF]))


def test_contradiction_is_reported_as_unknown():
    # Regression: without PG mode the flash does not answer (00 00 00) although 0xDC00 says it is there.
    # That must not be shown as "efuse only".
    s = storage.describe(bytes([0x00, 0x00, 0x00]), dc00=0x40)
    assert "unknown" in s and not s.startswith("efuse only")


def test_sizes_and_unknown_vendor():
    assert storage.describe(bytes([0xEF, 0x40, 0x13])) == "SPI flash, Winbond 512 KB (rewritable)"
    assert storage.describe(bytes([0x42, 0x40, 0x16])) == "SPI flash, vendor 0x42 4 MB (rewritable)"
