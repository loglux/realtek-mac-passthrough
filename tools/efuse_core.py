"""Pure efuse logic shared by the tools and covered by regression tests (../tests/test_efuse_core.py).

No DLL, no sys.argv - import-safe. Hardware I/O (CreateFileW, the diag DLL, the 0xDD00/0xDD04 poll loop)
lives in rtldiag.py; only the arithmetic/record parsing lives here, so it can be tested without a card.
Keep this file dependency-free.
"""


def byte_enable(addr: int, size: int) -> int:
    """Byte-enable mask for a DirectReadRegister/WriteRegister request at `addr` for `size` bytes.

    The chip is addressed in 4-byte dwords; the mask says which bytes of the aligned dword are wanted.
    """
    low = addr & 3
    end = size + low
    be = 0
    i = low
    while i < end and i <= 3:
        be |= 1 << (i & 0x1f)
        i += 1
    if end > 4:
        be |= {0: 0xf0, 1: 0x10, 2: 0x30, 3: 0x70}[end & 3]
    return be & 0xFF


def build_record(reg: int, value: int) -> bytes:
    """A 1-byte USB-OCP autoload record: [hdr=0x40][reg hi][reg lo][value]. E.g. 0xCFDB=0x03 -> 40 CF DB 03."""
    return bytes([0x40, (reg >> 8) & 0xFF, reg & 0xFF, value & 0xFF])


def record_dword(reg: int, value: int) -> int:
    """The little-endian dword that build_record(reg, value) burns (what the read-back must match).

    For 0xCFDB=0x03 this is 0x03DBCF40.
    """
    return int.from_bytes(build_record(reg, value), "little")


def find_append_point(data: bytes) -> dict:
    """Where the next autoload record goes: start of the trailing 0xFF run (end of autoload), dword-aligned.

    Returns last_significant byte offset, the dword-aligned `append` offset and `dwaddr`, the current dword
    there (`cur`), and whether it is free (0xFFFFFFFF). Mirrors the logic in the burn tool.
    """
    end = len(data)
    while end > 0 and data[end - 1] == 0xFF:
        end -= 1
    append = end
    if append % 4:
        append = (append + 4) & ~3
    chunk = data[append:append + 4]
    cur = int.from_bytes(chunk, "little") if len(chunk) == 4 else 0xFFFFFFFF
    return {
        "last_significant": end - 1,
        "append": append,
        "dwaddr": append >> 2,
        "cur": cur,
        "free": cur == 0xFFFFFFFF,
    }


def parse_autoload_records(data: bytes) -> list:
    """Walk efuse autoload records: [hdr][offset BE][data...]. 0xFF = End-Of-Autoload, 0x00 = padding/skip.

    hdr: len = (hdr & 0x1F) + 1, type = hdr & 0xE0 (0xE0 = DASH, 4-byte offset; otherwise 2-byte offset).
    Returns a list of {'at': start position, 'reg': register offset, 'data': bytes}.
    """
    recs = []
    i = 0
    n = len(data)
    while i < n:
        hdr = data[i]
        if hdr == 0xFF:
            break
        if hdr == 0x00:
            i += 1
            continue
        ln = (hdr & 0x1F) + 1
        if (hdr & 0xE0) == 0xE0:  # DASH: 4-byte offset
            if i + 5 + ln > n:
                break
            reg = int.from_bytes(data[i + 1:i + 5], "big")
            payload = data[i + 5:i + 5 + ln]
            nxt = i + 5 + ln
        else:  # USB-OCP / PLA-OCP: 2-byte offset
            if i + 3 + ln > n:
                break
            reg = int.from_bytes(data[i + 1:i + 3], "big")
            payload = data[i + 3:i + 3 + ln]
            nxt = i + 3 + ln
        recs.append({"at": i, "reg": reg, "data": bytes(payload)})
        i = nxt
    return recs
