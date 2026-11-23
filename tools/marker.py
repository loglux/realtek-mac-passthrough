"""Burn pass-through records into an RTL8153-family efuse - the one you pick, or both in one burn.
PERMANENT (one-time programmable).

Usage:
  python -I marker.py {InterfaceGUID} --plan [--records ad|cfdb|cfdb,ad]   read-only: every check, the exact commands
  python -I marker.py {InterfaceGUID} --burn [--records ...]               burn them (re-runs every check first)
  [--dll new|old|auto] on either; --records defaults to ad

The records:
  cfdb   40 CF DB 03      0xCFDB = 0x03, both clone bits: Windows and pre-boot (and Linux on -AD chips)
  ad     41 D8 1A 00 10   USB_MISC_0 = 0x1000, the -AD chip-variant marker: Linux (r8152) - it also needs
                          0xCFDB bit0, so it is refused alone on a chip without it (pick cfdb with it)
A record the chip does not need is skipped (0xCFDB already 0x03, the -AD marker already reported); only
0xCFDB as a whole byte is ever written - never single bits.

They go back to back right after the last record (no FF gap - FF ends the records), in the order cfdb, ad, and
the chip applies them at power-on, so re-plug the card afterwards. The chip type picks the efuse protocol, the way
Realtek's own tool does:
  type 1          byte by byte, 0xDD00 with Realtek's bit rotation          - not yet proven on hardware
  type 3 (V3)     byte by byte, 0xDD00 with prepare / write / finish bits   - proven (the -AD marker, RTL8153E)
The RTL8156 family (type 2, dword) is not written here: its 0xCFDB burn is efuse.py, proven on hardware.
Safe order, per record: everything after the header byte is burned first while the header is still 0xFF - to
the chip a 0xFF header means "no more records", so it is invisible. Each write is read back; only if all are
right is the header burned, last. If the second record stops, the first is complete and in effect.
Refused: a chip revision outside Realtek's tables (its efuse protocol is not known), an efuse record over a
register the type is read from, and a variant outside Realtek's tables that no efuse record explains. A
variant that is only unusual because an efuse record set it (e.g. this marker) is not refused: the type, and
with it the protocol, stays known.
With --json the last line is JSON {...} (what the GUI reads); 'STEP = ...' lines drive its progress bar.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # so sibling modules import under `python -I`

from efuse_core import (EFUSE_DWORD, EFUSE_OLD, EFUSE_V3, build_record_bytes,  # noqa: E402
                        efuse8153_encode_write, efuse8153_write_word, efuse_capacity, efuse_v3_write_command,
                        parse_autoload_records, place_records)
from passthru import AD_MASK, AD_VALUE  # noqa: E402
from jsonout import emit, wanted  # noqa: E402
from rtldiag import EfuseUnavailable, RtlDiag  # noqa: E402

REG, VALUE = 0xD81A, 0x1000          # USB_MISC_0 = 0x1000: r8152 sees an RTL8153-AD
RECORDS = {                          # name -> (record, what it is), burned in this order
    "cfdb": (build_record_bytes(0xCFDB, b"\x03"), "0xCFDB = 0x03, both clone bits: Windows and pre-boot"),
    "ad": (build_record_bytes(REG, VALUE.to_bytes(2, "little")), "USB_MISC_0 = 0x1000, the -AD marker: Linux"),
}
PROVEN = {EFUSE_DWORD: True, EFUSE_OLD: False, EFUSE_V3: True}    # burned and verified on a real card?


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


def plan(c, want):
    """Every check. Returns a plan dict when a burn may go ahead, else None."""
    m0 = c.usb_read(REG, 2)
    cf = c.usb_read(0xCFDB, 1)
    print(f"USB_MISC_0 now = 0x{m0:04X}   0xCFDB now = 0x{cf:02X}")
    todo = []
    if "cfdb" in want:
        if cf & 3 == 3:
            print("PLAN SKIP cfdb = 0xCFDB already has both clone bits")
        else:
            todo.append("cfdb")
    if "ad" in want:
        if (m0 & AD_MASK) == AD_VALUE:
            print("PLAN SKIP ad = the chip already reports the -AD marker")
        elif not cf & 1 and "cfdb" not in todo:
            plan_result("REFUSED", "0xCFDB bit0 is not set - on an -AD chip Linux needs it too, so the marker alone "
                                   "would not help (burn 0xCFDB = 0x03 with it)")
            return None
        else:
            todo.append("ad")
    if not todo:
        plan_result("NOT_NEEDED", "the chip already has " + " and ".join(
            {"cfdb": "both clone bits", "ad": "the -AD marker"}[w] for w in want))
        return None
    info = c.chip_info()
    kind, size = info["protocol"], info["size"]
    if kind is None or info["new_type"]:
        print(f"CHIP {info['name']}, efuse protocol = {kind or 'unknown'}")
        plan_result("REFUSED", "a chip revision outside Realtek's tables - its efuse protocol is not known")
        return None
    if kind == EFUSE_DWORD:
        print(f"CHIP {info['name']}, efuse protocol = {kind}")
        plan_result("REFUSED", "an RTL8156-family chip - its 0xCFDB burn is efuse.py; this tool writes the "
                               "RTL8153 family")
        return None
    try:
        area = c.efuse_area(kind, size)
    except EfuseUnavailable as e:
        plan_result("REFUSED", f"the efuse could not be read: {e}")
        return None
    recs = parse_autoload_records(area)
    info = c.chip_info(recs)                   # now telling factory values from ones an efuse record set
    print(f"CHIP {info['name']}, efuse protocol = {kind}")
    OUT["chip"] = {k: info[k] for k in ("name", "type", "variant", "protocol", "new_chip", "overrides",
                                        "factory_variant", "type_written")}
    if info["type_written"]:
        plan_result("REFUSED", "an efuse record writes a register the chip type is read from ("
                    + ", ".join(info["type_written"]) + ") - the type, and with it the protocol, is not certain")
        return None
    if not info["writable"]:
        plan_result("REFUSED", "a chip variant outside Realtek's tables that no efuse record explains - "
                               "its own tool refuses it too")
        return None
    print(f"EFUSE = {size} bytes ({kind} protocol), records = {len(recs)}, non-FF bytes = {sum(b != 0xFF for b in area)}")
    if not recs:
        print("PLAN NOTE = no records at all - compare the settings dump with Realtek's own tool before burning")
    if "ad" in todo and any(r["kind"] == "reg" and r["reg"] == REG for r in recs):
        plan_result("BLOCKED", "the efuse already holds a USB_MISC_0 record")
        return None
    placed = place_records(area, recs, efuse_capacity(kind, size), [RECORDS[w][0] for w in todo])
    if isinstance(placed, str):
        plan_result("BLOCKED", placed)
        return None
    items = []
    for w, (at, rec) in zip(todo, placed):
        print(f"PLAN record = {rec.hex(' ').upper()}  at 0x{at:02X}  ({RECORDS[w][1]})")
        order = list(range(1, len(rec))) + [0]
        for i in order:
            a = at + i
            word = efuse8153_write_word(a, 0xFF, rec[i])
            cmd = efuse8153_encode_write(a >> 1, word) if kind == EFUSE_OLD else efuse_v3_write_command(a, word)
            print(f"PLAN byte 0x{a:02X} = 0x{rec[i]:02X}   0xDD00 <- 0x{cmd:08X}"
                  + ("   (header, burned last - activates the record)" if i == 0 else ""))
        items.append({"name": w, "at": at, "rec": rec, "order": order})
    if kind == EFUSE_V3:
        print("PLAN V3 per byte (Realtek's tool 2.0.30): 0xE85B.0x10 and USB 0xD380 |= 0x0C for the session; "
              "efuse on; 0xDD00 bit27, wait; command, wait bit30; bit28, wait; efuse off; read back")
    print(f"PLAN PROTOCOL = {kind} - " + ("proven on hardware" if PROVEN[kind] else
                                          "written from Realtek's tool, not yet proven on hardware"))
    OUT["plan"].update(records=[{"name": it["name"], "record": it["rec"].hex(" ").upper(), "at": it["at"]}
                                for it in items],
                       record="  +  ".join(it["rec"].hex(" ").upper() for it in items), at=items[0]["at"],
                       protocol=kind, proven=PROVEN[kind])
    plan_result("OK")
    return {"kind": kind, "items": items}


def _stop(done, header):
    first = (f"{' and '.join(done)} burned and in effect; " if done else "")
    if header:
        burn_result("STOPPED", first + "the header of the next record did not verify - check the settings dump")
    else:
        burn_result("STOPPED", first + "a data byte did not verify; that record's header is still FF, so it is not "
                                       "active" + ("" if done else " and the card behaves as before"))
    return 1


def burn(c, want):
    p = plan(c, want)
    if p is None:
        return 1
    kind, items = p["kind"], p["items"]
    total = sum(len(it["order"]) for it in items)
    n, done = 0, []
    saved = c.v3_session_begin(for_write=True) if kind == EFUSE_V3 else None
    try:
        for it in items:
            at, rec = it["at"], it["rec"]
            for i in it["order"]:
                n += 1
                a = at + i
                step(f"Burning byte {n} of {total}" + (f" - the {it['name']} header" if i == 0 else "") + "...")
                back = (c.efuse8153_write_byte(a, rec[i]) if kind == EFUSE_OLD else c.efuse_v3_write_byte(a, rec[i]))
                print(f"BURN byte 0x{a:02X} = 0x{rec[i]:02X}, read back 0x{back:02X}  {'OK' if back == rec[i] else 'MISMATCH'}")
                if back != rec[i]:
                    return _stop(done, i == 0)
            done.append(it["name"])
    finally:
        if saved is not None:
            c.v3_session_end(saved)
    burn_result("OK", "  +  ".join(f"{it['rec'].hex(' ').upper()} at 0x{it['at']:02X}" for it in items)
                + " burned and verified; unplug and re-plug the card to load it")
    return 0


def main(argv):
    modes = [m for m in ("--plan", "--burn") if m in argv]
    want = argv[argv.index("--records") + 1].split(",") if "--records" in argv else ["ad"]
    if not argv or argv[0] in ("-h", "--help") or len(modes) != 1 or not want or any(w not in RECORDS for w in want):
        print("usage: marker.py {GUID} --plan | --burn  [--records ad|cfdb|cfdb,ad] [--dll new|old|auto] [--json]")
        return 2
    want = [w for w in RECORDS if w in want]          # always cfdb before ad
    guid = argv[0]
    dll = argv[argv.index("--dll") + 1] if "--dll" in argv else "auto"
    OUT["mode"] = modes[0].lstrip("-")
    OUT["want"] = want
    c = RtlDiag(guid, dll).open()
    try:
        print(f"GUID {guid}  (DLL: {c.family} v{c.version}, {c.exports} procedures)")
        c.pg_enter()
        try:
            if modes[0] == "--plan":
                ok = plan(c, want) is not None
                print("(read-only - nothing was written)")
                return 0 if ok else 1
            print("=== BURN (permanent) ===")
            return burn(c, want)
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
