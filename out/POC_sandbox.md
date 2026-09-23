# PoC — Explotar ventaja sandbox Qobuz (jailed, ESign)

## Estado actual (evidencia)
- Confirmado: StoreKit híbrido SK1+SK2, endpoints /appStore/offerEligibility + /appStore/transactionSubscribed, credential hires_streaming, StoreKitConfiguration.storekit con 18 subs studio.* free-trial P1M shipeado en release.
- Observado por ti: sideload -> Start 30-day free trial -> full-track 24/192 por horas (no preview).
- Hipótesis líder: resignado => receipt sandbox => StoreKit devuelve purchased test => backend lo valida contra sandbox Apple y emite user_auth_token real con TTL.

## Experimentos mínimos (uno a la vez, con QobuzLogger v1 instalado)

### E1 — Receipt-freeze (menor riesgo, probar primero)
Idea: impedir que la app refresque/invalide el receipt sandbox que ya funciona.
- v2 logger: hook SKReceiptRefreshRequest start -> no-op + log, hook NSBundle appStoreReceiptURL -> devolver path congelado.
- Protocolo: trial sandbox OK -> backup Documents + Library/Preferences via Filza -> kill -> relaunch avión 10s -> relaunch online -> ¿sigue Hi-Res sin nuevo purchase?
- Éxito: Hi-Res persiste tras relaunch sin tap paywall. Fracaso: cae a preview 30s => backend revalida por red, pasar a E2.

### E2 — Entitlement-replay
Idea: reusar transaction sandbox válida.
- Capturar con logger: productID (ej 20181112.studio.es), transactionIdentifier, jwsRepresentation si SK2, respuesta /appStore/transactionSubscribed (status 200 + credential).
- Guardar user_auth_token + expires_in + credential JSON de Filza prefs.
- En instalación limpia, inyectar mismo user_auth_token vía NSUserDefaults restore antes del primer launch (script python que edita plist, reempaqueta).
- Éxito: full-track sin pasar por paywall. Riesgo: token atado a device_id (device_manufacturer_id UUID) => puede requerir spoof device_id original.

### E3 — Flag-pin (más agresivo, solo si E1/E2 fallan)
Idea: forzar isHiresStreamable/hires_streaming=true local.
- Requiere localizar con capstone la función validateAndCompleteTransaction / credential parser y parchear retorno (MOV W0,#1) o NOP del branch a preview.
- ARM64 cuidado: ADRP/ADR, PAC, firma. Hacer copia, parche mínimo, re-firmar ESign, test full-track >90s + badge 24/192.
- Validación: si UI dice Hi-Res pero stream cae a 30s preview => servidor manda preview URL, flag local insuficiente => confirma chequeo servidor estricto, abortar parche.

## Criterios de éxito (todos deben cumplirse)
1. Track completo >90s (no 30s preview) + badge 24/192 en player.
2. Settings Default audio quality permite Hi-Res 192kHz.
3. Sobrevive kill+relaunch (E1/E2) o documentado TTL horas.
4. Log qobuz_hook.log muestra /appStore/transactionSubscribed 200 + credential hires_streaming=true.

## Límites y riesgos
- TTL horas esperado: backend puede revocar trial sandbox al detectar resignado repetido o mismatch App ID.
- No usar cuenta principal: posible flag/ban por abuse trial.
- No publicar productIDs ni tokens: uso investigación local.
- Cada modificación preserva original + sha256 (out/Qobuz.sha256 = aa56c34c...).

## Addendum 2026-09-23 — split-brain (evidencia de dispositivo, revierte el orden E1→E2)

- Confirmado: `Subscription plan = You're currently not subscribed` + botón `Subscribe` SIN precio (`/month` vacío) mientras el player reproduce full-track `24-Bit/192kHz` (Joji, 01:39/-00:11) con badge Hi-Res. La autorización de streaming NO depende del estado de plan visible: vive en la credencial Qobuz server-side (`user_auth_token`/credential del trial sandbox).
- Fuertemente apoyado: precio ausente = `getOffer()` no resuelve `SKProduct`s en este contexto (ver string `No offer found matching the app store product identifiers`). El gate de precio es decorativo; el gate real es la credencial del backend.
- Confirmado: `Documents/RecentActivity/last.json` con `"hires":true` por `contentID` — migas preservables vía Filza.
- Implicación: E2 (replay de sesión Qobuz) pasa por delante de E1 (freeze del receipt Apple). Y v2 se despliega DURANTE la ventana viva: no necesita el instante de compra.
- Nueva cuenta: el botón `Subscribe` está muerto en la cuenta actual (trial consumido). La próxima compra provocable requiere cuenta Qobuz nueva + (probablemente) sandbox tester nuevo de Apple. Antes de eso, backup de `sandboxReceipt` 25 KB + plist + `last.json` fuera del contenedor.
