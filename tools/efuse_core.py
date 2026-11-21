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


def build_record_bytes(reg: int, data: bytes) -> bytes:
    """A register-write autoload record of any length: [0x40 | (len-1)][reg 2B BE][data].

    E.g. USB_MISC_0 (0xD81A) = 0x1000 -> data 00 10 (little-endian) -> 41 D8 1A 00 10.
    """
    if not 1 <= len(data) <= 32:
        raise ValueError("record data must be 1..32 bytes")
    return bytes([0x40 | (len(data) - 1), (reg >> 8) & 0xFF, reg & 0xFF]) + bytes(data)


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


PG_STAMP_REG = 0xD3A0   # Realtek's programming tool leaves its own version and its CFG version here


def describe_pg_stamp(data: bytes) -> str:
    """'PG tool 2.19, CFG 1028' from a 4-byte 0xD3A0 record (13 02 04 04), or '' if it does not fit.

    Matched against Realtek's own tool on a real RTL8156BG: its log said "Nic PG version = 2.19" and
    "Nic CFG version = 1028" for an efuse whose 0xD3A0 record is 13 02 04 04.
    """
    if len(data) != 4:
        return ""
    return f"PG tool {data[1]}.{data[0]:02d}, CFG {int.from_bytes(data[2:4], 'little')}"
# --- RTL8153-family (older) efuse: 17-bit cells, command word at 0xDD02 -------------------------------------
# Ported 1:1 from RTUNicPG: FUN_14001c630 (write encode) and FUN_14001c8d0 (read decode). Each 16-bit word is
# stored in a 17-bit cell with one "hole" bit whose position depends on the word address; the encoder inserts
# it (set to 1 = leave unprogrammed), the decoder removes it. Byte writes go through a word whose other byte
# is 0xFF (= untouched): programming only clears bits, 1s are no-ops.

def efuse8153_shift(waddr: int) -> int:
    s = waddr & 0xF
    if waddr & 0x10:
        s = 0x10 - s
    return s


def efuse8153_encode_write(waddr: int, word: int) -> int:
    """The 0xDD00 dword that programs 16-bit `word` into efuse word `waddr` (write command 0x4000 | waddr)."""
    s = efuse8153_shift(waddr)
    v = ((word >> s) << (s + 1)) & 0xFFFFFFFF
    if s:
        v |= ((word << (32 - s)) & 0xFFFFFFFF) >> (32 - s)
    low = v & 0xFFFF
    if (v >> 16) & 1:
        low |= 0x800000
    hole = 0x17 if s == 0x10 else s
    return ((1 << hole) | ((waddr & 0x7F | 0x4000) << 16) | low) & 0xFFFFFFFF


def efuse8153_decode_read(v: int) -> int:
    """16-bit word from the 0xDD00 dword after a read command (its high word echoes the word address)."""
    s = efuse8153_shift((v >> 16) & 0x1F)
    cell = ((v >> 7) & 0x10000) | (v & 0xFFFF)
    w = ((cell >> (s + 1)) << s) & 0xFFFFFFFF
    if s:
        w |= ((cell << (32 - s)) & 0xFFFFFFFF) >> (32 - s)
    return w & 0xFFFF


def efuse8153_write_word(addr: int, old_byte: int, new_byte: int) -> int:
    """EFuseWrite's word for one byte: (~old | new) in this byte's half, 0xFF (untouched) in the other half."""
    b = (~old_byte | new_byte) & 0xFF
    return (b << 8 | 0x00FF) if addr & 1 else (b | 0xFF00)


FLASH_RECORDS_START = 0x008   # SPI flash: an 8-byte header, then autoload records until the first 0xFF


def parse_flash_records(data: bytes) -> list:
    """Records in an SPI-flash settings area: skip the 8-byte header, then the same grammar as efuse.

    The header is left as is (the chip scans to the first 0xFF, it does not read a length from it).
    'at' positions are absolute flash offsets.
    """
    recs = parse_autoload_records(data[FLASH_RECORDS_START:])
    for r in recs:
        r["at"] += FLASH_RECORDS_START
    return recs


def flash_append_point(data: bytes) -> int:
    """Where the next record goes in an SPI-flash settings area: right after the last record."""
    recs = parse_flash_records(data)
    if not recs:
        return FLASH_RECORDS_START
    last = recs[-1]
    return last["at"] + last["size"]


# Record kinds by the top 3 bits of the first byte - the classifier in RTUNicPG (FUN_14005eba0):
#   0x20 / 0x40  register write: [hdr][reg 2B BE][data], data length (hdr & 0x1F) + 1   (PLA / USB space)
#   0xE0         DASH register write: [hdr][reg 4B BE][data], length (hdr & 0x0F) + 1
#   0x60 / 0x80 / 0xA0   other autoload commands of a fixed size (4 / 5 / 2 bytes) - not decoded here
#   0xC0         size not known -> parsing stops there rather than guessing
FIXED_SIZE = {0x60: 4, 0x80: 5, 0xA0: 2}


def parse_autoload_records(data: bytes) -> list:
    """Walk autoload records. 0xFF = End-Of-Autoload, 0x00 = padding/skip.

    Returns a list of {'at', 'kind', 'reg', 'data'}: kind 'reg' = a register write (reg = its offset),
    'raw' = a fixed-size command we do not decode (reg None, data = the whole record), 'unknown' = a type
    whose size is not known - it is the last item and parsing stopped there.
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
        t = hdr & 0xE0
        if t in (0x20, 0x40):
            ln = (hdr & 0x1F) + 1
            if i + 3 + ln > n:
                break
            recs.append({"at": i, "kind": "reg", "reg": int.from_bytes(data[i + 1:i + 3], "big"),
                         "data": bytes(data[i + 3:i + 3 + ln]), "size": 3 + ln})
            i += 3 + ln
        elif t == 0xE0:
            ln = (hdr & 0x0F) + 1
            if i + 5 + ln > n:
                break
            recs.append({"at": i, "kind": "reg", "reg": int.from_bytes(data[i + 1:i + 5], "big"),
                         "data": bytes(data[i + 5:i + 5 + ln]), "size": 5 + ln})
            i += 5 + ln
        elif t in FIXED_SIZE:
            size = FIXED_SIZE[t]
            if i + size > n:
                break
            recs.append({"at": i, "kind": "raw", "reg": None, "data": bytes(data[i:i + size]), "size": size})
            i += size
        else:
            recs.append({"at": i, "kind": "unknown", "reg": None, "data": bytes(data[i:i + 1]), "size": 1})
            break
    return recs
