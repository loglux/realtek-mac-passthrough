"""Regression tests for the pure efuse logic (tools/efuse_core.py). No card / DLL needed.

Run:  python -m pytest -q
"""
import efuse_core as ec


def test_byte_enable():
    assert ec.byte_enable(0xCFDB, 1) == 0x08    # byte 3 of the aligned dword
    assert ec.byte_enable(0xDD00, 4) == 0x0F    # full dword (efuse data read)
    assert ec.byte_enable(0xDD04, 2) == 0x03    # bytes 0-1 (efuse command)
    assert ec.byte_enable(0xE85B, 1) == 0x08    # byte 3
    assert ec.byte_enable(0xC000, 6) == 0x3F    # spans past the dword boundary


def test_build_record_and_dword():
    assert ec.build_record(0xCFDB, 0x03) == bytes([0x40, 0xCF, 0xDB, 0x03])
    assert ec.build_record(0xCFDB, 0x02) == bytes([0x40, 0xCF, 0xDB, 0x02])  # aux-only
    assert ec.record_dword(0xCFDB, 0x03) == 0x03DBCF40   # the burn read-back must match this


def test_find_append_point_free():
    data = bytes([0x40, 0xCF, 0xDB, 0x03]) + b"\xff" * 12
    r = ec.find_append_point(data)
    assert r["append"] == 4 and r["dwaddr"] == 1 and r["free"] and r["cur"] == 0xFFFFFFFF


def test_find_append_point_alignment():
    data = bytes([0x40, 0xCF, 0xDB]) + b"\xff" * 5   # last significant byte at 2 -> align up to 4
    r = ec.find_append_point(data)
    assert r["append"] == 4 and r["free"]


def test_find_append_point_two_records():
    data = bytes([0x40, 0xCF, 0xDB, 0x03, 0x40, 0xCF, 0xDB, 0x03]) + b"\xff" * 8
    r = ec.find_append_point(data)
    assert r["append"] == 8 and r["dwaddr"] == 2 and r["free"]


def test_parse_records_synthetic():
    data = bytes([0x42, 0xCF, 0xDC, 0x20, 0x00, 0x64, 0x40, 0xCF, 0xDB, 0x01, 0xFF, 0x00])
    recs = ec.parse_autoload_records(data)
    assert len(recs) == 2
    assert recs[0]["reg"] == 0xCFDC and recs[0]["data"] == bytes([0x20, 0x00, 0x64])
    assert recs[1]["reg"] == 0xCFDB and recs[1]["data"] == bytes([0x01])


ETH6_EFUSE = bytes.fromhex(   # real efuse of a burned RTL8156 dongle (rev 0x3104), first 0x80 bytes
    "42 cf dc 20 00 64 41 d8 22 98 b3 40 d8 23 a3 40"
    "d8 23 b3 a0 1b 80 bd 40 82 80 80 bd 38 50 78 80"
    "bd 38 40 78 60 24 45 70 60 26 86 0a 40 b4 81 13"
    "60 20 70 7a 60 21 80 46 60 2f 85 08 40 d4 ee 00"
    "25 c0 00 1c bf ce fb e8 00 27 dd 8a 00 00 00 00"
    "0b 02 20 02 40 c0 12 86 4c c9 c0 ff 16 03 34 30"
    "31 33 30 30 30 30 30 31 41 c0 0c 04 31 23 d3 a0"
    "0f 02 01 04 40 cf db 03 ff ff ff ff ff ff ff ff")


def test_parse_records_real_full_dump():
    # Fixed-size commands (0xA0 / 0x80 / 0x60) used to throw the parser off and invent registers.
    recs = ec.parse_autoload_records(ETH6_EFUSE)
    regs = [(r["at"], r["reg"]) for r in recs if r["kind"] == "reg"]
    assert regs == [(0x00, 0xCFDC), (0x06, 0xD822), (0x0B, 0xD823), (0x0F, 0xD823), (0x2C, 0xB481),
                    (0x3C, 0xD4EE), (0x40, 0xC000), (0x49, 0xDD8A), (0x54, 0xC012), (0x58, 0xC9C0),
                    (0x68, 0xC00C), (0x6D, 0xD3A0), (0x74, 0xCFDB)]
    raw = [(r["at"], len(r["data"])) for r in recs if r["kind"] == "raw"]
    assert raw == [(0x13, 2), (0x15, 5), (0x1A, 5), (0x1F, 5), (0x24, 4), (0x28, 4),
                   (0x30, 4), (0x34, 4), (0x38, 4)]
    mac = next(r for r in recs if r["reg"] == 0xC000)
    assert mac["data"] == bytes.fromhex("1cbfcefbe800")
    assert recs[-1]["reg"] == 0xCFDB and recs[-1]["data"] == bytes([0x03])   # our burned record


def test_parse_flash_records():
    header = bytes.fromhex("0602000000080000")        # UGREEN PUYA flash header, left as is
    empty = ec.parse_flash_records(header + b"\xff" * 16)
    assert empty == []
    ad = ec.parse_flash_records(header + bytes.fromhex("41d81a0010") + b"\xff" * 8)
    assert len(ad) == 1 and ad[0]["at"] == 0x008 and ad[0]["reg"] == 0xD81A and ad[0]["data"] == b"\x00\x10"


def test_build_record_bytes_ad_marker():
    # USB_MISC_0 = 0x1000 (the RTL8153-AD marker), little-endian data -> the record planned for UGREEN
    assert ec.build_record_bytes(0xD81A, (0x1000).to_bytes(2, "little")) == bytes.fromhex("41d81a0010")
    assert ec.build_record_bytes(0xCFDB, b"\x03") == ec.build_record(0xCFDB, 0x03)


def test_flash_append_point():
    header = bytes.fromhex("0602000000080000")
    assert ec.flash_append_point(header + b"\xff" * 16) == 0x008
    assert ec.flash_append_point(header + bytes.fromhex("41d81a0010") + b"\xff" * 8) == 0x00D


def test_parse_records_unknown_type_stops():
    recs = ec.parse_autoload_records(bytes([0x40, 0xCF, 0xDB, 0x03, 0xC5, 0x11, 0x22, 0xFF]))
    assert recs[0]["reg"] == 0xCFDB and recs[-1]["kind"] == "unknown" and recs[-1]["at"] == 4


def test_parse_records_real_prefix():
    # First two autoload records from a real WAVLINK efuse dump (probe-out.txt).
    real = bytes([0x42, 0xCF, 0xDC, 0x20, 0x00, 0x64, 0x41, 0xD8, 0x22, 0x98, 0xB3])
    recs = ec.parse_autoload_records(real)
    assert recs[0]["reg"] == 0xCFDC and recs[0]["data"] == bytes([0x20, 0x00, 0x64])
    assert recs[1]["reg"] == 0xD822 and recs[1]["data"] == bytes([0x98, 0xB3])
