"""marker.py end to end on a fake card: the plan and the burn, without hardware.

The fake card is an efuse that takes writes and gives them back, and registers built from what the chip would
load from it - so the order (header last), the addresses and the dwords a record shares with the one before
are checked byte for byte. Areas are our real cards' efuse (the RTL8153E dongle, a WAVLINK-shaped RTL8156B).

Run:  python -m pytest -q
"""
import efuse_core as ec
import marker
from test_efuse_core import DONGLE_EFUSE


class FakeCard:
    def __init__(self, area, kind, size, regs, cfdb, rev):
        self.area, self.kind, self.size = bytearray(area), kind, size
        self.regs, self.cfdb, self.rev = dict(regs), cfdb, rev
        self.log = []                         # (address, value) in write order

    # registers
    def usb_read(self, addr, n=2):
        return {0xD81A: self.regs.get("misc0", 0), 0xCFDB: self.cfdb}.get(addr, 0)

    def read_bcd(self):
        return self.rev

    def chip_info(self, recs=None):
        info = ec.identify(self.regs, recs)
        info["e612"] = self.regs["e612"]
        return info

    # efuse
    def efuse_area(self, kind, size):
        return bytes(self.area[:size])

    def v3_session_begin(self, for_write=False):
        return 0

    def v3_session_end(self, saved):
        pass

    def efuse_v3_write_byte(self, a, b):
        self.area[a] &= b                     # programming only clears bits
        self.log.append((a, b))
        return self.area[a]

    efuse8153_write_byte = efuse_v3_write_byte

    def efuse_enable(self):
        pass

    def efuse_disable(self):
        pass

    def efuse_read_dword(self, dw):
        return int.from_bytes(self.area[dw * 4:dw * 4 + 4], "little")

    def efuse_write_dword(self, dw, v):
        cur = self.efuse_read_dword(dw)
        self.area[dw * 4:dw * 4 + 4] = (cur & v).to_bytes(4, "little")
        self.log.append((dw * 4, v))


DONGLE_REGS = {"e612": 0x6310, "cd14": 0x12, "misc0": 0x0000, "d81e": 0x1000}


def dongle(cfdb=0x03, rev=0x310D):
    return FakeCard(DONGLE_EFUSE, ec.EFUSE_V3, 0xD0, DONGLE_REGS, cfdb, rev)


def tail_records(area, start):
    return [(r["at"], r["reg"], bytes(r["data"]).hex()) for r in ec.parse_autoload_records(bytes(area)) if r["at"] >= start]


def setup_function(_):
    marker.OUT.update(plan={}, burn={})


def test_ad_alone_as_burned_on_the_dongle():
    c = dongle()
    assert marker.burn(c, ["ad"]) == 0
    # the bytes and order the real burn used: data 0x1B..0x1E first, the header 0x1A last
    assert c.log == [(0x1B, 0xD8), (0x1C, 0x1A), (0x1D, 0x00), (0x1E, 0x10), (0x1A, 0x41)]
    assert tail_records(c.area, 0x1A) == [(0x1A, 0xD81A, "0010")]


def test_both_records_in_one_burn():
    c = dongle(cfdb=0x00)
    assert marker.burn(c, ["cfdb", "ad"]) == 0
    assert tail_records(c.area, 0x1A) == [(0x1A, 0xCFDB, "03"), (0x1E, 0xD81A, "0010")]
    # each record's header comes after its own data, and the cfdb record is complete before the ad one starts
    order = [a for a, _ in c.log]
    assert order.index(0x1A) == 3 and order[-1] == 0x1E and order.index(0x1A) < order.index(0x1F)


def test_skips_and_refusals():
    assert marker.plan(dongle(cfdb=0x03), ["cfdb"]) is None and marker.OUT["plan"]["result"] == "NOT_NEEDED"
    assert marker.plan(dongle(cfdb=0x02), ["ad"]) is None and marker.OUT["plan"]["result"] == "REFUSED"  # no bit0
    assert marker.plan(dongle(), ["rev"]) is None and marker.OUT["plan"]["result"] == "NOT_NEEDED"        # not BasicFunc


