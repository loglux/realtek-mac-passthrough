"""Burn the RTL8153-AD chip-variant marker into an RTL8153-family efuse, so Linux (r8152) accepts the chip
for MAC pass-through. PERMANENT (one-time programmable).

Usage:
  python -I marker.py {InterfaceGUID} --plan     read-only: every check, and the exact commands a burn would send
  python -I marker.py {InterfaceGUID} --burn     burn it (re-runs every check first)
  [--dll new|old|auto] on either

The marker is one autoload record, USB_MISC_0 (0xD81A) = 0x1000 -> 41 D8 1A 00 10, appended right after the
last record (no FF gap - FF ends the records). The chip applies it at power-on, so re-plug the card afterwards.
The chip type picks the efuse protocol, the way Realtek's own tool does:
  type 1          byte by byte, 0xDD00 with Realtek's bit rotation          - not yet proven on hardware
  type 2 (dword)  four bytes at a time through 0xDD04                       - proven (the 0xCFDB burn, RTL8156)
  type 3 (V3)     byte by byte, 0xDD00 with prepare / write / finish bits   - not yet proven on hardware
Safe order: everything after the header byte is burned first while the header is still 0xFF - to the chip a
0xFF header means "no more records", so it is invisible. Each write is read back; only if all are right is the
header burned, last. A mismatch before that leaves the card behaving exactly as before.
A chip revision outside Realtek's tables is refused, as Realtek's tool refuses it.
With --json the last line is JSON {...} (what the GUI reads); 'STEP = ...' lines drive its progress bar.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # so sibling modules import under `python -I`

from efuse_core import (EFUSE_DWORD, EFUSE_OLD, EFUSE_V3, build_record_bytes,  # noqa: E402
                        efuse8153_encode_write, efuse8153_write_word, efuse_v3_write_command,
                        parse_autoload_records, record_dword_writes)
from passthru import AD_MASK, AD_VALUE  # noqa: E402
from jsonout import emit, wanted  # noqa: E402
from rtldiag import EfuseUnavailable, RtlDiag  # noqa: E402

REG, VALUE = 0xD81A, 0x1000          # USB_MISC_0 = 0x1000: r8152 sees an RTL8153-AD
PROVEN = {EFUSE_DWORD: True, EFUSE_OLD: False, EFUSE_V3: False}   # burned and verified on a real card?


OUT: dict = {"tool": "marker", "plan": {}, "burn": {}}   # what --json emits at the end


def plan_result(code, reason=""):
    """Print the PLAN RESULT line and remember it for --json. code: OK / NOT_NEEDED / REFUSED / BLOCKED."""
    OUT["plan"].update(result=code, reason=reason)
    print(f"PLAN RESULT = {code.replace('_', ' ')}" + (f" ({reason})" if reason else ""))


def burn_result(code, reason=""):
    """Print the BURN RESULT line and remember it for --json. code: OK / STOPPED."""
    OUT["burn"].update(result=code, reason=reason)
    print(f"BURN RESULT = {code}" + (f" ({reason})" if reason else ""))


def step(text):
    print(f"STEP = {text}", flush=True)


def _read_area(c, kind, size):
    if kind == EFUSE_OLD:
        return c.efuse8153_dump(size)
    if kind == EFUSE_V3:
        return c.efuse_v3_dump(size)
    c.efuse_enable()
    try:
        return c.efuse_dump(size)
    finally:
        c.efuse_disable()


def plan(c):
    """Every check. Returns a plan dict when a burn may go ahead, else None."""
    m0 = c.usb_read(REG, 2)
    cf = c.usb_read(0xCFDB, 1)
    print(f"USB_MISC_0 now = 0x{m0:04X}   0xCFDB now = 0x{cf:02X}")
    if (m0 & AD_MASK) == AD_VALUE:
        plan_result("NOT_NEEDED", "the chip already reports the -AD marker")
        return None
    if not cf & 1:
        plan_result("REFUSED", "0xCFDB bit0 is not set - on an -AD chip Linux needs it too, so the marker alone would not help")
        return None
    info = c.chip_info()
    kind, size = info["protocol"], info["size"]
    print(f"CHIP {info['name']}, efuse protocol = {kind or 'unknown'}")
    OUT["chip"] = {k: info[k] for k in ("name", "type", "variant", "protocol", "new_chip")}
    if kind is None or info["new_chip"]:
        plan_result("REFUSED", "a chip revision outside Realtek's tables - its own tool refuses it too")
        return None
    try:
        area = _read_area(c, kind, size)
    except EfuseUnavailable as e:
        plan_result("REFUSED", f"the efuse could not be read: {e}")
        return None
    recs = parse_autoload_records(area)
    at = recs[-1]["at"] + recs[-1]["size"] if recs else 0
    rec = build_record_bytes(REG, VALUE.to_bytes(2, "little"))
    print(f"EFUSE = {size} bytes ({kind} protocol), records = {len(recs)}, non-FF bytes = {sum(b != 0xFF for b in area)}")
    if not recs:
        print("PLAN NOTE = no records at all - compare the settings dump with Realtek's own tool before burning")
    if any(r["kind"] == "reg" and r["reg"] == REG for r in recs):
        plan_result("BLOCKED", "the efuse already holds a USB_MISC_0 record")
        return None
    if recs and recs[-1]["kind"] == "unknown":
        plan_result("BLOCKED", "the records end in a type this tool cannot size - cannot tell where they stop")
        return None
    end = at + len(rec)                        # this byte must stay FF: it ends the records after ours
    if end >= size - 1 or any(b != 0xFF for b in area[at:end + 1]):
        plan_result("BLOCKED", f"no blank room at 0x{at:02X} for {len(rec)} bytes + end marker before the write counter")
        return None
    print(f"PLAN record = {rec.hex(' ').upper()}  (USB_MISC_0 = 0x{VALUE:04X}, the -AD marker)")
    print(f"PLAN at = 0x{at:02X}")
    OUT["plan"].update(record=rec.hex(" ").upper(), at=at, protocol=kind, proven=PROVEN[kind])
    p = {"kind": kind, "at": at, "rec": rec}
    if kind == EFUSE_DWORD:
        p["dwords"] = record_dword_writes(area, at, rec)
        for n, (dw, old, new) in enumerate(p["dwords"], 1):
            last = n == len(p["dwords"])
            print(f"PLAN dword 0x{dw * 4:03X} = 0x{new:08X} (now 0x{old:08X})   0xDD04 <- 0x{(dw & 0x1FF) | 0x4000:04X}"
                  + ("   (holds the header, burned last - activates the record)" if last else ""))
    else:
        p["order"] = list(range(1, len(rec))) + [0]
        for i in p["order"]:
            a = at + i
            w = efuse8153_write_word(a, 0xFF, rec[i])
            cmd = efuse8153_encode_write(a >> 1, w) if kind == EFUSE_OLD else efuse_v3_write_command(a, w)
            print(f"PLAN byte 0x{a:02X} = 0x{rec[i]:02X}   0xDD00 <- 0x{cmd:08X}"
                  + ("   (header, burned last - activates the record)" if i == 0 else ""))
        if kind == EFUSE_V3:
            print("PLAN V3 per byte (Realtek's tool 2.0.30): 0xE85B.0x10 and USB 0xD380 |= 0x0C for the session; "
                  "efuse on; 0xDD00 bit27, wait; command, wait bit30; bit28, wait; efuse off; read back")
    print(f"PLAN PROTOCOL = {kind} - " + ("proven on hardware" if PROVEN[kind] else
                                          "written from Realtek's tool, not yet proven on hardware"))
    plan_result("OK")
    return p


def _stop(header):
    if header:
        burn_result("STOPPED", "the header did not verify - check the settings dump")
    else:
        burn_result("STOPPED", "a data byte did not verify; the header is still FF, so the record is not "
                               "active and the card behaves as before")
    return 1


def burn(c):
    p = plan(c)
    if p is None:
        return 1
    kind, at, rec = p["kind"], p["at"], p["rec"]
    if kind == EFUSE_DWORD:
        c.efuse_enable()
        try:
            for n, (dw, old, new) in enumerate(p["dwords"], 1):
                last = n == len(p["dwords"])
                step(f"Burning dword {n} of {len(p['dwords'])}" + (" - with the header, last" if last else "") + "...")
                cur = c.efuse_read_dword(dw)
                if cur != old:
                    print(f"BURN dword 0x{dw * 4:03X} changed since the plan (0x{cur:08X} != 0x{old:08X}) - nothing written")
                    return _stop(last)
                c.efuse_write_dword(dw, new)
                back = c.efuse_read_dword(dw)
                print(f"BURN dword 0x{dw * 4:03X} = 0x{new:08X}, read back 0x{back:08X}  {'OK' if back == new else 'MISMATCH'}")
                if back != new:
                    return _stop(last)
        finally:
            c.efuse_disable()
    else:
        saved = c.v3_session_begin(for_write=True) if kind == EFUSE_V3 else None
        try:
            for n, i in enumerate(p["order"], 1):
                a = at + i
                step(f"Burning byte {n} of {len(p['order'])}" + (" - the header, last" if i == 0 else "") + "...")
                back = (c.efuse8153_write_byte(a, rec[i]) if kind == EFUSE_OLD else c.efuse_v3_write_byte(a, rec[i]))
                print(f"BURN byte 0x{a:02X} = 0x{rec[i]:02X}, read back 0x{back:02X}  {'OK' if back == rec[i] else 'MISMATCH'}")
                if back != rec[i]:
                    return _stop(i == 0)
        finally:
            if saved is not None:
                c.v3_session_end(saved)
    burn_result("OK", f"record burned and verified at 0x{at:02X}; unplug and re-plug the card to load it")
    return 0


def main(argv):
    modes = [m for m in ("--plan", "--burn") if m in argv]
    if not argv or argv[0] in ("-h", "--help") or len(modes) != 1:
        print("usage: marker.py {GUID} --plan | --burn  [--dll new|old|auto] [--json]")
        return 2
    guid = argv[0]
    dll = argv[argv.index("--dll") + 1] if "--dll" in argv else "auto"
    OUT["mode"] = modes[0].lstrip("-")
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
            if wanted(argv):
                emit(OUT)
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
