#!/usr/bin/env python3
"""macho_quick.py - Level 0 stdlib Mach-O parser for Qobuz iOS.
Reads thin Mach-O 64 LE, lists load commands, segments, dylibs, encryption.
Usage: python tools/macho_quick.py <path-to-binary> [--json out.json]
"""
import struct, sys, json, pathlib

LC_SEGMENT_64 = 0x19
LC_LOAD_DYLIB = 0xC
LC_ID_DYLIB = 0xD
LC_LOAD_WEAK_DYLIB = 0x18
LC_REEXPORT_DYLIB = 0x1F
LC_LAZY_LOAD_DYLIB = 0x20
LC_LOAD_UPWARD_DYLIB = 0x23
LC_ENCRYPTION_INFO = 0x21
LC_ENCRYPTION_INFO_64 = 0x2C
LC_CODE_SIGNATURE = 0x1D
LC_MAIN = 0x80000028
LC_UUID = 0x1B
LC_VERSION_MIN_IPHONEOS = 0x24
LC_BUILD_VERSION = 0x32
LC_SOURCE_VERSION = 0x2A

LC_NAMES = {
 0x1:"LC_SEGMENT",0x19:"LC_SEGMENT_64",0xC:"LC_LOAD_DYLIB",0xD:"LC_ID_DYLIB",
 0x18:"LC_LOAD_WEAK_DYLIB",0x1F:"LC_REEXPORT_DYLIB",0x20:"LC_LAZY_LOAD_DYLIB",
 0x21:"LC_ENCRYPTION_INFO",0x2C:"LC_ENCRYPTION_INFO_64",0x1D:"LC_CODE_SIGNATURE",
 0x80000028:"LC_MAIN",0x1B:"LC_UUID",0x24:"LC_VERSION_MIN_IPHONEOS",0x32:"LC_BUILD_VERSION",
 0x2A:"LC_SOURCE_VERSION",0xB:"LC_SYMTAB",0x2:"LC_SYMSEG",0xE:"LC_LOAD_DYLINKER",
 0x80000022:"LC_DYLD_INFO_ONLY",0x22:"LC_DYLD_INFO",0x26:"LC_FUNCTION_STARTS",
 0x29:"LC_DATA_IN_CODE",0x27:"LC_DYLIB_CODE_SIGN_DRS",0x1E:"LC_SEGMENT_SPLIT_INFO",
 0x30:"LC_DYLD_EXPORTS_TRIE",0x33:"LC_DYLD_CHAINED_FIXUPS",0x34:"LC_FILESET_ENTRY",
}

def cstr(data, off):
    end = data.index(b'\x00', off)
    return data[off:end].decode('utf-8', errors='replace')

def parse(path):
    data = pathlib.Path(path).read_bytes()
    if len(data) < 32:
        raise ValueError("file too small")
    magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from('<8I', data, 0)
    assert magic == 0xfeedfacf, f"not thin arm64 LE Mach-O, magic={hex(magic)}"
    res = {"path": str(path), "size": len(data), "magic": hex(magic),
           "cputype": cputype, "cpusubtype": cpusubtype, "filetype": filetype,
           "ncmds": ncmds, "flags": hex(flags)}
    off = 32
    dylibs, segments, enc = [], [], None
    uuid = None
    for i in range(ncmds):
        if off + 8 > len(data): break
        cmd, cmdsize = struct.unpack_from('<2I', data, off)
        name = LC_NAMES.get(cmd, hex(cmd))
        if cmd == LC_SEGMENT_64:
            segname = data[off+8:off+24].split(b'\x00')[0].decode(errors='replace')
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<4Q', data, off+24)
            maxprot, initprot, nsects, segflags = struct.unpack_from('<4I', data, off+56)
            segments.append({"segname": segname, "vmsize": vmsize, "filesize": filesize, "nsects": nsects})
        elif cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LAZY_LOAD_DYLIB, LC_LOAD_UPWARD_DYLIB):
            str_off = off + struct.unpack_from('<I', data, off+8)[0]
            try: dylibs.append({"type": name, "name": cstr(data, str_off)})
            except: dylibs.append({"type": name, "name": "<parse-error>"})
        elif cmd in (LC_ENCRYPTION_INFO, LC_ENCRYPTION_INFO_64):
            cryptoff, cryptsize, cryptid = struct.unpack_from('<3I', data, off+8)
            enc = {"cmd": name, "cryptoff": cryptoff, "cryptsize": cryptsize, "cryptid": cryptid,
                   "decrypted": cryptid == 0}
        elif cmd == LC_UUID:
            uuid = data[off+8:off+24].hex()
        off += cmdsize
    res["segments"] = segments
    res["dylibs"] = dylibs
    res["encryption"] = enc
    res["uuid"] = uuid
    # heuristic: __TEXT filesize vs vmsize
    return res

if __name__ == "__main__":
    p = sys.argv[1]
    r = parse(p)
    print(json.dumps(r, indent=2))
    if "--json" in sys.argv:
        out = sys.argv[sys.argv.index("--json")+1]
        pathlib.Path(out).write_text(json.dumps(r, indent=2))
        print(f"[+] wrote {out}", file=sys.stderr)
