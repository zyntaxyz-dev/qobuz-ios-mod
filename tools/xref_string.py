#!/usr/bin/env python3
"""xref_string.py — targeted static xref for Qobuz (stdlib + capstone + lief).
Given a substring, finds its vmaddr in __TEXT/__cstring and scans __text for
ADRP+ADD materializations referencing its page. Prints each hit with
surrounding disassembly and nearest function start (via smda if available).
Usage: python tools/xref_string.py <binary> <substring> [--ctx N]
"""
import re, struct, sys, pathlib

def get_text_info(path):
    import lief
    b = lief.parse(str(path))
    segs = {}
    for s in b.segments:
        segs[s.name] = (s.virtual_address, s.file_offset, s.virtual_size, s.file_size)
    text = b.get_section("__text")
    cstr = b.get_section("__cstring")
    tva, toff = text.virtual_address, text.offset
    try:
        tsize = text.file_size
    except AttributeError:
        tsize = text.size
    return b, segs, (tva, toff, tsize), cstr

def fo2va(fo, segs, sec_file_off, sec_va):
    return sec_va + (fo - sec_file_off)

def main():
    binary, needle = sys.argv[1], sys.argv[2].encode()
    ctx = int(sys.argv[sys.argv.index("--ctx") + 1]) if "--ctx" in sys.argv else 12
    import lief
    from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN
    b, segs, (tva, toff, tsize), cstr = get_text_info(binary)
    data = pathlib.Path(binary).read_bytes()
    tbytes = data[toff:toff + tsize]
    print(f"[+] __text va={hex(tva)} size={tsize}")
    # 1. find needle in __cstring (or whole binary as fallback)
    hits = [m.start() for m in re.finditer(re.escape(needle), data)]
    print(f"[+] {len(hits)} raw hits for {needle!r}")
    for fo in hits[:10]:
        # section?
        sec = "?"
        for name, (va, fo0, vsz, fsz) in segs.items():
            if fo0 <= fo < fo0 + fsz:
                sec = name
                va_hit = va + (fo - fo0)
                break
        print(f"    fo={fo} ({hex(fo)}) sec={sec} va={hex(va_hit) if sec!='?' else '?'}")
        s = data[fo:fo+120].split(b'\x00')[0].decode(errors='replace')
        print(f"    str: {s[:120]}")
    # 2. ADRP/ADD scan in __text for pages of cstring hits
    md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
    md.detail = True
    pages = set()
    for fo in hits:
        for name, (va, fo0, vsz, fsz) in segs.items():
            if fo0 <= fo < fo0 + fsz:
                pages.add((va + (fo - fo0)) & ~0xFFF)
    print(f"[+] {len(pages)} target pages")
    # decode all ADRP in __text
    from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN
    md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
    md.detail = True
    # Fast byte-pattern scan for ADRP: 32-bit word, bits[31]=1,[30:29]=00,[27:24]=1000x
    # page = (pc & ~0xFFF) + ((immhi:immlo) << 12), immhi=w[23:5], immlo=w[30:29]
    import struct
    nwords = len(tbytes) // 4
    words = struct.unpack_from("<%dI" % nwords, tbytes)
    exact = {}  # str_va -> [code va]
    for idx, w in enumerate(words):
        # ADRP = 1 00 10000 immlo immhi Rd  -> (w & 0x9F000000) == 0x90000000
        if (w & 0x9F000000) != 0x90000000:
            continue
        rd = w & 0x1F
        immlo = (w >> 29) & 3
        immhi = (w >> 5) & 0x7FFFF
        pc = tva + idx * 4
        page = (pc & ~0xFFF) + ((((immhi << 2) | immlo) << 12) & 0xFFFFFFFF)
        # sign-extend 21-bit imm+/- (imm is signed; handle negative via mask)
        raw = (immhi << 2) | immlo
        if raw & 0x100000:
            page = (pc & ~0xFFF) - ((0x200000 - raw) << 12)
        if (page & ~0xFFF) not in pages:
            continue
        # disassemble next 4 insns locally to resolve add/sub on same reg
        # (ventana EMPIEZA DESPUÉS del adrp: tbytes[idx*4+4:])
        local = tbytes[idx * 4 + 4:idx * 4 + 24]
        val = page
        ok = False
        try:
            for j in md.disasm(local, pc + 4):
                if j.mnemonic == "add" and len(j.operands) >= 3:
                    try:
                        if j.operands[0].reg == rd + 100 and False:
                            pass
                    except Exception:
                        pass
                    parts = j.op_str.split(",")
                    if len(parts) == 3 and parts[0].strip() == parts[1].strip().lower():
                        try:
                            val += int(parts[2].strip().lstrip("#"), 0)
                            ok = True
                        except ValueError:
                            pass
                elif j.mnemonic == "sub":
                    parts = j.op_str.split(",")
                    if len(parts) == 3 and parts[0].strip() == parts[1].strip().lower():
                        try:
                            val -= int(parts[2].strip().lstrip("#"), 0)
                        except ValueError:
                            pass
                elif j.mnemonic in ("adrp", "bl", "b", "cbz", "cbnz"):
                    break
        except Exception:
            pass
        if ok:
            exact.setdefault(val, []).append(pc)
    want = None
    for fo in hits:
        for name, (va, fo0, vsz, fsz) in segs.items():
            if fo0 <= fo < fo0 + fsz:
                want = va + (fo - fo0)
    print("[+] string va = %s" % (hex(want) if want else "?"))
    # dump all cstrings near want (same 4K page) for context
    if want:
        pg = want & ~0xFFF
        print(f"--- cstrings on page {hex(pg)} ---")
        # iterate raw: find printable runs in [pg_fo, pg_fo+0x1000]
        for name, (va, fo0, vsz, fsz) in segs.items():
            if va <= pg < va + vsz:
                base = fo0 + (pg - va)
                chunk = data[base:base + 0x1000]
                for m in re.finditer(rb'[\x20-\x7e]{10,}', chunk):
                    s = m.group().decode()
                    print(f"    {hex(pg + m.start())} : {s[:100]}")
                break
    if want and want in exact:
        print("[+] EXACT xrefs to target (%d):" % len(exact[want]))
        for a in exact[want][:10]:
            print("--- code %s ---" % hex(a))
            off = a - tva
            for j in md.disasm(tbytes[off - 8:off + ctx * 4], a - 8):
                print("    %s  %-8s %s" % (hex(j.address), j.mnemonic, j.op_str))
    else:
        print("[-] no exact ADRP+ADD xref to target string")
        # show which strings on the page DO have xrefs (top 10 by hits)
        cands = sorted(((k, len(v)) for k, v in exact.items() if (k & ~0xFFF) == (want & ~0xFFF)), key=lambda x: -x[1])[:10]
        print("[i] xrefs on same page:")
        tva0, tfo0 = segs["__TEXT"][0], segs["__TEXT"][1]
        for k, n in cands:
            s = data[tfo0 + (k - tva0):tfo0 + (k - tva0) + 70].split(b"\x00")[0].decode(errors="replace")
            addrs = " ".join(hex(a) for a in exact[k][:4])
            print("    %s x%d : %s" % (hex(k), n, s[:70]))
            print("        code: %s" % addrs)
    print("[+] done")

if __name__ == "__main__":
    main()
