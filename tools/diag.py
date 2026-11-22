"""Read a Realtek USB card's plain registers (USB-OCP) via the diag DLL. Read-only.

Usage:  python -I diag.py {InterfaceGUID} [--dll new|old|auto] [--vid 0BDA]
Prints bcdDevice(REV), USB_MISC_0/1 and 0xCFDB with its RT/AUX clone bits, then the chip variant and a
per-layer pass-through verdict (Windows / PXE / Linux, see passthru.py). Register reads use
USBDirectRead (reliable, no off-by-one). With --json the last line is JSON {...} - that is what the GUI reads.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # so sibling modules import under `python -I`

from rtldiag import RtlDiag
from passthru import format_lines, verdict
from storage import describe as describe_storage
from jsonout import emit, wanted


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print("usage: diag.py {InterfaceGUID} [--dll new|old|auto] [--json]")
        return 2
    guid = argv[0]
    dll = argv[argv.index("--dll") + 1] if "--dll" in argv else "auto"
    vid = int(argv[argv.index("--vid") + 1], 16) if "--vid" in argv else 0x0BDA
    c = RtlDiag(guid, dll).open()
    try:
        rev = c.read_bcd() or 0
        m0 = c.usb_read(0xD81A, 2)
        m1 = c.usb_read(0xD81F, 1)
        cfdb = c.usb_read(0xCFDB, 1)
        info = c.chip_info()
        print(f"GUID {guid}")
        print(f"DLL {c.family} v{c.version} ({c.exports} procedures)  {c.path}")
        print(f"bcdDevice(REV) = 0x{rev:04X}")
        print(f"CHIP = {info['name']}, efuse protocol = {info['protocol'] or 'unknown'}")
        print(f"  0xD81A USB_MISC_0 = 0x{m0:04X}")
        print(f"  0xD81F USB_MISC_1 = 0x{m1:02X}")
        print(f"  0xCFDB EFUSE(PASS_THRU) = 0x{cfdb:02X}   bit0(RT-clone)={cfdb & 1}  bit1(AUX-clone)={(cfdb >> 1) & 1}")
        v = verdict(m0, m1, cfdb, vid)
        for line in format_lines(v):
            print(line)
        storage = {"dc00": None, "jedec": None, "text": ""}
        try:
            dc00, jedec = c.flash_id()
            storage = {"dc00": dc00, "jedec": jedec.hex(" ").upper(), "text": describe_storage(jedec, dc00)}
            print(f"  storage DC00 = 0x{dc00:02X}   SPI flash ID = {storage['jedec']}")
            print(f"CONFIG STORAGE = {storage['text']}")
        except Exception as e:     # never let the storage probe break the register read
            storage["text"] = f"unknown (probe failed: {e})"
            print(f"CONFIG STORAGE = {storage['text']}")
        if wanted(argv):
            emit({"tool": "diag", "guid": guid,
                  "dll": {"family": c.family, "version": c.version, "exports": c.exports, "path": c.path},
                  "rev": rev, "chip": {k: info[k] for k in ("name", "type", "variant", "protocol", "new_chip")},
                  "usb_misc_0": m0, "usb_misc_1": m1, "cfdb": cfdb, "linux_variant": v["variant"],
                  "layers": {k: {"ok": v[k][0], "why": v[k][1]} for k in ("Windows", "PXE", "Linux")},
                  "storage": storage})
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
