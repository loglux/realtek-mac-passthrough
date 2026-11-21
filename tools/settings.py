"""Show where a Realtek USB card keeps its settings, and what is stored there. Read-only.

Usage:  python -I settings.py {InterfaceGUID} [--dll new|old|auto]

A card can keep its settings in efuse (one-time programmable), in an external SPI flash (rewritable),
or both - efuse is applied first, then the flash on top. This tool works out which stores the card has
and dumps each one with its decoded autoload records, so the same button works on any card:
  - efuse:     probed by reading it; a chip without a usable efuse never answers (reported, not hung on)
  - SPI flash: found by its JEDEC ID; only the settings area (first 256 bytes) is read - it is bit-banged
The output format is stable - the GUI shows it as is.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # so sibling modules import under `python -I`

from efuse_core import parse_autoload_records, parse_flash_records
from rtldiag import EfuseUnavailable, RtlDiag
from storage import describe as describe_storage, has_flash

NAMES = {0xC000: "MAC address", 0xCFDB: "SW_FEATURE - MAC clone / pass-through bits",
         0xD81A: "USB_MISC_0 - chip variant (AD marker)", 0xD81F: "USB_MISC_1 - chip variant (BD/BND)"}
EFUSE_BYTES = 256   # the whole efuse: a burned record sits past 0x80 (e.g. 0x080 on a burned RTL8156)
FLASH_BYTES = 256


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
            print(f"  0x{r['at']:03X}: write [{dhex}] -> reg 0x{r['reg']:04X}" + (f"  ({nm})" if nm else ""))
        elif r["kind"] == "raw":
            print(f"  0x{r['at']:03X}: other command [{dhex}]  (fixed-size, not decoded)")
        else:
            print(f"  0x{r['at']:03X}: unknown record type 0x{r['data'][0]:02X} - stopped reading here")
    regs = {r["reg"]: r["data"] for r in recs if r["kind"] == "reg"}
    if 0xCFDB in regs:   # several records may write it - the chip applies them in order, the last one wins
        print(f"  => 0xCFDB ends up as 0x{regs[0xCFDB][-1]:02X} (the last record wins)")


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print("usage: settings.py {InterfaceGUID} [--dll new|old|auto]")
        return 2
    guid = argv[0]
    dll = argv[argv.index("--dll") + 1] if "--dll" in argv else "auto"
    c = RtlDiag(guid, dll).open()
    try:
        print(f"GUID {guid}  (DLL: {c.family} v{c.version}, {c.exports} procedures)")

        efuse = None
        c.pg_enter()
        c.efuse_enable()
        try:
            efuse = c.efuse_dump(EFUSE_BYTES)
        except EfuseUnavailable:
            efuse = None
        finally:
            c.efuse_disable()
            c.pg_leave()

        dc00, jedec = c.flash_id()
        flash = c.flash_read(0, FLASH_BYTES) if has_flash(jedec) else None

        print(f"STORAGE efuse = {'responding' if efuse is not None else 'not responding (not used on this chip)'}")
        print(f"STORAGE flash = {describe_storage(jedec, dc00) if flash is not None else 'none'}")

        if efuse is not None:
            print(f"\n=== EFUSE (first {EFUSE_BYTES} bytes, one-time programmable) ===")
            _hex(efuse)
            print("records:")
            _records(parse_autoload_records(efuse))
        if flash is not None:
            print(f"\n=== SPI FLASH (first {FLASH_BYTES} bytes, rewritable) ===")
            _hex(flash)
            print(f"header 0x000-0x007: {flash[:8].hex(' ')}  (left as is; records start at 0x008)")
            print("records:")
            _records(parse_flash_records(flash))
        if efuse is None and flash is None:
            print("\nNo readable settings store found - the chip runs on its factory defaults.")
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
