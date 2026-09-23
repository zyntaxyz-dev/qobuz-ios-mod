# qobuz-ios-mod

Investigación jailed (sin jailbreak) Qobuz iOS 10.1.0 — mapa estático + tweak instrumental + PoC sandbox. Windows + Python + ESign + GitHub Actions (macOS runner para compilar).

## Estructura
- `tools/macho_quick.py` — parser Mach-O stdlib
- `tools/strings_harvest.py` — cosecha strings StoreKit/subs/red
- `tools/inject_dylib.py` — prepara IPA para ESign (LIEF o manual)
- `ios_tweak/QobuzLogger.m` — dylib jailed, log a `Documents/qobuz_hook.log` (Filza)
- `ios_tweak/build.sh` — build macOS local
- `.github/workflows/build-dylib.yml` — build arm64 en CI
- `out/STATIC_MAP_v1.md` — mapa StoreKit híbrido + endpoints `/appStore/*`
- `out/POC_sandbox.md` — experimentos receipt-freeze / replay / flag-pin

## Build dylib (desde Windows)
1. Push a GitHub → Actions `build-dylib` → descargar artifact `QobuzLogger-dylib`.
2. Copiar a `ios_tweak/QobuzLogger.dylib`.
3. `python tools/inject_dylib.py --app originals/Qobuz_v10.1.0/Payload/Qobuz.app --dylib ios_tweak/QobuzLogger.dylib --out out/Qobuz_injected.ipa`
4. Firmar con ESign, instalar, reproducir trial → Hi-Res, leer log con Filza.

## Nota
`originals/` (IPA desencriptada) NO se sube por copyright/peso. Cada investigador usa su propia copia + `out/Qobuz.sha256` local.
