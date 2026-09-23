#!/bin/bash
# ios_tweak/build.sh — compilación local macOS / reutilizado por GitHub Actions
# Uso: bash ios_tweak/build.sh [--out QobuzLogger.dylib]
set -euo pipefail
OUT="${1:-QobuzLogger.dylib}"
SRC="$(dirname "$0")/QobuzLogger.m"
SDK=$(xcrun -sdk iphoneos --show-sdk-path)
echo "[+] SDK: $SDK"
echo "[+] xcode: $(xcode-select -p)"
xcrun -sdk iphoneos clang -arch arm64 \
  -mios-version-min=16.4 \
  -O2 -fobjc-arc -fvisibility=hidden \
  -dynamiclib \
  -framework Foundation -framework StoreKit \
  -o "$OUT" "$SRC"
echo "[+] built $OUT"
file "$OUT" || true
lipo -info "$OUT" || true
otool -L "$OUT" || true
codesign -s - -f "$OUT" || true
codesign -dv "$OUT" || true
ls -lh "$OUT"
