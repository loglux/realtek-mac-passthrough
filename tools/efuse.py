"""Read/dump efuse and burn the SW_FEATURE (0xCFDB) pass-through record. English output.

Usage:
  python -I efuse.py {GUID} [N] [--dll new|old|auto]           dump N bytes (default 128) + decoded records
  python -I efuse.py {GUID} --plan [--dll ...]    dry run: show where/what would be written
  python -I efuse.py {GUID} --burn [--dll ...]    OTP write 0xCFDB=0x03 (both clone bits), verify

Always 0x03, like a chip that ships enabled: Windows needs the AUX bit (bit1), Linux on -AD chips also
needs bit0, and pre-boot was verified with 0x03 only. (The old --aux-only / 0x02 option was removed.)

The burn appends a 4-byte record to the trailing 0xFF run (end of autoload); factory data is untouched.
Only ever writes into confirmed-free (0xFFFFFFFF) space. The output format is stable - the GUI parses it.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # so sibling modules import under `python -I`

from efuse_core import build_record, find_append_point, parse_autoload_records, record_dword
from rtldiag import EfuseUnavailable, RtlDiag

REG = 0xCFDB
NAMES = {0xC000: "IDR/MAC", 0xCFDB: "SW_FEATURE (MAC_CLONE/pass-through)", 0xD81A: "USB_MISC_0", 0xD81F: "USB_MISC_1"}


def _dump(c, nbytes):
    data = c.efuse_dump(max(nbytes, 128))
    shown = data[:nbytes]
    for i in range(0, len(shown), 16):
        chunk = shown[i:i + 16]
        hexs = " ".join(f"{b:02x}" for b in chunk)
        text = "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)
        print(f"0x{i:03X}: {hexs:<47}  |{text}|")
    print("records:")
    for r in parse_autoload_records(data):
        dhex = " ".join(f"{b:02X}" for b in r["data"])
        if r["kind"] != "reg":
            print(f"  0x{r['at']:02X}: other command [{dhex}]" if r["kind"] == "raw"
                  else f"  0x{r['at']:02X}: unknown record type - stopped")
            continue
        nm = NAMES.get(r["reg"], "")
        tag = f"  ({nm})" if nm else ""
        star = "   <<<" if r["reg"] == REG else ""
        print(f"  0x{r['at']:02X}: write [{dhex}] -> reg 0x{r['reg']:04X}{tag}{star}")


def _plan(c, value):
    data = c.efuse_dump(256)
    ap = find_append_point(data)
    append, dw = ap["append"], ap["dwaddr"]
    rec = build_record(REG, value)
    dwdata = record_dword(REG, value)
    print(f"append point (dword-aligned): 0x{append:X} (dwaddr 0x{dw:X})")
    print(f"current dword @0x{append:X} = 0x{ap['cur']:08X}")
    print(f"record to write: {' '.join(f'{b:02X}' for b in rec)}  (0x{REG:04X} = 0x{value:02X})")
    print(f"dword to write @0x{append:X}: 0x{dwdata:08X}")
    nxt = data[append + 4] if append + 4 < len(data) else 0xFF
    print(f"after burn 0x{append:X}..0x{append + 3:X} = {' '.join(f'{b:02X}' for b in rec)}, then 0x{append + 4:X}=0x{nxt:02X} (0xFF=EOL)")
    return ap, dw, dwdata


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print("usage: efuse.py {GUID} [N] [--plan|--burn] [--dll new|old|auto]")
        return 2
    if "--aux-only" in argv:
        print("ERROR: --aux-only was removed. 0x02 turns Linux pass-through off on -AD chips and was never "
              "tested at pre-boot; RtlPassthru always writes 0x03.")
        return 2
    guid = argv[0]
    dll = argv[argv.index("--dll") + 1] if "--dll" in argv else "auto"
    value = 0x03
    do_burn = "--burn" in argv
    do_plan = do_burn or "--plan" in argv
    nbytes = 128
    for a in argv[1:]:
        if a.isdigit():
            nbytes = int(a)
        elif a.lower().startswith("0x"):
            nbytes = int(a, 16)

    c = RtlDiag(guid, dll).open()
    try:
        print(f"GUID {guid}  (DLL: {c.family} v{c.version}, {c.exports} procedures)")
        c.pg_enter()
        c.efuse_enable()
        try:
            if not do_plan:
                _dump(c, nbytes)
                return 0
            ap, dw, dwdata = _plan(c, value)
            if not ap["free"]:
                print("!! append point is NOT free (not 0xFFFFFFFF) - BURN ABORTED for safety.")
                return 1
            if not do_burn:
                print("=== DRY RUN: nothing written. Add --burn to write. ===")
                return 0
            print("=== BURN (irreversible) ===")
            st = c.efuse_write_dword(dw, dwdata)
            print(f"burn cmd done, flag 0x4000 after poll: {st & 0x4000}")
            back = c.efuse_read_dword(dw)
            print(f"read-back @0x{ap['append']:X} = 0x{back:08X}")
            ok = back == dwdata
            print("RESULT: " + ("OK, matches" if ok else f"MISMATCH: 0x{back:08X} != 0x{dwdata:08X}"))
            return 0 if ok else 1
        except EfuseUnavailable as e:
            print(f"EFUSE UNAVAILABLE: {e}")
            return 3
        finally:
            c.efuse_disable()
            c.pg_leave()
    finally:
        c.close()


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
