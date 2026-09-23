#!/bin/bash
# ios_tweak/build.sh — build v2: QobuzLogger.m (ObjC) + QobuzLoggerSK2.swift en un solo dylib
# Uso: bash ios_tweak/build.sh [out/QobuzLogger.dylib]
# Si swiftc falla, fallback automático a dylib solo-ObjC (red+receipt+polling, sin SK2).
set -euo pipefail
OUT="${1:-out/QobuzLogger.dylib}"
mkdir -p "$(dirname "$OUT")"
ARCH=arm64
MIN=16.4
SDK=$(xcrun -sdk iphoneos --show-sdk-path)
echo "[+] SDK: $SDK"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "[+] clang QobuzLogger.m"
xcrun -sdk iphoneos clang -arch "$ARCH" -mios-version-min="$MIN" -O2 -fobjc-arc -fvisibility=hidden \
  -c ios_tweak/QobuzLogger.m -o "$TMP/QZ.o"

HAVE_SK2=0
echo "[+] swiftc QobuzLoggerSK2.swift"
if xcrun -sdk iphoneos swiftc -arch "$ARCH" -mios-version-min="$MIN" -O \
    -import-objc-header ios_tweak/QZBridge.h \
    -emit-object ios_tweak/QobuzLoggerSK2.swift -o "$TMP/QZSK2.o"; then
  HAVE_SK2=1
  echo "[+] Swift OK"
else
  echo "[!] swiftc failed — ObjC-only fallback"
fi

echo "[+] link"
if [ "$HAVE_SK2" = 1 ]; then
  xcrun -sdk iphoneos clang -arch "$ARCH" -mios-version-min="$MIN" -dynamiclib \
    "$TMP/QZ.o" "$TMP/QZSK2.o" \
    -framework Foundation -framework StoreKit \
    -L"$SDK/usr/lib/swift" -lswiftCore -lswiftFoundation -lswiftDarwin -lswift_Concurrency \
    -o "$OUT"
else
  xcrun -sdk iphoneos clang -arch "$ARCH" -mios-version-min="$MIN" -O2 -dynamiclib \
    "$TMP/QZ.o" -framework Foundation -framework StoreKit -o "$OUT"
fi

echo "[+] verify"
file "$OUT" || true
lipo -info "$OUT" || true
otool -L "$OUT" || true
if [ "$HAVE_SK2" = 1 ]; then
  nm -gU "$OUT" | grep -q _QZSK2Start && echo "[+] QZSK2Start present" || echo "[!] QZSK2Start MISSING (SK2 disabled at runtime via dlsym guard)"
fi
codesign -s - -f "$OUT" || true
ls -lh "$OUT"
