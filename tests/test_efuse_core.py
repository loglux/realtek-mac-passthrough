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


def test_pg_stamp():
    # WAVLINK RTL8156BG: Realtek's tool reported "Nic PG version = 2.19", "Nic CFG version = 1028" for 13 02 04 04.
    assert ec.describe_pg_stamp(bytes.fromhex("13020404")) == "PG tool 2.19, CFG 1028"
    # The burned RTL8156 dongle (ETH6_EFUSE above) carries 0F 02 01 04.
    stamp = next(r for r in ec.parse_autoload_records(ETH6_EFUSE) if r["reg"] in ec.PG_STAMP_REGS)
    assert ec.describe_pg_stamp(stamp["data"]) == "PG tool 2.15, CFG 1025"
    assert ec.describe_pg_stamp(b"\x01") == ""
def _cell_as_read(waddr, dword):
    """What a read of `waddr` returns after `dword` was programmed: the 17-bit cell + the address echo."""
    cell_lo, cell_b16 = dword & 0xFFFF, (dword >> 23) & 1
    return ((waddr & 0x7F) | (cell_b16 << 7)) << 16 | cell_lo


def test_efuse8153_encode_decode_round_trip():
    for waddr in range(0x80):
        for word in (0x0000, 0xFFFF, 0x1234, 0xA55A, 0x00FF, 0xFF00, 0x8001, 0xFF41, 0xD8FF, 0x00FF):
            assert ec.efuse8153_decode_read(_cell_as_read(waddr, ec.efuse8153_encode_write(waddr, word))) == word


def test_efuse8153_known_commands():
    # The exact 0xDD00 dwords the -AD marker burn sends (checked against the dry run on a real RTL8153).
    assert ec.efuse8153_encode_write(0x00, ec.efuse8153_write_word(0x01, 0xFF, 0xD8)) == 0x4080B1FF
    assert ec.efuse8153_encode_write(0x01, ec.efuse8153_write_word(0x02, 0xFF, 0x1A)) == 0x4081FE36
    assert ec.efuse8153_encode_write(0x01, ec.efuse8153_write_word(0x03, 0xFF, 0x00)) == 0x400101FF
    assert ec.efuse8153_encode_write(0x02, ec.efuse8153_write_word(0x04, 0xFF, 0x10)) == 0x4082FE24
    assert ec.efuse8153_encode_write(0x00, ec.efuse8153_write_word(0x00, 0xFF, 0x41)) == 0x4080FE83


def test_efuse8153_blank_reads_ff():
    # A blank cell reads back 0xFFFF on a real UGREEN (raw dword 0x00..FFFF, bit16 = 1 in hi bit 7).
    assert ec.efuse8153_decode_read(0x0080FFFF) == 0xFFFF
    assert ec.efuse8153_decode_read(0x00DFFFFF) == 0xFFFF


UGREEN_EFUSE = bytes.fromhex(   # real efuse of a plain RTL8153B (type 0x3106), read by Realtek's tool and by ours
    "40 cc 24 20 25 c0 00 ec 1a c3 12 34 ad 20 e8 22"
    "08 23 e8 18 18 02 05 04") + b"\xff" * (0xD0 - 0x19) + b"\xfe"


def test_chip_type_real_cards():
    # UGREEN: 0xE612 = 0x6310, 0xCD14 = 0x12 -> 0x3106 (Realtek's tool: "RTL8153BvC"), V3 protocol, 208 bytes
    assert ec.chip_type(0x6310, 0x12) == 0x3106
    assert ec.efuse_protocol(0x3106) == (ec.EFUSE_V3, 0xD0)
    # WAVLINK: 0xE612 & 0x7CF0 = 0x7410 -> RTL8156B family, dword protocol
    assert ec.efuse_protocol(ec.chip_type(0x7410, 0)) == (ec.EFUSE_DWORD, 0x510)


def test_chip_type_8153b_subrevisions():
    assert ec.chip_type(0x6000, 0) == 0x3101
    assert [ec.chip_type(0x6010, x) for x in (0x00, 0x01, 0x11, 0x02, 0x12)] == [0x3102, 0x3103, 0x3104, 0x3105, 0x3106]
    assert ec.chip_type(0x6010, 0x03) == 0 and ec.chip_type(0x6020, 0) == 0     # unknown -> 0 (refuse)
    assert [ec.chip_type(0x6400, x) for x in (0x00, 0x01, 0x11, 0x02, 0x12)] == [0x3201, 0x3202, 0x3203, 0x3204, 0x3205]
    assert ec.efuse_protocol(0x3102)[0] == ec.EFUSE_OLD and ec.efuse_protocol(0x3104)[0] == ec.EFUSE_DWORD
    assert ec.efuse_protocol(0) == (None, 0)


def test_ugreen_records_and_stamp():
    recs = ec.parse_autoload_records(UGREEN_EFUSE)
    assert [(r["at"], r["reg"]) for r in recs] == [(0x00, 0xCC24), (0x04, 0xC000), (0x0D, 0xE822), (0x11, 0xE818)]
    assert recs[1]["data"] == bytes.fromhex("ec1ac31234ad")
    assert ec.describe_pg_stamp(recs[3]["data"]) == "PG tool 2.24, CFG 1029"    # Realtek's tool: V2.24(1.029)
    assert ec.find_append_point(UGREEN_EFUSE[:-1])["append"] == 0x18            # a new record goes after these


def test_parse_records_unknown_type_stops():
    recs = ec.parse_autoload_records(bytes([0x40, 0xCF, 0xDB, 0x03, 0xC5, 0x11, 0x22, 0xFF]))
    assert recs[0]["reg"] == 0xCFDB and recs[-1]["kind"] == "unknown" and recs[-1]["at"] == 4


def test_parse_records_real_prefix():
    # First two autoload records from a real WAVLINK efuse dump (probe-out.txt).
    real = bytes([0x42, 0xCF, 0xDC, 0x20, 0x00, 0x64, 0x41, 0xD8, 0x22, 0x98, 0xB3])
    recs = ec.parse_autoload_records(real)
    assert recs[0]["reg"] == 0xCFDC and recs[0]["data"] == bytes([0x20, 0x00, 0x64])
    assert recs[1]["reg"] == 0xD822 and recs[1]["data"] == bytes([0x98, 0xB3])
