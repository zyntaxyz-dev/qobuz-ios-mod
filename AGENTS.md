# AGENTS.md — qobuz-ios-mod

## Environment (non-obvious, verify before assuming otherwise)
- Dev machine is **Windows + PowerShell 5.1**. No `&&`, no `head`/`cat`; chain with `; if ($?) { ... }`. Paths contain spaces (`Developing Lab`) — always quote.
- Python is `python` (3.14, `C:\Python314`), not `python3`. `lief`, `capstone`, `smda` already installed. Prefer stdlib first; escalate to those only with a concrete reason.
- No test suite, linter, or package manager. Only verification available: `python -m py_compile tools/*.py` and YAML parse of the workflow.
- iOS target is **jailed, no jailbreak** (ESign sideload, Filza on iOS 26). Never introduce Substrate/Substitute/ElleKit, `/var/jb`, SSH, or `frida-server` assumptions.

## What is NOT in git (do not recreate or commit it)
- `originals/` (decrypted Qobuz IPA, 40MB+, copyrighted) is gitignored. Fresh clones lack it — scripts must fail with a clear message when the binary is absent, not with a traceback.
- Also ignored: `*.ipa`, `*.dylib`, `*.sha256`, `out/strings.json`, `*.log`, `logs/`. Committable evidence lives in `out/STATIC_MAP_v1.md`, `out/POC_sandbox.md`, `out/macho.json`.

## Build flow (the one thing agents get wrong)
- The dylib **cannot compile on Windows**. Only: push → GitHub Actions `build-dylib` (macos runner) → download `QobuzLogger-dylib` artifact; or on a Mac: `bash ios_tweak/build.sh out/QobuzLogger.dylib`.
- CI is path-filtered: pushes touching only `tools/` or `out/` do **not** trigger a build. Use `workflow_dispatch` or touch `ios_tweak/**` for a rebuild.
- CI rejects jailbreak deps (`otool -L | grep substrate/substitute/ellekit`). Keep `QobuzLogger.m` to Foundation + StoreKit + ObjC runtime only.
- Dylib injection on Windows: `python tools/inject_dylib.py --app <Qobuz.app> --dylib <QobuzLogger.dylib> --out <injected.ipa>` (LIEF if present, else ESign's Inject Dylib UI). Then sign with ESign; read `Documents/qobuz_hook.log` via Filza.

## RE method (repo convention)
- Static-first, evidence-driven: `tools/macho_quick.py` → `tools/strings_harvest.py` → targeted Capstone only around hits. No broad hooks, no blind patching.
- Label every finding: Confirmed / Strongly supported / Hypothesis / Unknown. Never present inference as fact.
- Preserve reversibility: keep original IPA hash (`out/Qobuz.sha256` pattern), one minimal experiment at a time (see `out/POC_sandbox.md` E1→E2→E3 order).