def test_rev_basicfunc_to_mapt_on_rtl8153():
    c = dongle(rev=0x310F)                                  # the same dongle, as if its maker had picked BasicFunc
    p = marker.plan(c, ["rev"])
    assert p and marker.OUT["plan"]["experimental"] and not marker.OUT["plan"]["proven"]
    assert marker.OUT["plan"]["rev"] == {"now": 0x310F, "new": 0x3102, "register": 0xC054}
    assert marker.burn(dongle(rev=0x310F), ["rev"]) == 0
    c = dongle(rev=0x310F)
    marker.burn(c, ["rev"])
    assert tail_records(c.area, 0x1A) == [(0x1A, 0xC054, "0231")]          # 41 C0 54 02 31


def test_rev_on_rtl8156_uses_dwords_and_keeps_the_shared_bytes():
    # WAVLINK-shaped RTL8156B: factory records end at 0x20 (dword-aligned), revision 0x31FF (BasicFunc, WU set)
    area = bytes.fromhex("25c000001122334466" "42d82298b3a3" "42cfdc200064" "40cfdb03" "23d3a013020404")
    area = area + b"\xff" * (0x50F - len(area)) + b"\xfe" + b"\xff" * (0x800 - 0x510)
    regs = {"e612": 0x7410, "misc0": 0x1000}
    c = FakeCard(area, ec.EFUSE_DWORD, 0x510, regs, 0x03, 0x31FF)
    assert marker.burn(c, ["rev"]) == 0
    assert marker.OUT["plan"]["rev"] == {"now": 0x31FF, "new": 0x31F2, "register": 0xC00C}
    assert tail_records(c.area, 0x20) == [(0x20, 0xC00C, "f231")]
    # two dwords, the one with the header last; the factory bytes before 0x20 untouched
    assert [a for a, _ in c.log] == [0x24, 0x20] and bytes(c.area[:0x20]) == area[:0x20]
    # cfdb / ad on an RTL8156 stay with efuse.py - refused here
    assert marker.plan(FakeCard(area, ec.EFUSE_DWORD, 0x510, regs, 0x01, 0x3104), ["cfdb"]) is None
    assert marker.OUT["plan"]["result"] == "REFUSED"


def test_mapt_revision_and_bcd_register():
    assert [ec.mapt_revision(r) for r in (0x300F, 0x310F, 0x31EF, 0x31FF)] == [0x3002, 0x3102, 0x31E2, 0x31F2]
    assert [ec.mapt_revision(r) for r in (0x310D, 0x3104, 0x3113, 0x3102)] == [None, None, None, None]
    assert [ec.bcd_register(t) for t in (0x3106, 0x3102, 0x1001, 0x3205, 0x4102, 0x4001, 0x5001, 0x6002, 0x7000)] == \
        [0xC054, 0xC054, 0xC054, 0xC054, 0xC00C, 0xC00C, 0xC018, 0xC018, None]


def test_rev_on_rtl8156_records_ending_mid_dword():
    # the factory records end at 0x1F: the rev record starts there and shares dword 0x1C with factory bytes
    area = bytes.fromhex("25c000001122334466" "41d82298b3" "42cfdc200064" "23d3a013020404" "40cfdb03")
    assert len(area) == 0x1F
    area = area + b"\xff" * (0x50F - len(area)) + b"\xfe" + b"\xff" * (0x800 - 0x510)
    c = FakeCard(area, ec.EFUSE_DWORD, 0x510, {"e612": 0x7410, "misc0": 0x1000}, 0x03, 0x310F)
    assert marker.burn(c, ["rev"]) == 0
    assert tail_records(c.area, 0x1F) == [(0x1F, 0xC00C, "0231")]
    # dword 0x1C keeps the factory bytes 0x1C-0x1E and takes our header at 0x1F - and it is written last
    assert [a for a, _ in c.log] == [0x20, 0x1C] and bytes(c.area[:0x1F]) == area[:0x1F]
