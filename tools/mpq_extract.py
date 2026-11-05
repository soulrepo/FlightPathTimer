#!/usr/bin/env python3
"""Minimal MPQ (v1) reader, stdlib only. Extracts named files from the highest-priority archive.

usage: mpq_extract.py <wow Data dir> <out dir> <file name>...
"""
import bz2
import os
import struct
import sys
import zlib

def _crypt_table():
    table = [0] * 0x500
    seed = 0x00100001
    for i in range(0x100):
        idx = i
        for _ in range(5):
            seed = (seed * 125 + 3) % 0x2AAAAB
            t1 = (seed & 0xFFFF) << 16
            seed = (seed * 125 + 3) % 0x2AAAAB
            t2 = seed & 0xFFFF
            table[idx] = t1 | t2
            idx += 0x100
    return table

CT = _crypt_table()

def hash_str(s, kind):
    s1, s2 = 0x7FED7FED, 0xEEEEEEEE
    for ch in s.upper().replace("/", "\\"):
        c = ord(ch)
        s1 = (CT[(kind << 8) + c] ^ (s1 + s2)) & 0xFFFFFFFF
        s2 = (c + s1 + s2 + (s2 << 5) + 3) & 0xFFFFFFFF
    return s1

def decrypt(data, key):
    out = bytearray()
    seed = 0xEEEEEEEE
    n = len(data) // 4
    vals = struct.unpack("<%dI" % n, data[: n * 4])
    for v in vals:
        seed = (seed + CT[0x400 + (key & 0xFF)]) & 0xFFFFFFFF
        d = (v ^ (key + seed)) & 0xFFFFFFFF
        key = ((((~key) << 0x15) + 0x11111111) | (key >> 0x0B)) & 0xFFFFFFFF
        seed = (d + seed + (seed << 5) + 3) & 0xFFFFFFFF
        out += struct.pack("<I", d)
    return bytes(out) + data[n * 4:]

# ---- PKWARE DCL "explode" (used by MPQ_FILE_IMPLODE and compression type 0x08) ----
_LEN_BITS = [3, 2, 3, 3, 4, 4, 4, 5, 5, 5, 5, 6, 6, 6, 7, 7]
_LEN_CODE = [0x05, 0x03, 0x01, 0x06, 0x0A, 0x02, 0x0C, 0x14, 0x04, 0x18, 0x08, 0x30, 0x10, 0x20, 0x40, 0x00]
_EX_LEN_BITS = [0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8]
_LEN_BASE = [0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 14, 22, 38, 70, 134, 262]
_DIST_BITS = [2, 4, 4, 5, 5, 5, 5, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
              7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8]
_DIST_CODE = [0x03, 0x0D, 0x05, 0x19, 0x09, 0x11, 0x01, 0x3E, 0x1E, 0x2E, 0x0E, 0x36, 0x16, 0x26, 0x06, 0x3A,
              0x1A, 0x2A, 0x0A, 0x32, 0x12, 0x22, 0x42, 0x02, 0x7C, 0x3C, 0x5C, 0x1C, 0x6C, 0x2C, 0x4C, 0x0C,
              0x74, 0x34, 0x54, 0x14, 0x64, 0x24, 0x44, 0x04, 0x78, 0x38, 0x58, 0x18, 0x68, 0x28, 0x48, 0x08,
              0xF0, 0x70, 0xB0, 0x30, 0xD0, 0x50, 0x90, 0x10, 0xE0, 0x60, 0xA0, 0x20, 0xC0, 0x40, 0x80, 0x00]

def _build_decode(bits, codes):
    table = {}
    for i, (b, c) in enumerate(zip(bits, codes)):
        table[(b, c)] = i
    return table

_LEN_DEC = _build_decode(_LEN_BITS, _LEN_CODE)
_DIST_DEC = _build_decode(_DIST_BITS, _DIST_CODE)

class _Bits:
    def __init__(self, data, pos):
        self.data, self.pos, self.buf, self.n = data, pos, 0, 0
    def get(self, k):
        while self.n < k:
            if self.pos >= len(self.data):
                raise EOFError
            self.buf |= self.data[self.pos] << self.n
            self.pos += 1
            self.n += 8
        v = self.buf & ((1 << k) - 1)
        self.buf >>= k
        self.n -= k
        return v
    def decode(self, table, maxbits):
        code = 0
        for nb in range(1, maxbits + 1):
            code |= self.get(1) << (nb - 1)
            if (nb, code) in table:
                return table[(nb, code)]
        raise ValueError("bad code")

