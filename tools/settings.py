"""Show where a Realtek USB card keeps its settings, and what is stored there. Read-only.

Usage:  python -I settings.py {InterfaceGUID} [--dll new|old|auto]

The chip applies its settings at power-on from its efuse (one-time programmable) or an external EEPROM
(RTL8153 datasheet 6.4). This tool dumps the efuse with its decoded autoload records - trying the RTL8156
protocol first, then the RTL8153 one - and shows the start of an SPI flash if the card has one; that
flash holds the driver install disk, not chip settings. A controller that does not answer is reported,
never hung on.
The output format is stable - the GUI shows it as is.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # so sibling modules import under `python -I`

from efuse_core import PG_STAMP_REG, describe_pg_stamp, parse_autoload_records
from rtldiag import EfuseUnavailable, RtlDiag
from storage import flash_name, has_flash

NAMES = {0xC000: "MAC address", 0xCFDB: "SW_FEATURE - MAC clone / pass-through bits",
         0xD81A: "USB_MISC_0 - chip variant (AD marker)", 0xD81F: "USB_MISC_1 - chip variant (BD/BND)"}
EFUSE_BYTES = 256   # the whole efuse: a burned record sits past 0x80 (e.g. 0x080 on a burned RTL8156)
EFUSE8153_BYTES = 192   # the user efuse RTUNicPG reads on an RTL8153B
FLASH_BYTES = 256       # only the start of the flash is shown (header of the driver install disk)


def _hex(data: bytes, base: int = 0):
    for i in range(0, len(data), 16):
        chunk = data[i:i + 16]
        hexs = " ".join(f"{b:02x}" for b in chunk)
        text = "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)
        print(f"0x{base + i:03X}: {hexs:<47}  |{text}|")


def _records(recs):
    if not recs:
        print("  (none - the area is empty)")
    for r in recs:
        dhex = " ".join(f"{b:02X}" for b in r["data"])
        if r["kind"] == "reg":
            nm = NAMES.get(r["reg"], "")
            if r["reg"] == PG_STAMP_REG and describe_pg_stamp(r["data"]):
                nm = "programmed with " + describe_pg_stamp(r["data"])
            print(f"  0x{r['at']:03X}: write [{dhex}] -> reg 0x{r['reg']:04X}" + (f"  ({nm})" if nm else ""))
        elif r["kind"] == "raw":
            print(f"  0x{r['at']:03X}: other command [{dhex}]  (fixed-size, not decoded)")
        else:
            print(f"  0x{r['at']:03X}: unknown record type 0x{r['data'][0]:02X} - stopped reading here")
    regs = {r["reg"]: r["data"] for r in recs if r["kind"] == "reg"}
    if 0xCFDB in regs:   # several records may write it - the chip applies them in order, the last one wins
        print(f"  => 0xCFDB ends up as 0x{regs[0xCFDB][-1]:02X} (the last record wins)")


def _summary(recs, data, start, store):
    """Plain-language reading of a dump: what is records, what is empty space."""
    end = recs[-1]["at"] + recs[-1]["size"] if recs else start
    print("in plain words:")
    if recs:
        print(f"  0x{start:03X}-0x{end - 1:03X}  {len(recs)} setting record(s), listed above; the chip applies them at power-on")
    else:
        print(f"  no setting records at all - the chip takes nothing from its {store} and runs on its factory defaults")
    if end < len(data) and all(b == 0xFF for b in data[end:]):
        print(f"  0x{end:03X}-0x{len(data) - 1:03X}  all FF = empty: erased / never written (FF is the blank state, not data)")
    regs = {r["reg"] for r in recs if r["kind"] == "reg"}
    if 0xCFDB not in regs:
        print("  no 0xCFDB record - the pass-through bits are the chip's own default")
    if 0xD81A not in regs and 0xD81F not in regs:
        print("  no chip-variant record (USB_MISC_0/1) - the variant is whatever the chip reports by itself")


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print("usage: settings.py {InterfaceGUID} [--dll new|old|auto]")
        return 2
    guid = argv[0]
    dll = argv[argv.index("--dll") + 1] if "--dll" in argv else "auto"
    c = RtlDiag(guid, dll).open()
    try:
        print(f"GUID {guid}  (DLL: {c.family} v{c.version}, {c.exports} procedures)")

        efuse, proto = None, ""
        c.pg_enter()
        c.efuse_enable()
        try:
            efuse, proto = c.efuse_dump(EFUSE_BYTES), "RTL8156 protocol"
        except EfuseUnavailable:
            pass
        finally:
            c.efuse_disable()
        if efuse is None:                       # older family (RTL8153): the other protocol, read only
            try:
                efuse, proto = c.efuse8153_dump(EFUSE8153_BYTES), "RTL8153 protocol"
            except EfuseUnavailable:
                pass
        c.pg_leave()

        _, jedec = c.flash_id()
        flash = c.flash_read(0, FLASH_BYTES) if has_flash(jedec) else None

        print("STORAGE efuse = " + (f"responding ({proto})" if efuse is not None else
              "could not be read - the efuse controller answered neither protocol this tool knows"))
        print("STORAGE flash = " + (f"{flash_name(jedec)} - holds the driver install disk, not chip settings"
                                    if flash is not None else "none"))

        if efuse is not None:
            print(f"\n=== EFUSE (first {len(efuse)} bytes, one-time programmable) ===")
            _hex(efuse)
            print("records:")
            recs = parse_autoload_records(efuse)
            _records(recs)
            _summary(recs, efuse, 0, "efuse")
        else:
            print("\nThe settings this chip applies at power-on live in its efuse, which could not be read here.")
        if flash is not None:
            print(f"\n=== SPI FLASH (first {FLASH_BYTES} bytes) - driver install disk, not chip settings ===")
            _hex(flash)
            print("in plain words:")
            print(f"  0x000-0x007  {flash[:8].hex(' ')}  header of the driver install disk")
            print("  0x008-...    FF = empty; the disk image itself starts at 0x1000 (not shown)")
            print("  the chip does not load settings from this flash (RTL8153 datasheet 6.4: efuse or EEPROM only)")
    finally:
        c.close()
    return 0


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass
    try:
        _rc = main(sys.argv[1:])
    except OSError as _e:
        print(f"ERROR: {_e}")
        _rc = 1
    raise SystemExit(_rc)
