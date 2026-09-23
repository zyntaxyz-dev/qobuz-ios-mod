#!/usr/bin/env python3
"""funcmap.py — disassemble one function fully: BL targets + string refs.
Usage: python tools/funcmap.py <binary> <code_va_hex>
Resolves function bounds via smda, disassembles with capstone,
annotates BL (local vs stub) and ADRP-string refs.
"""
import sys, struct, re, pathlib

def main():
    path, va = sys.argv[1], int(sys.argv[2], 16)
    import lief
    from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN
    b = lief.parse(path)
    data = pathlib.Path(path).read_bytes()
    t = b.get_section("__text")
    tva, toff, tsize = t.virtual_address, t.offset, t.size
    segs = {s.name: (s.virtual_address, s.file_offset) for s in b.segments}
    tva0, tfo0 = segs["__TEXT"]

    def va2str(v):
        for name, (sva, sfo) in segs.items():
            pass
        # assume __TEXT cstring zone
        fo = tfo0 + (v - tva0)
        if 0 <= fo < len(data):
            return data[fo:fo + 80].split(b"\x00")[0].decode(errors="replace")
        return "?"

    # stub -> imported symbol map via LIEF
    stubs = {}
    try:
        for imp in b.imported_functions:
            stubs[imp.address] = imp.name
    except Exception as e:
        print("[i] no import map:", e)

    from smda.Disassembler import Disassembler
    da = Disassembler()
    # analyze window around va
    start = max(toff, toff + (va - tva) - 0x3000)
    buf = data[start:start + 0x8000]
    base = tva + (start - toff)
    try:
        res = da.disassembleBuffer(buf, base)
        fns = list(res.getFunctions())
        print("[+] smda functions in window:", len(fns))
    except Exception as e:
        print("[!] smda fail:", e)
        return
    # find function containing va
    target = None
    for f in fns:
        try:
            addrs = sorted(f.getInstructions().keys())
        except Exception:
            continue
        if not addrs:
            continue
        lo, hi = addrs[0], addrs[-1]
        if lo <= va <= hi + 0x100:
            target = (f, lo, hi)
            break
    if not target:
        print("[-] no smda function contains", hex(va))
        return
    f, lo, hi = target
    print("[+] func %s range %s-%s size %d" % (hex(f.address), hex(lo), hex(hi), hi - lo))
    md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
    md.detail = True
    fbytes = data[tfo0 + (lo - tva0):tfo0 + (hi - tva0) + 8]
    for ins in md.disasm(fbytes, lo):
        extra = ""
        if ins.mnemonic == "bl" and ins.operands:
            try:
                dst = ins.operands[0].imm
                if dst in stubs:
                    extra = " => STUB " + stubs[dst]
                else:
                    extra = " => local %s" % hex(dst & 0xFFFFFFFFFFFFFFFF)
            except Exception:
                pass
        elif ins.mnemonic == "adrp":
            extra = " => page %s" % ins.op_str.split(",")[-1].strip()
        print("    %s  %-8s %-28s %s" % (hex(ins.address), ins.mnemonic, ins.op_str, extra))

if __name__ == "__main__":
    main()
