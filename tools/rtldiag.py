"""Unified Realtek diag-DLL backend.

Loads either diag DLL and auto-detects old vs new by its EXPORTS (API_* vs Direct_API_*), so one code
path drives both. Two register spaces, two primitives:
  - plain USB-OCP registers (0xCFDB, USB_MISC) -> USBDirectRead (reliable, no off-by-one);
  - the efuse controller (0xDD00/0xDD04)        -> byte-enable DirectReadRegister/WriteRegister.

No sys.argv here - callers pass a GUID. The vendor DLL is NOT shipped; point to it with env vars
RTLDIAG_DLL_NEW / RTLDIAG_DLL_OLD, or rely on the in-repo downloads/ paths during development.
"""
import ctypes
import os
import struct
from ctypes import wintypes

from efuse_core import byte_enable, chip_type, efuse8153_decode_read, efuse8153_encode_write, efuse8153_write_word

_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.dirname(os.path.dirname(_HERE))   # CardInspector/tools -> CardInspector -> repo root
INVALID = ctypes.c_void_p(-1).value

_K32 = ctypes.WinDLL("kernel32", use_last_error=True)
_CF = _K32.CreateFileW
_CF.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p]
_CF.restype = ctypes.c_void_p
_CH = _K32.CloseHandle
_CH.argtypes = [ctypes.c_void_p]
_CH.restype = wintypes.BOOL


def _candidate_dirs():
    """Folders to look in for a diag DLL, in priority order (each keeps the DLL next to its own deps)."""
    dirs = []
    env = os.environ.get("RTLDIAG_DLL_DIR")
    if env:
        dirs.append(env)
    app = os.path.abspath(os.path.join(_HERE, "..", "dll"))
    dirs.append(app)                                                                 # dll/ itself
    if os.path.isdir(app):
        for sub in sorted(os.listdir(app)):                                          # any sub-folder name
            p = os.path.join(app, sub)
            if os.path.isdir(p):
                dirs.append(p)
    dirs.append(os.path.join(_REPO, "downloads", "diag-tool"))                       # dev fallback
    dirs.append(os.path.join(_REPO, "downloads", "pgtool-win", "run", "x64"))        # dev fallback
    out = []
    for d in dirs:
        ad = os.path.abspath(d)
        if os.path.isdir(ad) and ad not in out:
            out.append(ad)
    return out


def count_exports(path):
    """Number of exported functions in a PE DLL, read straight from the file (stdlib only)."""
    try:
        with open(path, "rb") as f:
            data = f.read()
        if data[:2] != b"MZ":
            return None
        e = struct.unpack_from("<I", data, 0x3C)[0]
        if data[e:e + 4] != b"PE\0\0":
            return None
        coff = e + 4
        nsec = struct.unpack_from("<H", data, coff + 2)[0]
        opt_size = struct.unpack_from("<H", data, coff + 16)[0]
        opt = coff + 20
        magic = struct.unpack_from("<H", data, opt)[0]
        rva = struct.unpack_from("<I", data, opt + (112 if magic == 0x20B else 96))[0]  # export dir RVA
        if rva == 0:
            return 0
        sect = opt + opt_size
        for i in range(nsec):
            s = sect + i * 40
            vsize = struct.unpack_from("<I", data, s + 8)[0]
            vaddr = struct.unpack_from("<I", data, s + 12)[0]
            praw = struct.unpack_from("<I", data, s + 20)[0]
            if vaddr <= rva < vaddr + max(vsize, 1):
                return struct.unpack_from("<I", data, praw + (rva - vaddr) + 0x14)[0]  # NumberOfFunctions
        return None
    except Exception:
        return None


# The ~8 commands this app actually calls (out of the 60-200 a diag DLL exports). A DLL is "usable"
# only if it exports ALL of these - that is how we know we understand its command set, not by the count.
_REQUIRED = ["EnableRTKDiag", "DisableRTKDiag", "DirectReadRegister", "DirectWriteRegister",
             "Usb_EnterPGMode", "Usb_LeavePGMode"]