def explode(data):
    ctype, dict_bits = data[0], data[1]
    if ctype != 0:
        raise ValueError("ASCII-mode implode not supported")
    br = _Bits(data, 2)
    out = bytearray()
    try:
        while True:
            if br.get(1):
                li = br.decode(_LEN_DEC, 7)
                length = _LEN_BASE[li] + (br.get(_EX_LEN_BITS[li]) if _EX_LEN_BITS[li] else 0) + 2
                if length == 519:
                    break
                di = br.decode(_DIST_DEC, 8)
                if length == 2:
                    dist = (di << 2) | br.get(2)
                else:
                    dist = (di << dict_bits) | br.get(dict_bits)
                start = len(out) - dist - 1
                for i in range(length):
                    out.append(out[start + i])
            else:
                out.append(br.get(8))
    except EOFError:
        pass
    return bytes(out)

def decompress_sector(data):
    mask = data[0]
    body = data[1:]
    if mask == 0x02:
        return zlib.decompress(body)
    if mask == 0x10:
        return bz2.decompress(body)
    if mask == 0x08:
        return explode(body)
    raise ValueError("unsupported compression 0x%02x" % mask)

class MPQ:
    def __init__(self, path):
        self.f = open(path, "rb")
        self.base = self._find_header()
        f = self.f
        f.seek(self.base)
        hdr = f.read(32)
        _, hsize, _, ver, sshift, htpos, btpos, htn, btn = struct.unpack("<4sIIHHIIII", hdr)
        self.sector = 512 << sshift
        f.seek(self.base + htpos)
        self.hashes = struct.unpack("<%dI" % (htn * 4), decrypt(f.read(htn * 16), hash_str("(hash table)", 3)))
        f.seek(self.base + btpos)
        self.blocks = struct.unpack("<%dI" % (btn * 4), decrypt(f.read(btn * 16), hash_str("(block table)", 3)))
        self.htn = htn

    def _find_header(self):
        off = 0
        size = os.fstat(self.f.fileno()).st_size
        while off < size:
            self.f.seek(off)
            if self.f.read(4) == b"MPQ\x1a":
                return off
            off += 512
        raise ValueError("no MPQ header")

    def find(self, name):
        a, b, start = hash_str(name, 1), hash_str(name, 2), hash_str(name, 0) % self.htn
        i = start
        while True:
            ha, hb, _loc, block = self.hashes[i * 4: i * 4 + 4]
            if block == 0xFFFFFFFF:
                return None
            if ha == a and hb == b and block != 0xFFFFFFFE:
                return block
            i = (i + 1) % self.htn
            if i == start:
                return None

    def read(self, name):
        bi = self.find(name)
        if bi is None:
            return None
        pos, csize, fsize, flags = self.blocks[bi * 4: bi * 4 + 4]
        if not flags & 0x80000000:
            return None
        if flags & 0x00010000:
            raise ValueError("encrypted file not supported: " + name)
        self.f.seek(self.base + pos)
        raw = self.f.read(csize)
        if not flags & 0x00000300:  # stored
            return raw[:fsize]
        if flags & 0x01000000:  # single unit
            if csize == fsize:
                return raw
            return decompress_sector(raw) if flags & 0x200 else explode(raw)
        n = (fsize + self.sector - 1) // self.sector
        offs = struct.unpack("<%dI" % (n + 1), raw[: (n + 1) * 4])
        out = bytearray()
        for s in range(n):
            chunk = raw[offs[s]: offs[s + 1]]
            want = min(self.sector, fsize - s * self.sector)
            if len(chunk) == want:
                out += chunk
            elif flags & 0x200:
                out += decompress_sector(chunk)
            else:
                out += explode(chunk)
        return bytes(out[:fsize])

def archive_priority(data_dir):
    """Highest priority first: patch-Z..patch-2, patch, then base archives."""
    names = os.listdir(data_dir)
    patches = sorted([n for n in names if n.lower().startswith("patch") and n.lower().endswith(".mpq")],
                     key=lambda n: n.lower().replace(".mpq", ""), reverse=True)
    rest = [n for n in names if n.lower().endswith(".mpq") and n not in patches]
    return patches + sorted(rest)

def main():
    data_dir, out_dir, wanted = sys.argv[1], sys.argv[2], sys.argv[3:]
    os.makedirs(out_dir, exist_ok=True)
    order = archive_priority(data_dir)
    print("archive order:", order)
    for name in wanted:
        for arc in order:
            try:
                m = MPQ(os.path.join(data_dir, arc))
                data = m.read(name)
            except Exception as e:
                print("  %s in %s: error %s" % (name, arc, e))
                continue
            if data is not None:
                dest = os.path.join(out_dir, name.split("\\")[-1])
                with open(dest, "wb") as fh:
                    fh.write(data)
                print("%s <- %s (%d bytes)" % (name, arc, len(data)))
                break
        else:
            print("%s: not found" % name)

if __name__ == "__main__":
    main()
