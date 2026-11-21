"""Config-storage decoding (tools/storage.py), checked against the two cards we read on real hardware."""
import storage


def test_ugreen_flash_is_the_driver_disk_not_settings():
    # UGREEN RTL8153: JEDEC ID 85 60 15 (also confirmed by Realtek's own tooling) = PUYA P25Q16H, 2 MB.
    # Its flash holds the driver auto-install ISO; settings come from efuse (RTL8153 datasheet 6.4).
    assert storage.has_flash(bytes([0x85, 0x60, 0x15]))
    s = storage.describe(bytes([0x85, 0x60, 0x15]))
    assert s.startswith("efuse") and "PUYA 2 MB" in s and "not settings" in s
    assert "rewritable" not in s


def test_wavlink_has_no_flash():
    # WAVLINK RTL8156: ID 00 00 00 -> settings live in efuse only.
    assert not storage.has_flash(bytes([0x00, 0x00, 0x00]))
    assert storage.describe(bytes([0x00, 0x00, 0x00])).startswith("efuse (one-time) - no external memory")
    assert not storage.has_flash(bytes([0xFF, 0xFF, 0xFF]))


def test_contradiction_is_reported_as_unknown():
    # Regression: without PG mode the flash does not answer (00 00 00) although 0xDC00 says it is there.
    # That must not be shown as "no external memory".
    s = storage.describe(bytes([0x00, 0x00, 0x00]), dc00=0x40)
    assert "unknown" in s and "no external memory" not in s


def test_sizes_and_unknown_vendor():
    assert storage.flash_name(bytes([0xEF, 0x40, 0x13])) == "Winbond 512 KB"
    assert storage.flash_name(bytes([0x42, 0x40, 0x16])) == "vendor 0x42 4 MB"
