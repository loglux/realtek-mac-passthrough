"""Show where a Realtek USB card keeps its settings, and what is stored there. Read-only.

Usage:  python -I settings.py {InterfaceGUID} [--dll new|old|auto]

The chip applies its settings at power-on from its efuse (one-time programmable) or an external EEPROM
(RTL8153 datasheet 6.4). This tool works out the chip type as Realtek's own tool does (PLA 0xE612, USB 0xCD14),
dumps the efuse with that type's protocol and its decoded autoload records, and shows the start of an SPI flash if the card has one; that
flash holds the driver install disk, not chip settings. A controller that does not answer is reported,
never hung on.
The output format is stable - the GUI shows it as is.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # so sibling modules import under `python -I`

from efuse_core import (EFUSE_DWORD, EFUSE_OLD, EFUSE_V3, PG_STAMP_REGS, describe_pg_stamp, efuse_capacity,
                        efuse_provenance, parse_autoload_records, variant_name)
from passthru import chip_variant as linux_variant
from rtldiag import EfuseUnavailable, RtlDiag
from storage import flash_name, has_flash

NAMES = {0xC000: "MAC address", 0xCFDB: "SW_FEATURE - MAC clone / pass-through bits",
         0xD81A: "USB_MISC_0 - r8152 AD marker", 0xD81F: "USB_MISC_1 - r8152 BD/BND markers"}
EFUSE_BYTES = 2048      # the whole efuse address space of the dword protocol (9-bit dword address)
FLASH_BYTES = 256       # only the start of the flash is shown (header of the driver install disk)


def _hex(data: bytes, base: int = 0):
    """Hex dump; runs of all-FF lines are folded into one line so a 2 KB efuse stays readable."""
    i, n = 0, len(data)
    while i < n:
        chunk = data[i:i + 16]
        if all(b == 0xFF for b in chunk):
            j = i
            while j + 16 <= n and all(b == 0xFF for b in data[j:j + 16]):
                j += 16
            if j - i > 16:
                print(f"0x{base + i:03X}-0x{base + j - 1:03X}: all FF")
                i = j
                continue
        hexs = " ".join(f"{b:02x}" for b in chunk)
        text = "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)
        print(f"0x{base + i:03X}: {hexs:<47}  |{text}|")
        i += 16


def _ranges(data: bytes, start: int):
    """(first, last) offsets of the non-FF runs from `start` on; FF gaps shorter than 16 bytes are bridged."""
    out = []
    for i in range(start, len(data)):
        if data[i] == 0xFF:
            continue
        if out and i - out[-1][1] <= 16:
            out[-1][1] = i
        else:
            out.append([i, i])
    return out


def _records(recs):
    if not recs:
        print("  (none - the area is empty)")
    for r in recs:
        dhex = " ".join(f"{b:02X}" for b in r["data"])
        if r["kind"] == "reg":
            nm = NAMES.get(r["reg"], "")
            if r["reg"] in PG_STAMP_REGS and describe_pg_stamp(r["data"]):
                nm = "programmed with " + describe_pg_stamp(r["data"])
            print(f"  0x{r['at']:03X}: write [{dhex}] -> reg 0x{r['reg']:04X}" + (f"  ({nm})" if nm else ""))
        elif r["kind"] == "raw":
            print(f"  0x{r['at']:03X}: other command [{dhex}]  (fixed-size, not decoded)")
        else:
            print(f"  0x{r['at']:03X}: unknown record type 0x{r['data'][0]:02X} - stopped reading here")
    regs = {r["reg"]: r["data"] for r in recs if r["kind"] == "reg"}
    if 0xCFDB in regs:   # several records may write it - the chip applies them in order, the last one wins
        print(f"  => 0xCFDB ends up as 0x{regs[0xCFDB][-1]:02X} (the last record wins)")


def _provenance(p):
    """Factory state or modified: records after Realtek's last stamp were added later (efuse_provenance)."""
    if not p["stamped"]:
        print("  no stamp of Realtek's tool - cannot tell factory records from ones added later")
        return
    if not p["added"]:
        print("  FACTORY STATE: no records after the stamp of Realtek's tool - nothing was added since")
        return
    who = ("not by Realtek's tool: no new stamp, and the write counter shows no extra session"
           if p["by_realtek"] is False else
           "the write counter shows extra sessions - possibly Realtek's tool" if p["by_realtek"] else "")
    print(f"  MODIFIED: {len(p['added'])} record(s) added after the factory programming" + (f" ({who})" if who else ""))
    for a in p["added"]:
        what = (f"0x{a['reg']:04X} = {' '.join(f'{b:02X}' for b in a['data'])}" if a["reg"] is not None
                else "a command record")
        print(f"  0x{a['at']:03X}        added later: {what}" + (f" - {a['own']}" if a["own"] else ""))


