#!/usr/bin/env python3
"""inject_dylib.py — prepara IPA jailed para ESign (Windows + Python puro + LIEF opcional).
1. Copia ios_tweak/QobuzLogger.dylib -> Payload/Qobuz.app/Frameworks/
2. Si LIEF disponible, añade LC_LOAD_DYLIB @executable_path/Frameworks/QobuzLogger.dylib
   Si no, imprime pasos manuales ESign (ESign tiene 'Inject Dylib' integrado).
3. Reempaqueta IPA lista para firmar.
Uso: python tools/inject_dylib.py --app originals/Qobuz_v10.1.0/Payload/Qobuz.app --dylib ios_tweak/QobuzLogger.dylib --out out/Qobuz_injected.ipa
"""
import argparse, pathlib, shutil, zipfile, sys

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True)
    ap.add_argument("--dylib", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    app = pathlib.Path(a.app); dylib = pathlib.Path(a.dylib); out = pathlib.Path(a.out)
    assert app.exists(), f"no app {app}"
    assert dylib.exists(), f"no dylib {dylib} — compílala primero en Mac (ver ios_tweak/BUILD.md)"
    fw = app / "Frameworks"
    fw.mkdir(exist_ok=True)
    shutil.copy2(dylib, fw / dylib.name)
    print(f"[+] copied {dylib.name} -> {fw}")
    # Intentar LIEF
    try:
        import lief
        binpath = app / "Qobuz"
        binary = lief.parse(str(binpath))
        lc = f"@executable_path/Frameworks/{dylib.name}"
        if any(d.name == lc for d in binary.libraries):
            print(f"[*] already has {lc}")
        else:
            binary.add_library(lc)
            binary.write(str(binpath))
            print(f"[+] LIEF injected {lc}")
    except ImportError:
        print("[!] lief no instalado: usa ESign -> Import IPA -> Inject Dylib -> selecciona QobuzLogger.dylib")
        print("    ESign hace el LC_LOAD_DYLIB por ti, no necesitas parche manual.")
    except Exception as e:
        print(f"[!] LIEF inject falló: {e}")
        print("    Fallback: usa ESign Inject Dylib manual.")
    # Reempaquetar: buscar Payload root
    # app = .../Payload/Qobuz.app -> payload_dir = .../Payload
    payload_dir = app.parent
    assert payload_dir.name == "Payload"
    out.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for f in payload_dir.rglob("*"):
            if f.is_file():
                arc = f.relative_to(payload_dir.parent)
                z.write(f, arc)
    print(f"[+] wrote {out} ({out.stat().st_size/1e6:.1f} MB) — firma con ESign + instala jailed")

if __name__ == "__main__":
    main()
