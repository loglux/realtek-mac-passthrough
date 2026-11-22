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


def test_chip_identification_real_cards():
    # UGREEN: 0xE612 = 0x6310, 0xCD14 = 0x12, USB_MISC_0 = 0, 0xD81E = 0x4000 -> type 0x3106, variant 0x220
    # = "RTL8153UG" in Realtek's tool 2.0.30 (2.0.19 did not know 0x4000 and called it a new chip)
    assert ec.chip_type(0x6310, cd14=0x12) == (0x3106, False)
    assert ec.chip_variant(0x3106, 0x0000, 0x4000) == (0x220, False)
    assert ec.chip_name(0x3106, 0x220) == "RTL8153UG (type 0x3106)"
    assert ec.efuse_protocol(0x3106) == (ec.EFUSE_V3, 0xD0)
    # WAVLINK: 0xE612 = 0x7410, USB_MISC_0 = 0x1000 -> type 0x4102, variant 0x502 = "RTL8156BG" (both tools agree)
    assert ec.chip_type(0x7410) == (0x4102, False)
    assert ec.chip_variant(0x4102, 0x1000, 0x0000) == (0x502, False)
    assert ec.variant_name(0x502) == "RTL8156BG"
    assert ec.efuse_protocol(0x4102) == (ec.EFUSE_DWORD, 0x510)


def test_chip_type_revisions():
    t = lambda e612, cd14=0, **kw: ec.chip_type(e612, cd14=cd14, **kw)[0]   # noqa: E731
    assert t(0x6000) == 0x3101
    assert [t(0x6010, x) for x in (0x00, 0x01, 0x11, 0x02, 0x12)] == [0x3102, 0x3103, 0x3104, 0x3105, 0x3106]
    assert ec.chip_type(0x6010, cd14=0x03) == (0x3106, True)          # outside the table: flagged, like Realtek
    assert ec.chip_type(0x6020)[1] is True
    assert [t(0x6400, x) for x in (0x00, 0x01, 0x11, 0x02, 0x12)] == [0x3201, 0x3202, 0x3203, 0x3204, 0x3205]
    assert [t(0x5C00), t(0x5C10), t(0x5C20), t(0x5C30), t(0x5C30, 1)] == [0x3001, 0x3002, 0x3003, 0x3004, 0x3005]
    assert [t(0x7020), t(0x7030), t(0x7030, dc48=6)] == [0x4001, 0x4002, 0x4003]
    assert [t(0x7400), t(0x7410), t(0x7420)] == [0x4101, 0x4102, 0x4103]
    assert [t(0x1020), t(0x1030), t(0x2010), t(0x2020)] == [0x5001, 0x5002, 0x6001, 0x6002]   # RTL8157 / RTL8159
    assert [t(0x4800), t(0x4C00), t(0x4C10)] == [0x1001, 0x2001, 0x2002]
    assert ec.chip_type(0x0800) == (0, True)
    assert ec.efuse_protocol(0x3102)[0] == ec.EFUSE_OLD and ec.efuse_protocol(0x3104)[0] == ec.EFUSE_DWORD
    assert ec.efuse_protocol(0x5001)[0] == ec.EFUSE_DWORD and ec.efuse_protocol(0) == (None, 0)


def test_chip_variants():
    assert ec.chip_variant(0x3102, 0x1000, 0) == (0x207, False) and ec.variant_name(0x207) == "RTL8158vA"
    assert ec.chip_variant(0x3102, 0, 0x0400) == (0x206, False) and ec.variant_name(0x206) == "RTL8153BND"
    assert ec.chip_variant(0x3004, 0x1000, 0) == (0x10A, False) and ec.variant_name(0x10A) == "RTL8153ADvB"
    assert ec.chip_variant(0x3106, 0, 0) == (0x216, False) and ec.variant_name(0x216) == "RTL8153E"
    assert ec.chip_variant(0x3106, 0, 0x2000) == (0x216, True)            # unknown USB_MISC_1 -> new chip
    assert ec.chip_variant(0x4102, 0x1000, 0x0200) == (0x508, False) and ec.variant_name(0x508) == "RTL8156BGH"
    assert ec.chip_variant(0x5001, 0, 0) == (0xA01, False) and ec.variant_name(0xA01) == "RTL8157"
    assert ec.chip_name(0x3106, 0x216, True) == "RTL8153E (type 0x3106, a revision not in Realtek's tables)"

def test_record_dword_writes():
    rec = bytes.fromhex("41d81a0010")
    # aligned start: two dwords, the header dword last
    area = b"\xff" * 16
    w = ec.record_dword_writes(area, 4, rec)
    assert [(d, f"{o:08X}", f"{n:08X}") for d, o, n in w] == [(2, "FFFFFFFF", "FFFFFF10"), (1, "FFFFFFFF", "001AD841")]
    # records end mid-dword at 0x06: bytes 4..5 (AA BB) are kept, the record starts at 6 with no FF gap
    #   dword 1 (bytes 4..7) = AA BB 41 D8 -> 0xD841BBAA (header, last); dword 2 (bytes 8..11) = 1A 00 10 FF
    area = bytes.fromhex("40cfdb03aabb") + b"\xff" * 10
    w = ec.record_dword_writes(area, 6, rec)
    assert w == [(2, 0xFFFFFFFF, 0xFF10001A), (1, 0xFFFFBBAA, 0xD841BBAA)]


def test_v3_write_command():
    # the AD marker 41 D8 1A 00 10 at 0x18 on a blank V3 area: byte 0x19 = D8 -> odd -> D8 << 8 | 0xFF
    assert ec.efuse_v3_write_command(0x19, ec.efuse8153_write_word(0x19, 0xFF, 0xD8)) == 0x400CD8FF
    assert ec.efuse_v3_write_command(0x18, ec.efuse8153_write_word(0x18, 0xFF, 0x41)) == 0x400CFF41
    # the read command for the same byte differs only in the top bits (bit31 = read, bit30 = write)
    assert ec.efuse_v3_write_command(0x18, 0) & 0x00FF0000 == (0x80000000 | (0x18 << 15)) & 0x00FF0000


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
