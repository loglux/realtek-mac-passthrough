"""Burn the RTL8153-AD chip-variant marker into an RTL8153-family efuse, so Linux (r8152) accepts the chip
for MAC pass-through. PERMANENT (one-time programmable).

Usage:
  python -I marker.py {InterfaceGUID} --plan     read-only: every check, and the exact commands a burn would send
  python -I marker.py {InterfaceGUID} --burn     burn it (re-runs every check first)
  [--dll new|old|auto] on either

The marker is one autoload record, USB_MISC_0 (0xD81A) = 0x1000 -> 41 D8 1A 00 10, appended to the efuse
records. The chip applies it at power-on, so re-plug the card afterwards.
Safe order: the record's data bytes are burned first while its header byte is still 0xFF - to the chip a
0xFF header means "no more records", so they are invisible. Each byte is read back; only if all of them are
right is the header burned, last. A mismatch before that leaves the card behaving exactly as before.
The output format is stable - the GUI parses the 'PLAN / BURN ...' lines and shows 'STEP = ...' as progress.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # so sibling modules import under `python -I`

from efuse_core import (EFUSE_DWORD, EFUSE_OLD, EFUSE_V3, build_record_bytes,  # noqa: E402
                        efuse8153_encode_write, efuse8153_write_word, efuse_v3_write_command,
                        parse_autoload_records)
from passthru import AD_MASK, AD_VALUE  # noqa: E402
from rtldiag import EfuseUnavailable, RtlDiag  # noqa: E402

REG, VALUE = 0xD81A, 0x1000          # USB_MISC_0 = 0x1000: r8152 sees an RTL8153-AD


def step(text):
    print(f"STEP = {text}", flush=True)


def plan(c):
    """Every check. Returns (at, record, order) when a burn may go ahead, else None."""
    m0 = c.usb_read(REG, 2)
    cf = c.usb_read(0xCFDB, 1)
    print(f"USB_MISC_0 now = 0x{m0:04X}   0xCFDB now = 0x{cf:02X}")
    if (m0 & AD_MASK) == AD_VALUE:
        print("PLAN RESULT = NOT NEEDED (the chip already reports the -AD marker)")
        return None
    if not cf & 1:
        print("PLAN RESULT = REFUSED (0xCFDB bit0 is not set - on an -AD chip Linux needs it too, so the marker alone would not help)")
        return None
    info = c.chip_info()
    kind, size = info["protocol"], info["size"]
    print(f"CHIP {info['name']}, efuse protocol = {kind or 'unknown'}")
    if info["new_chip"]:
        print("PLAN RESULT = REFUSED (a chip revision outside Realtek's tables - its tool refuses it too)")
        return None
    if kind not in (EFUSE_OLD, EFUSE_V3):
        why = {None: "the chip type is not known to this tool",
               EFUSE_DWORD: "this chip's efuse uses the dword protocol (RTL8156 family) - the marker writer is for the RTL8153 family"}[kind]
        print(f"PLAN RESULT = REFUSED ({why})")
        return None
    try:
        area = c.efuse8153_dump(size) if kind == EFUSE_OLD else c.efuse_v3_dump(size)
    except EfuseUnavailable as e:
        print(f"PLAN RESULT = REFUSED (the efuse could not be read: {e})")
        return None
    recs = parse_autoload_records(area)
    at = recs[-1]["at"] + recs[-1]["size"] if recs else 0
    rec = build_record_bytes(REG, VALUE.to_bytes(2, "little"))
    print(f"EFUSE = {size} bytes ({kind} protocol), records = {len(recs)}, "
          f"non-FF bytes = {sum(b != 0xFF for b in area)}")
    if at == 0 and sum(b != 0xFF for b in area) == 0:
        print("PLAN NOTE = the efuse reads completely blank - check the settings dump against Realtek's own tool first")
    if any(r["kind"] == "reg" and r["reg"] == REG for r in recs):
        print("PLAN RESULT = BLOCKED (the efuse already holds a USB_MISC_0 record)")
        return None
    if at + len(rec) + 1 > size - 1 or any(b != 0xFF for b in area[at:at + len(rec) + 1]):
        print(f"PLAN RESULT = BLOCKED (no blank room at 0x{at:02X} for {len(rec)} bytes + end marker before the write counter)")
        return None
    print(f"PLAN record = {rec.hex(' ').upper()}  (USB_MISC_0 = 0x{VALUE:04X}, the -AD marker)")
    print(f"PLAN at = 0x{at:02X}")
    order = list(range(1, len(rec))) + [0]
    for i in order:
        a = at + i
        w = efuse8153_write_word(a, 0xFF, rec[i])
        cmd = efuse8153_encode_write(a >> 1, w) if kind == EFUSE_OLD else efuse_v3_write_command(a, w)
        print(f"PLAN byte 0x{a:02X} = 0x{rec[i]:02X}   0xDD00 <- 0x{cmd:08X}"
              + ("   (header, burned last - activates the record)" if i == 0 else ""))
    if kind == EFUSE_V3:
        print("PLAN V3 sequence per byte (Realtek's tool 2.0.30): 0xE85B |= 0x10 and USB 0xD380 |= 0x0C for the session; "
              "0xE85B |= 0xC4; 0xDD00 |= bit27, wait clear; 0xDD00 <- command above, wait bit30 clear; "
              "0xDD00 |= bit28, wait clear; 0xE85B &= 0x3B; read the byte back")
        print("PLAN RESULT = PLAN-ONLY (this chip uses the V3 protocol - the plan is shown, burning with it is not enabled yet)")
        return None
    print("PLAN RESULT = OK")
    return at, rec, order


def burn(c):
    p = plan(c)
    if p is None:
        return 1
    at, rec, order = p
    for n, i in enumerate(order, 1):
        a = at + i
        step(f"Burning byte {n} of {len(order)}" + (" - the header, last" if i == 0 else "") + "...")
        back = c.efuse8153_write_byte(a, rec[i])
        print(f"BURN byte 0x{a:02X} = 0x{rec[i]:02X}, read back 0x{back:02X}  {'OK' if back == rec[i] else 'MISMATCH'}")
        if back != rec[i]:
            if i:
                print("BURN RESULT = STOPPED (a data byte did not verify; the header is still FF, so the record is "
                      "not active and the card behaves as before)")
            else:
                print("BURN RESULT = STOPPED (the header byte did not verify - check the settings dump)")
            return 1
    print(f"BURN RESULT = OK (record burned and verified at 0x{at:02X}; unplug and re-plug the card to load it)")
    return 0


def main(argv):
    modes = [m for m in ("--plan", "--burn") if m in argv]
    if not argv or argv[0] in ("-h", "--help") or len(modes) != 1:
        print("usage: marker.py {GUID} --plan | --burn  [--dll new|old|auto]")
        return 2
    guid = argv[0]
    dll = argv[argv.index("--dll") + 1] if "--dll" in argv else "auto"
    c = RtlDiag(guid, dll).open()
    try:
        print(f"GUID {guid}  (DLL: {c.family} v{c.version}, {c.exports} procedures)")
        c.pg_enter()
        try:
            if modes[0] == "--plan":
                ok = plan(c) is not None
                print("(read-only - nothing was written)")
                return 0 if ok else 1
            print("=== BURN (permanent) ===")
            return burn(c)
        finally:
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