def _summary(recs, data, start, store, counter_at=None, misc=None, capacity=None):
    """Plain-language reading of a dump: what is records, what is empty space, and the write counter (the last
    byte of the efuse area: Realtek's tool burns one bit of it per programming session). `capacity` = where
    Realtek's reserved tail starts: free space is counted up to it, as its tool does."""
    end = recs[-1]["at"] + recs[-1]["size"] if recs else start
    print("in plain words:")
    if recs:
        print(f"  0x{start:03X}-0x{end - 1:03X}  {len(recs)} setting record(s), listed above; the chip applies them at power-on")
    else:
        print(f"  no setting records at all - the chip takes nothing from its {store} and runs on its factory defaults")
    counted = counter_at is not None and end <= counter_at < len(data)
    scan = bytearray(data)
    if counted:
        scan[counter_at] = 0xFF
    others = _ranges(bytes(scan), end)
    free_to = (others[0][0] if others else len(data)) - 1
    if counted:
        free_to = min(free_to, counter_at - 1)
    tail = counted and capacity is not None and end <= capacity <= counter_at
    if tail:
        free_to = min(free_to, capacity - 1)
    if end <= free_to:
        print(f"  0x{end:03X}-0x{free_to:03X}  all FF = empty: never written ({free_to - end + 1} bytes free; FF is the blank state)")
    if tail and capacity < counter_at:
        print(f"  0x{capacity:03X}-0x{counter_at - 1:03X}  reserved by Realtek's tool - never used for records")
    if counted:
        n = 8 - bin(data[counter_at]).count("1")
        print(f"  0x{counter_at:03X}        {data[counter_at]:02X} = write counter: {n} programming session(s) by Realtek's tool "
              "(one bit burned per session)")
    for a, b in others:
        print(f"  0x{a:03X}-0x{b:03X}  other data - not setting records (the records end at the first FF), not decoded")
    _provenance(efuse_provenance(recs, data[counter_at] if counted else None))
    regs = {r["reg"] for r in recs if r["kind"] == "reg"}
    if 0xCFDB not in regs:
        print("  no 0xCFDB record - the pass-through bits are the chip's own default")
    if 0xD81A not in regs and 0xD81F not in regs:
        print("  no USB_MISC record - the chip-variant value comes from the chip itself, not from these records")
        if misc:
            print(f"               (USB_MISC_0 = 0x{misc[0]:04X}, USB_MISC_1 = 0x{misc[1]:02X}: {misc[2]})")
    elif misc:
        print("  USB_MISC record - not a factory value: the chip applies it over its own chip-variant value")
        print(f"               (now USB_MISC_0 = 0x{misc[0]:04X}, USB_MISC_1 = 0x{misc[1]:02X}: {misc[2]})")


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print("usage: settings.py {InterfaceGUID} [--dll new|old|auto]")
        return 2
    guid = argv[0]
    dll = argv[argv.index("--dll") + 1] if "--dll" in argv else "auto"
    c = RtlDiag(guid, dll).open()
    try:
        print(f"GUID {guid}  (DLL: {c.family} v{c.version}, {c.exports} procedures)")

        _, jedec = c.flash_id()
        flash = c.flash_read(0, FLASH_BYTES) if has_flash(jedec) else None

        info = c.chip_info()
        m0, m1 = c.usb_read(0xD81A, 2), c.usb_read(0xD81F, 1)
        kind, size = info["protocol"], info["size"]
        efuse, proto = None, ""
        c.pg_enter()
        try:
            if kind == EFUSE_DWORD:
                c.efuse_enable()
                try:
                    efuse, proto = c.efuse_dump(EFUSE_BYTES), EFUSE_DWORD + " protocol"
                finally:
                    c.efuse_disable()
            elif kind == EFUSE_V3:
                efuse, proto = c.efuse_v3_dump(size), EFUSE_V3 + " protocol"
            elif kind == EFUSE_OLD:
                efuse, proto = c.efuse8153_dump(size), EFUSE_OLD + " protocol"
        except EfuseUnavailable:
            efuse = None
        finally:
            c.pg_leave()

        recs = parse_autoload_records(efuse) if efuse is not None else None
        if recs is not None:
            info = c.chip_info(recs)               # tells factory values from ones an efuse record set
        lin = linux_variant(m0, m1)
        realtek = variant_name(info["factory_variant"] if info["overrides"] else info["variant"])
        misc = (m0, m1, (f'Linux sees "-{lin}"' if lin else 'Linux sees a plain chip')
                + (f', Realtek calls the chip itself {realtek}' if realtek and info["overrides"] else
                   f', Realtek calls it {realtek}' if realtek else ''))
        print(f"CHIP {info['name']}")
        print("STORAGE efuse = " + (f"responding ({proto})" if efuse is not None else
              "could not be read - chip type not known to this tool, or the controller did not answer"))
        print("STORAGE flash = " + (f"{flash_name(jedec)} - holds the driver install disk, not chip settings"
                                    if flash is not None else "none"))

        if efuse is not None and recs is not None:
            print(f"\n=== EFUSE ({len(efuse)} bytes - the whole address space, one-time programmable) ===")
            _hex(efuse)
            print("records:")
            _records(recs)
            _summary(recs, efuse, 0, "efuse", counter_at=size - 1 if size else None, misc=misc,
                     capacity=efuse_capacity(kind, size) if size else None)
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