def _missing_cmds(dll, prefix):
    """Required commands (for this DLL's API prefix) that the DLL does NOT export - empty list = usable."""
    miss = [prefix + c for c in _REQUIRED if not hasattr(dll, prefix + c)]
    usbrd = "Direct_USBDirectRead" if prefix == "Direct_API_" else "USBDirectRead"
    if not hasattr(dll, usbrd):
        miss.append(usbrd)
    return miss


def file_version(path):
    """The DLL's own FileVersion from its version resource (e.g. '5.0.0.2'), or None. Self-describing."""
    try:
        v = ctypes.WinDLL("version")
        v.GetFileVersionInfoSizeW.argtypes = [wintypes.LPCWSTR, ctypes.POINTER(wintypes.DWORD)]
        v.GetFileVersionInfoSizeW.restype = wintypes.DWORD
        v.GetFileVersionInfoW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p]
        v.GetFileVersionInfoW.restype = wintypes.BOOL
        v.VerQueryValueW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR, ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(wintypes.UINT)]
        v.VerQueryValueW.restype = wintypes.BOOL
        dummy = wintypes.DWORD(0)
        size = v.GetFileVersionInfoSizeW(path, ctypes.byref(dummy))
        if not size:
            return None
        buf = ctypes.create_string_buffer(size)
        if not v.GetFileVersionInfoW(path, 0, size, buf):
            return None
        ptr = ctypes.c_void_p()
        ln = wintypes.UINT(0)
        if not v.VerQueryValueW(buf, "\\", ctypes.byref(ptr), ctypes.byref(ln)) or not ptr:
            return None
        data = ctypes.string_at(ptr, ln.value)
        ms, ls = struct.unpack_from("<II", data, 8)  # VS_FIXEDFILEINFO: dwFileVersionMS @8, dwFileVersionLS @12
        return f"{ms >> 16}.{ms & 0xFFFF}.{ls >> 16}.{ls & 0xFFFF}"
    except Exception:
        return None


def classify(path):
    """(kind, exports, missing, version) for a diag DLL: kind 'new'/'old' by its command set, the export
    count, the required commands it lacks (empty = usable), and its FileVersion. kind None if not a diag DLL."""
    n = count_exports(path)
    ver = file_version(path)
    try:
        os.add_dll_directory(os.path.dirname(os.path.abspath(path)))
        d = ctypes.WinDLL(path)
    except OSError:
        return None, n, None, ver
    if hasattr(d, "Direct_API_DirectReadRegister"):
        prefix, kind = "Direct_API_", "new"
    elif hasattr(d, "API_DirectReadRegister"):
        prefix, kind = "API_", "old"
    else:
        return None, n, None, ver
    return kind, n, _missing_cmds(d, prefix), ver


def discover():
    """Scan candidate dirs and classify diag DLLs by exports. Returns {kind: {'path':..., 'exports':...}}."""
    found = {}
    for d in _candidate_dirs():
        for f in sorted(os.listdir(d)):
            if not f.lower().endswith(".dll") or "directdiag" not in f.lower():
                continue  # only the diag DLL (by name stem); deps like RTDiagLibV2/cygwin1 are skipped
            kind, n, missing, ver = classify(os.path.join(d, f))
            if kind and kind not in found:
                found[kind] = {"path": os.path.join(d, f), "exports": n, "missing": missing, "version": ver}
    return found


def resolve_dll(which: str) -> str:
    """'auto'|'new'|'old' -> a DLL path chosen by export-classification; or an explicit path."""
    if which in ("new", "old", "auto"):
        found = discover()
        order = ("new", "old") if which == "auto" else (which,)
        for k in order:
            if k in found:
                return found[k]["path"]
        raise FileNotFoundError(
            f"no '{which}' Realtek diag DLL found. Put RtlDirectDiagLib64.dll (with its deps) in "
            f"the tool's dll/ folder, or set RTLDIAG_DLL_DIR. Detected: {sorted(found)}")
    if not os.path.exists(which):
        raise FileNotFoundError(f"DLL not found: {which}")
    return which


class EfuseUnavailable(OSError):
    """The efuse controller never answered - the chip keeps its settings somewhere else (e.g. SPI flash)."""


