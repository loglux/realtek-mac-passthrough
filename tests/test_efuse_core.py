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


def test_parse_records_real_prefix():
    # First two autoload records from a real WAVLINK efuse dump (probe-out.txt).
    real = bytes([0x42, 0xCF, 0xDC, 0x20, 0x00, 0x64, 0x41, 0xD8, 0x22, 0x98, 0xB3])
    recs = ec.parse_autoload_records(real)
    assert recs[0]["reg"] == 0xCFDC and recs[0]["data"] == bytes([0x20, 0x00, 0x64])
    assert recs[1]["reg"] == 0xD822 and recs[1]["data"] == bytes([0x98, 0xB3])
