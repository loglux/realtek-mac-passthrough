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

from efuse_core import byte_enable

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
            f"RtlPassthru/dll/, or set RTLDIAG_DLL_DIR. Detected: {sorted(found)}")
    if not os.path.exists(which):
        raise FileNotFoundError(f"DLL not found: {which}")
    return which


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

    def efuse_read_dword(self, dw):
        self.dwrite(0xDD04, 2, ((dw & 0x1ff) | 0x8000).to_bytes(2, "little"))
        for _ in range(10000):
            if not (int.from_bytes(self.dread(0xDD04, 2), "little") & 0x8000):
                break
        return int.from_bytes(self.dread(0xDD00, 4), "little")

    def efuse_write_dword(self, dw, dwdata):
        self.dwrite(0xDD00, 4, dwdata.to_bytes(4, "little"))
        self.dwrite(0xDD04, 2, ((dw & 0x1ff) | 0x4000).to_bytes(2, "little"))
        c = 0x4000
        for _ in range(10000):
            c = int.from_bytes(self.dread(0xDD04, 2), "little")
            if not (c & 0x4000):
                break
        return c

    def efuse_dump(self, nbytes=256):
        data = bytearray()
        for dw in range(nbytes // 4):
            data += self.efuse_read_dword(dw).to_bytes(4, "little")
        return bytes(data)