class RtlDiag:
    """Open a Realtek USB card through the diag DLL and read/write its registers and efuse.

    Usage:  with RtlDiag(guid, dll="new") as c: c.usb_read(0xCFDB, 1); c.efuse_dump(128)
    """

    def __init__(self, guid: str, dll: str = "auto"):
        self.guid = guid
        self.dev = r"\\.\RealTekUsbCard" + guid
        self.path = resolve_dll(dll)
        self.exports = count_exports(self.path)
        self.version = file_version(self.path)
        os.add_dll_directory(os.path.dirname(self.path))
        d = ctypes.WinDLL(self.path)
        if hasattr(d, "Direct_API_DirectReadRegister"):
            self.prefix, self.kind = "Direct_API_", "new"
        elif hasattr(d, "API_DirectReadRegister"):
            self.prefix, self.kind = "API_", "old"
        else:
            raise RuntimeError(f"{self.path}: not a Realtek diag DLL (no DirectReadRegister export)")
        self.family = self.prefix.rstrip("_")   # 'Direct_API' or 'API' - the objective command-set family
        self.missing = _missing_cmds(d, self.prefix)
        if self.missing:
            raise RuntimeError(f"{self.path}: diag DLL is missing required command(s): {', '.join(self.missing)}")
        p = self.prefix
        self._En  = self._bind(d, p + "EnableRTKDiag", 1)
        self._Dis = self._bind(d, p + "DisableRTKDiag", 1)
        self._DRd = self._bind(d, p + "DirectReadRegister", 2)
        self._DWr = self._bind(d, p + "DirectWriteRegister", 2)
        try:
            self._PGon  = self._bind(d, p + "Usb_EnterPGMode", 1)
            self._PGoff = self._bind(d, p + "Usb_LeavePGMode", 1)
        except AttributeError:
            self._PGon = self._PGoff = None
        self._USBRd = getattr(d, "Direct_USBDirectRead", None) or getattr(d, "USBDirectRead", None)
        if self._USBRd is not None:
            self._USBRd.argtypes = [ctypes.c_void_p, ctypes.c_ubyte, ctypes.c_uint, ctypes.c_void_p, ctypes.c_ushort]
            self._USBRd.restype = ctypes.c_int
        self._Bcd = getattr(d, p + "ReadbcdDevice", None)
        if self._Bcd is not None:
            self._Bcd.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint)]
            self._Bcd.restype = None
        self.h = None
        self.ctx = None

    @staticmethod
    def _bind(dll, name, n):
        f = getattr(dll, name)
        f.argtypes = [ctypes.c_void_p] * n
        f.restype = ctypes.c_int
        return f

    def open(self):
        self.h = _CF(self.dev, 0xC0000000, 0, None, 3, 0x40000000, None)
        if self.h in (None, 0, INVALID):
            raise OSError(f"open GLE={ctypes.get_last_error()} (run as admin? card connected?)")
        self.ctx = (ctypes.c_ubyte * 0x800)()
        ctypes.cast(self.ctx, ctypes.POINTER(ctypes.c_void_p))[0] = self.h
        ctypes.cast(ctypes.addressof(self.ctx) + 0x198, ctypes.POINTER(ctypes.c_uint16))[0] = 2
        if self._En(self.ctx) != 1:
            raise OSError("EnableRTKDiag != 1")
        return self

    def close(self):
        try:
            if self.ctx is not None:
                self._Dis(self.ctx)
        finally:
            if self.h not in (None, 0, INVALID):
                _CH(ctypes.c_void_p(self.h))

    def __enter__(self):
        return self.open()

    def __exit__(self, *exc):
        self.close()

    # --- byte-enable register path (reaches the efuse controller) ---
    def _mkreq(self, addr, size, data=None):
        off = addr & 3
        aligned = addr & ~3
        length = size + off
        if length < 5:
            length = 4
        req = (ctypes.c_ubyte * 0x1100)()
        ctypes.cast(req, ctypes.POINTER(ctypes.c_uint16))[0] = aligned & 0xFFFF
        ctypes.cast(ctypes.addressof(req) + 2, ctypes.POINTER(ctypes.c_uint16))[0] = length & 0xFFFF
        req[4] = byte_enable(addr, size)
        req[5] = 1
        if data is not None:
            for i, bb in enumerate(data):
                req[6 + off + i] = bb
        return req, off

    def dread(self, addr, size):
        req, off = self._mkreq(addr, size)
        self._DRd(self.ctx, req)
        return bytes(req)[6 + off:6 + off + size]

    def dwrite(self, addr, size, data):
        req, _ = self._mkreq(addr, size, data)
        return self._DWr(self.ctx, req)

    # --- USBDirectRead for plain USB-OCP registers (no off-by-one) ---
    def usb_read(self, addr, size):
        if self._USBRd is None:
            raise RuntimeError("USBDirectRead not exported by this DLL")
        buf = (ctypes.c_ubyte * size)()
        self._USBRd(ctypes.cast(self.ctx, ctypes.c_void_p), 0, addr & 0xffff, ctypes.cast(buf, ctypes.c_void_p), size)
        return int.from_bytes(bytes(buf), "little")

    def read_bcd(self):
        """bcdDevice (REV) from the USB descriptor, or None if the DLL does not export it."""
        if self._Bcd is None:
            return None
        rev = ctypes.c_uint(0)
        self._Bcd(ctypes.cast(self.ctx, ctypes.c_void_p), ctypes.byref(rev))
        return rev.value & 0xffff

    # --- SPI flash identification (read-only: JEDEC ID, command 0x9F) ---
    # Bit-banged through PLA register 0xE81D exactly as RTUNicPG does (FlashChipSelect / FlashSetCommand):
    # 0x80 = select, 0xC0 = deselect, data-in bit = 0x10, clock low/high = 0x80/0xA0, data-out = bit3.
    # The two interface-enable registers are put back as they were afterwards.
    def _rb(self, reg):
        # read the whole aligned dword and pick the byte - a single unaligned byte read does not return
        # the flash data bit (0xE81D bit3) reliably; this is how the working reader does it
        return (int.from_bytes(self.dread(reg & ~3, 4), "little") >> ((reg & 3) * 8)) & 0xFF

    def _wb(self, reg, val):
        self.dwrite(reg, 1, bytes([val & 0xFF]))

    def _spi(self, cmd, nread=0, addr=None, data=b""):
        """One SPI transaction: select, send command (+ 24-bit address, + data), clock in `nread` bytes, deselect."""
        self._wb(0xE81D, 0xC0)
        self._wb(0xE81D, 0x80)                             # chip select
        out_bytes = [cmd]
        if addr is not None:
            out_bytes += [(addr >> 16) & 0xFF, (addr >> 8) & 0xFF, addr & 0xFF]
        out_bytes += list(data)
        for c in out_bytes:                                # MSB first
            for _ in range(8):
                di = ((c >> 7) & 1) << 4
                self._wb(0xE81D, di | 0x80)
                self._wb(0xE81D, di | 0xA0)
                c = (c << 1) & 0xFF
        out = []
        for _ in range(nread):
            v = 0
            for _ in range(8):
                self._wb(0xE81D, 0x80)
                self._wb(0xE81D, 0xA0)
                v = (v << 1) | (1 if self._rb(0xE81D) & 0x08 else 0)
            out.append(v)
        self._wb(0xE81D, 0xC0)                             # deselect
        return bytes(out)

    def _flash_session(self, fn):
        """Run fn() with the SPI interface enabled (PG mode); put the two enable registers back afterwards."""
        pg = self.pg_enter()                               # the SPI interface only answers in PG mode
        e84c, e81c = self._rb(0xE84C), self._rb(0xE81C)
        try:
            self._wb(0xE84C, e84c | 0x10)
            self._wb(0xE81C, e81c | 0xC0)                 # enable the SPI interface
            return fn()
        finally:
            self._wb(0xE81C, e81c)
            self._wb(0xE84C, e84c)
            if pg == 1:
                self.pg_leave()

    def flash_id(self):
        """(storage-status byte at 0xDC00, 3-byte JEDEC ID). An ID of 00 00 00 / FF FF FF = no SPI flash."""
        dc00 = self._rb(0xDC00)
        return dc00, self._flash_session(lambda: self._spi(0x9F, 3))

    # --- SPI flash writes: the same sequence RTUNicPG uses (FlashWritePage / FlashErase) ---
    def _flash_wait(self, polls=20000):
        for _ in range(polls):
            s = self._spi(0x05, 1)[0]
            if not s & 1:                                   # bit0 = write in progress
                return s
        raise OSError("SPI flash stayed busy - timed out")

    def _flash_wren(self):
        self._spi(0x06)                                     # Write Enable
        s = self._spi(0x05, 1)[0]
        if not s & 2:                                       # bit1 = write-enable latch
            raise OSError(f"SPI flash did not accept Write Enable (status 0x{s:02X})")

    def flash_write_page(self, addr, data):
        """Program bytes inside one 256-byte page (0x02). Only turns 1-bits into 0 - write over 0xFF."""
        if not data or (addr & 0xFF) + len(data) > 256:
            raise ValueError("a page program must stay inside one 256-byte page")
        def go():
            self._flash_wren()
            self._spi(0x02, 0, addr, data)
            return self._flash_wait()
        return self._flash_session(go)

    def flash_erase_sector(self, addr):
        """Erase the 4 KB sector containing addr (0x20) - back to all 0xFF."""
        def go():
            self._flash_wren()
            self._spi(0x20, 0, addr & ~0xFFF)
            return self._flash_wait()
        return self._flash_session(go)

    def flash_status(self):
        """SPI flash status register (command 0x05): bit0 = busy, bits 2-4 = write-protect. Read-only."""
        return self._flash_session(lambda: self._spi(0x05, 1))[0]

    def flash_read(self, addr, n):
        """Read n bytes of the SPI flash from addr (command 0x03). Read-only. Bit-banged, so keep n small
        (the settings area is the first few hundred bytes; a full 2 MB read would take hours)."""
        return self._flash_session(lambda: self._spi(0x03, n, addr))

    # --- PG mode + efuse ---
    def pg_enter(self):
        return self._PGon(self.ctx) if self._PGon else -1

    def pg_leave(self):
        return self._PGoff(self.ctx) if self._PGoff else -1

    def efuse_enable(self):
        v = self.dread(0xE85B, 1)[0]
        self.dwrite(0xE85B, 1, bytes([(v | 0xC4) & 0xFF]))
        return v

    def efuse_disable(self):
        v = self.dread(0xE85B, 1)[0]
        self.dwrite(0xE85B, 1, bytes([v & 0x3B]))

    # Two efuse protocols (RTUNicPG branches on the chip family):
    #   newer chips (RTL8156...): dword protocol, command word at 0xDD04         -> efuse_read_dword / _write_dword
    #   older chips (RTL8153...): 17-bit cells, command word at 0xDD02 (as r8152) -> efuse8153_read_byte (read only)
    # An older chip never clears the 0xDD04 busy bit - so: bounded poll, and a clear error on the first timeout.
    EFUSE_POLLS = 2000

    def _efuse_wait(self, busy_bit):
        for _ in range(self.EFUSE_POLLS):
            c = int.from_bytes(self.dread(0xDD04, 2), "little")
            if not (c & busy_bit):
                return c
        raise EfuseUnavailable(
            "efuse controller does not answer the RTL8156 protocol (busy bit never clears). Nothing was written.")

    def efuse8153_read_byte(self, addr):
        """Older-family efuse read, ported from RTUNicPG EFuseRead (FUN_14001c8d0): 0xDD02 = 0x8000 | addr/2,
        wait for bit31 of the 0xDD00 dword to clear, then undo the per-word bit rotation of the 17-bit cell."""
        self.dwrite(0xDD00, 4, ((0x80000000 | ((addr & 0xFE) << 15)) & 0xFFFFFFFF).to_bytes(4, "little"))
        for _ in range(self.EFUSE_POLLS):
            v = int.from_bytes(self.dread(0xDD00, 4), "little")
            if not v & 0x80000000:
                break
        else:
            raise EfuseUnavailable("efuse controller does not answer the RTL8153 protocol either. Nothing was written.")
        if ((v >> 16) & 0x7F) != ((addr >> 1) & 0x7F):
            raise EfuseUnavailable("efuse controller did not echo the requested address - read not trusted.")
        word = efuse8153_decode_read(v)
        return (word >> 8 if addr & 1 else word) & 0xFF

    def efuse8153_write_byte(self, addr, new):
        """Older-family efuse byte write (RTUNicPG EFuseWrite, FUN_14001cc90). PERMANENT. Returns the read-back.

        Enable write (0xE85B |= 0xC4), send the encoded dword to 0xDD00, wait for bit30 to clear, disable write
        (always - the tool skips that on errors), then read the byte back."""
        old = self.efuse8153_read_byte(addr)
        dword = efuse8153_encode_write(addr >> 1, efuse8153_write_word(addr, old, new))
        self.efuse_enable()
        try:
            self.dwrite(0xDD00, 4, dword.to_bytes(4, "little"))
            for _ in range(self.EFUSE_POLLS):
                if not int.from_bytes(self.dread(0xDD00, 4), "little") & 0x40000000:
                    break
            else:
                raise EfuseUnavailable("efuse write did not finish (busy bit never cleared).")
        finally:
            self.efuse_disable()
        return self.efuse8153_read_byte(addr)

    def efuse8153_dump(self, nbytes=192):
        """User efuse of an older-family chip (RTUNicPG reads 192 bytes for RTL8153B)."""
        return bytes(self.efuse8153_read_byte(a) for a in range(nbytes))

    def chip_type(self):
        """Realtek's chip type (efuse_core.chip_type) from PLA 0xE612 and USB 0xCD14; 0 if not known."""
        e612 = int.from_bytes(self.dread(0xE612, 2), "little")
        cd14 = self.usb_read(0xCD14, 1) if self._USBRd is not None else 0
        return chip_type(e612, cd14)

    def efuse_v3_dump(self, nbytes=0xD0):
        """Efuse of a late RTL8153B/C (types 0x3105/06, 0x3204/05), as Realtek's tool 2.0.19 reads it:
        0xE85B |= 0x10 and |= 0xC4, then per byte 0xDD00 = 0x80000000 | (addr & 0x1FE) << 15, wait for bit31,
        take the low (even address) or second (odd) byte. Without the 0x10 bit the controller answers with FF.
        0xE85B is put back as it was."""
        orig = self.dread(0xE85B, 1)[0]
        self.dwrite(0xE85B, 1, bytes([orig | 0x10]))
        self.efuse_enable()
        out = bytearray()
        try:
            for a in range(nbytes):
                self.dwrite(0xDD00, 4, ((0x80000000 | ((a & 0x1FE) << 15)) & 0xFFFFFFFF).to_bytes(4, "little"))
                for _ in range(self.EFUSE_POLLS):
                    v = int.from_bytes(self.dread(0xDD00, 4), "little")
                    if not v & 0x80000000:
                        break
                else:
                    raise EfuseUnavailable("efuse controller does not answer (V3 protocol). Nothing was written.")
                out.append((v >> 8 if a & 1 else v) & 0xFF)
        finally:   # put it back in Realtek's order: efuse off (& 0x3B), then the 0x10 bit (& 0xEF)
            self.efuse_disable()
            v = self.dread(0xE85B, 1)[0]
            self.dwrite(0xE85B, 1, bytes([(v & 0xEF) | (orig & 0x10)]))
        return bytes(out)

    def efuse_read_dword(self, dw):
        self.dwrite(0xDD04, 2, ((dw & 0x1ff) | 0x8000).to_bytes(2, "little"))
        self._efuse_wait(0x8000)
        return int.from_bytes(self.dread(0xDD00, 4), "little")

    def efuse_write_dword(self, dw, dwdata):
        self.dwrite(0xDD00, 4, dwdata.to_bytes(4, "little"))
        self.dwrite(0xDD04, 2, ((dw & 0x1ff) | 0x4000).to_bytes(2, "little"))
        return self._efuse_wait(0x4000)

    def efuse_dump(self, nbytes=256):
        data = bytearray()
        for dw in range(nbytes // 4):
            data += self.efuse_read_dword(dw).to_bytes(4, "little")
        return bytes(data)
