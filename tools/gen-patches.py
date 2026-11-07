#!/usr/bin/env python3
"""Write data/<model>/bootpkg.patch from TrimUI's stock boot package.

Usage: tools/gen-patches.py TG3040 path/to/boot_package.fex
       tools/gen-patches.py TG4040 path/to/boot_package.fex

The boot package (U-Boot, its device tree and firmware) is the same on every
unit of a model running the same TrimUI firmware, so its edits, including the
recomputed checksums, are constants. The device applies them to a copy of its
backup boot package and checks the result against the hash written here.
Offsets and values come from BaseOS's brick lab tool (brick/dev/lab.py).
"""
import hashlib
import os
import struct
import sys

STAMP = 0x5F0A6C39
UBOOT_BASE = 0x4A000000
STOCK_SHA = {
    "TG3040": "9e3ae29b54a8c87f73b8168764cc24a3f77a9aa7a8873721c3122937aaad5a31",  # Brick, Brick Hammer v1.1.1
    "TG4040": "7e537bca7e5141d4536561d1041b869330f6d26f89d4c8c96ba26079c19c1aa2",  # Brick Pro v1.1.1
}
# Run address in U-Boot, stock bytes, new bytes, what it does.
UBOOT_PATCHES = {
    "TG3040": [
        (0x4A0268D2, b"\x78\x20", b"\x0a\x20", "panel reset pulse 120 -> 10 ms"),
        (0x4A09F0F4, b"\x32", b"\x0a", "jd9168 panel: wait after display-on 50 -> 10 ms"),
        (0x4A00F772, b"\x01\xd2", b"\x00\xbf", "U-Boot prints no messages"),
    ],
    "TG4040": [
        (0x4A0268FE, b"\x78\x20", b"\x0a\x20", "panel reset pulse 120 -> 10 ms"),
        (0x4A0A207C, b"\x32", b"\x0a", "jd9168 panel: wait after display-on 50 -> 10 ms"),
        (0x4A0A177C, b"\xfa", b"\x0a", "gh7003 panel: wait after display-on 250 -> 10 ms"),
        (0x4A00F772, b"\x01\xd2", b"\x00\xbf", "U-Boot prints no messages"),
    ],
}
# Device-tree u32 properties: node path suffix, stock value, new value, what.
FDT_FIELDS = {
    "burn_key": ("/target", 1, 0, "no wait for a PC flashing tool"),
    "debug_mode": ("/platform", 8, 0, "U-Boot serial output off"),
}


def checksum(data, field, length):
    t = bytearray(data[:length])
    struct.pack_into("<I", t, field, STAMP)
    return sum(struct.unpack_from(f"<{length // 4}I", t)) & 0xFFFFFFFF


def fdt_fields(p):
    """Offsets of the FDT_FIELDS values inside the package's device tree."""
    i = 0
    while (base := p.find(b"\xd0\x0d\xfe\xed", i)) >= 0:
        i = base + 4
        total, off_struct, off_strings = struct.unpack_from(">III", p, base + 4)
        if not (0 < total <= len(p) - base and off_struct < total and off_strings < total):
            continue
        strings, pos, path, hits = base + off_strings, base + off_struct, [], {}
        try:
            while (tok := struct.unpack_from(">I", p, pos)[0]) != 9:
                pos += 4
                if tok == 1:
                    end = p.index(b"\0", pos)
                    path.append(p[pos:end].decode())
                    pos = (end + 4) & ~3
                elif tok == 2:
                    path.pop()
                elif tok == 3:
                    ln, no = struct.unpack_from(">II", p, pos)
                    pos += 8
                    name = p[strings + no:p.index(b"\0", strings + no)].decode()
                    if name in FDT_FIELDS and ln == 4 and "/".join(path).endswith(FDT_FIELDS[name][0]):
                        hits[name] = pos
                    pos = (pos + ln + 3) & ~3
                elif tok != 4:
                    raise ValueError
        except (ValueError, IndexError, struct.error, UnicodeDecodeError):
            continue
        if len(hits) == len(FDT_FIELDS):
            return hits
    sys.exit("burn_key and debug_mode not found in the device tree")


def uboot_item(p):
    for i in range(struct.unpack_from("<I", p, 0x20)[0]):
        e = 0x40 + i * 0x170
        if p[e:e + 0x40].split(b"\0")[0] == b"u-boot":
            off, _ = struct.unpack_from("<II", p, e + 0x40)
            assert p[off + 4:off + 9] == b"uboot", "U-Boot item has no uboot header"
            return off
    sys.exit("no u-boot item in the boot package")


def main(model, path):
    stock = open(path, "rb").read()
    if hashlib.sha256(stock).hexdigest() != STOCK_SHA[model]:
        sys.exit(f"{path} is not TrimUI's v1.1.1 boot package for {model}")
    out = bytearray(stock)
    notes = {}
    off = uboot_item(stock)
    ulen = struct.unpack_from("<I", out, off + 0x14)[0]
    for addr, old, new, what in UBOOT_PATCHES[model]:
        o = off + addr - UBOOT_BASE
        assert out[o:o + len(old)] == old, f"unexpected stock bytes at {addr:#x}"
        out[o:o + len(new)] = new
        notes[o] = (len(new), what)
    struct.pack_into("<I", out, off + 12, checksum(out[off:off + ulen], 12, ulen))
    notes[off + 12] = (4, "U-Boot checksum")
    for name, o in fdt_fields(stock).items():
        _, old, new, what = FDT_FIELDS[name]
        assert struct.unpack_from(">I", out, o)[0] == old, f"{name} is not {old}"
        struct.pack_into(">I", out, o, new)
        notes[o] = (4, f"{name} {old} -> {new}: {what}")
    plen = struct.unpack_from("<I", out, 36)[0]
    struct.pack_into("<I", out, 20, checksum(out, 20, plen))
    notes[20] = (4, "boot package checksum")
    assert checksum(out, 20, plen) == struct.unpack_from("<I", out, 20)[0]

    # One line per edited field: its offset and all of its new bytes.
    lines = [f"{start} {''.join(chr(92) + format(b, '03o') for b in out[start:start + width])} {what}"
             for start, (width, what) in sorted(notes.items())]
    every = {i for i in range(len(stock)) if out[i] != stock[i]}
    covered = {i for start, (width, _) in notes.items() for i in range(start, start + width)}
    assert every <= covered, "a changed byte is missing from the table"

    size = (plen + 511) // 512 * 512
    assert len(stock) == size, "package file is not exactly its valid length in sectors"
    dest = os.path.join(os.path.dirname(__file__), "..", "data", model, "bootpkg.patch")
    with open(dest, "w") as f:
        f.write(f"# Boot package edits for {model}, TrimUI firmware v1.1.1. Made by tools/gen-patches.py.\n")
        f.write(f"# Each line: byte offset, new bytes (octal escapes), what it does.\n")
        f.write(f"sectors {size // 512}\n")
        f.write(f"stock {STOCK_SHA[model]}\n")
        f.write(f"tweaked {hashlib.sha256(out).hexdigest()}\n")
        f.write("".join(f"{ln}\n" for ln in lines))
    print(f"{dest}: {len(lines)} edits, {len(every)} bytes")


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in STOCK_SHA:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
