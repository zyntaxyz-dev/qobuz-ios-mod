# BUILD — QobuzLogger.dylib (jailed, ESign)

## Compilación desde Windows vía GitHub Actions (recomendado)
1. `git add ios_tweak/QobuzLogger.m .github/workflows/build-dylib.yml ios_tweak/build.sh && git commit && git push`.
2. GitHub -> Actions -> `build-dylib` -> Run o auto por push -> descarga artifact `QobuzLogger-dylib`.
3. Copia `QobuzLogger.dylib` a `ios_tweak/QobuzLogger.dylib` en Windows.
4. Sigue a Inyección A/B abajo.

## Compilación local en Mac (alternativa)
```bash
bash ios_tweak/build.sh out/QobuzLogger.dylib
```

## Inyección (2 opciones)

### A) Automática (LIEF, Windows)
```bash
python tools/inject_dylib.py --app originals/Qobuz_v10.1.0/Payload/Qobuz.app --dylib ios_tweak/QobuzLogger.dylib --out out/Qobuz_injected.ipa
```
Luego ESign -> Sign -> Install.

### B) Manual ESign (recomendada si LIEF falla)
1. ESign -> Files -> Import `original` IPA (reempaqueta desde `originals/Qobuz_v10.1.0/Payload` si hace falta).
2. ESign -> ... -> Inject Dylib -> selecciona `QobuzLogger.dylib`.
3. Sign + Install.
4. Abre Qobuz, reproduce paywall -> trial -> Hi-Res track.
5. Filza -> `Containers/Data/Application/<Qobuz UUID>/Documents/qobuz_hook.log`.
6. Exporta también `Library/Preferences/com.qobuz.music.plist`.

## v1 es pasiva a propósito
- No hace exchange agresivo de NSURLSession para no crashear en iOS 26.
- Solo observa SK1 + snapshot NSUserDefaults + receiptURL + clases.
- v2 (tras tus logs) añadirá swizzle NSURLSession completo + hook `verifyTransaction/validateAndComplete` por dirección (capstone) si hace falta flag-pin.

## Protocolo de prueba
1. Instalación limpia, abre app, tapa `Start your 30-day free trial`.
2. Reproduce track Hi-Res conocido (ej Joji PIXELATED KISSES), deja 2 min.
3. Kill + relaunch, verifica si sigue Hi-Res o cae a preview 30s.
4. Copia `qobuz_hook.log` + hora exacta de cada paso.
