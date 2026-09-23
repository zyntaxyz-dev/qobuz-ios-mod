# BUILD — QobuzLogger.dylib (jailed, ESign)

## v5 (actual): exportador de sesión E2 + cobertura total
- `EXPORT[init|change] n=… file=session_export_<tag>_<epoch>.json`: lee los VALORES del keychain propio (solo servicios `*qobuz*` y `auth`), base64 a `Documents/`. Al init (baseline) y cada vez que el keychain cambia (rotación por compra/login). El log jamás lleva valores, solo conteos.
- **Regla de manejo**: ese JSON equivale a la sesión. Respaldar fuera del dispositivo y borrarlo de `Documents` de inmediato. Ignorado en git (`session_export*.json`). V6 (restaurador) lo reinyectará post-expiración para el PoC E2.
- `tasksTotal=N` en el heartbeat: contador de TODAS las tasks creadas (vs `imgSkipped` filtradas). Si `tasksTotal` crece y no hay líneas `NET`, el tráfico va por una vía no hookeada (diagnóstico de cobertura, no suposición).

## v4 (actual): marcador de sheets
- `PRESENT <VC> from=<VC>`: hook a `UIViewController presentViewController:animated:completion:`. El botón Subscribe del paywall es SwiftUI (jamás toca `sendAction`), pero el paywall y el sheet de Apple sí se presentan como VCs — esta es la marca temporal del tap/flujo de compra. Heartbeat incluye `vc=`.
- Resto igual que v3 (red real, uploadTask, keychain probe, filtro de ruido, SK2 Swift, receipt watcher).

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

## v3: qué añade sobre v2 (tap exacto + keychain + sin ruido)
- `TAP action=… to=… sender=…`: hook a `UIApplication sendAction:to:from:forEvent:` que marca con timestamp cada tap Subscribe/purchase/trial + snapshot de receipt y defaults en ese instante. Si el tap no genera POST posterior, el grant es local (caza de flag).
- `uploadTask` hooks (`fromData` + `fromFile`): cubre stacks que suben JSON sin pasar por `dataTask`.
- Keychain probe: `SecItemCopyMatching` con `kSecReturnAttributes` (nunca valores) — detecta dónde vive la credencial por presencia/cambios, cuentas redactadas.
- Filtro de ruido: `static.qobuz.com/images`, `resizer/v2`, `cloudfront` se cuentan (`imgSkipped=N` en el heartbeat) en vez de loguear 150 líneas de portadas.
- Heartbeat extendido: `hooks(net=,up=,tap=)` + `imgSkipped` + keychain-diff.

## v2 (base que se mantiene)
- Red real con fallback: exchange `dataTaskWithRequest:completionHandler:` + `dataTaskWithRequest:` (+ log de creación). Filtra `appStore|offerEligibility|transactionSubscribed|reportStreaming|qobuz`, trunca a 2 KB, redacta `user_auth_token|hmac|jws`. Si el exchange falla → modo pasivo v1, nunca crashea.
- StoreKit 2 en Swift (`QobuzLoggerSK2.swift`): `Transaction.updates` + `currentEntitlements`. Símbolo opcional vía `dlsym` (build ObjC-only sigue funcional).
- Receipt watcher: copia `sandboxReceipt` → `Documents/receipt_<tag>_<epoch>.bin` al init, tras cada transacción SK1 y por timer si cambia el mtime. Log con tamaño + sha corto.
- Heartbeat 60s (`alive pendingSK1=… receipt=…`) verificable en vivo con Filza + snapshots de defaults con diff (solo loguea cambios).
- Proxy de `SKProductsRequest`: registra `productIdentifier`s al init y productos/precios en la respuesta, reenvía todo al delegate real.

## Protocolo de prueba (ventana viva, sin necesidad de compra)
1. Backup ANTES de reinstalar: `sandboxReceipt`, `com.qobuz.music.plist`, `RecentActivity/last.json` (la reinstalación puede vaciar el contenedor).
2. Instala IPA con v2, abre app, verifica en Filza que `qobuz_hook.log` crece (`alive` cada 60s).
3. Login con la MISMA cuenta Qobuz: si el Hi-Res vuelve sin paywall → confirma credencial server-side (predicción del split-brain).
4. Reproduce Hi-Res 2 min → kill → relaunch → ¿persiste o cae a preview 30s?
5. Exporta `qobuz_hook.log` + `receipt_*.bin` + hora exacta de cada paso.
