# Análisis v2 — `logs/qobuz_hook.log` (sesión 2026-09-23 16:35–16:38 UTC)
# Fuente: log completo exportado vía Filza (174 líneas, 20 KB). El log crudo queda en `logs/` (gitignored); aquí solo hallazgos redactados.

## 0. Veredicto del tweak (v2 sí registró)
- Todos los hooks instalados: `HOOK NSURLSession dataTaskWithRequest:completionHandler:`, `dataTaskWithRequest:`, `SKProductsRequest initWithProductIdentifiers:` + `setDelegate:`.
- `SK2 symbol found, starting` + `SK2 listener start` — el listener Swift corre.
- Heartbeat `alive` cada 60s + copia `RECEIPT[timer] bytes=24864` — verificable en vivo, como se pedía.
- Ruido conocido: ~150 líneas `NET-CREATE` de `static.qobuz.com` (portadas). v3 debe filtrar imágenes o contar en vez de loguear.

## 1. Hallazgos (con confianza)

### Confirmado — la app consulta productos US+DE al arrancar
- `IAP productsRequest ids={(20190214.studio.us, 20181112.studio.de)}` (2 ocurrencias, una por delegate).
- Delegates reales envueltos sin crash: `Mixpanel.AutomaticEvents` y `APMProductsRequest`. Nota: Mixpanel intercepta el `SKProductsRequest` de la app (telemetría de terceros sobre el flujo IAP).
- Pendiente: el proxy no capturó ningún `productsResponse` en esta ventana (sin respuesta → sin precios, consistente con el paywall sin precio).

### Confirmado — entitlement SK2 activo de OTRA región (CA)
- `SK2 entitlements count=1 [20230419.studio.ca#…6508]`.
- El producto con derecho vigente (`20230419.studio.ca`) **no está entre los consultados** (US/DE). Desajuste región-consulta vs. derecho que encaja con el split-brain: la UI no ve suscripción y el backend sí autoriza.

### Confirmado — transacción SK2 histórica re-emitida por el stream
- `SK2 verified id=2000001…0494 product=20190214.studio.us date=2025-10-13 expires=2025-10-14 revoked=nil`.
- Transacción expirada hace ~1 año, re-entregada por `Transaction.updates` al suscribirse. Peculiaridad sandbox documentada como dato, no como vía.

### Confirmado — 21 transacciones SK1 sin finalizar
- `alive pendingSK1=21` estable durante toda la sesión. La app observa la cola pero nunca hace `finishTransaction` (o falla siempre).
- Ángulo E1: cola llena de transacciones sandbox sin cerrar + string `retryPendingTransaction()` en binario. Registrar qué hace la app con ellas al comprar (v2 ya loguea `updatedTransactions` si disparan).

### Confirmado — receipt reescrito al arrancar
- `RECEIPT[init] missing` → 2s después existe (`24864B, mtime 16:35:43`). StoreKit regenera el `sandboxReceipt` en cada launch; la copia `receipt_timer_*.bin` quedó preservada en `Documents/`.
- `DEFAULTS[timer]` revela `QobuzConnectDeviceID = 075AD72D-…` (UUID por instalación, relevante para E2: posible amarre token↔dispositivo).

## 2. Gaps (qué sigue sin capturarse y por qué)
1. **Sin tráfico `/appStore/*`**: ningún `transactionSubscribed`/`offerEligibility` en la ventana — no hubo evento de compra/login, esperado. Requiere cuenta nueva + trial fresco.
2. **Sin `productsResponse`**: proxy armado, cero respuestas. O la respuesta llegó antes del wrap (improbable, wrap es en `setDelegate:` previo a `start`) o la sesión no disparó request con respuesta en ventana. Observar en la ventana de compra.
3. **Tráfico JSON de la API Qobuz ausente**: solo imágenes + firebase. Hipótesis: contenido cacheado / sesión ya autenticada sin llamadas, o stack que no pasa por `dataTask` (p. ej. `uploadTask`, que v2 no hookea). v3: añadir `uploadTaskWithRequest:fromData:completionHandler:` + filtro anti-imágenes.
4. **Sin volcado de `credential`/`user_auth_token`**: defaults filtrados solo dieron el deviceID. La credencial vive en keychain o memoria — v3: leer la entrada keychain propia (`SecItemCopyMatching` con el access-group de la app) solo para detectar presencia/longitud, nunca el valor.

## 3. Siguientes pasos
1. Exportar vía Filza y custodiar: `receipt_timer_*.bin` + `qobuz_hook.log` completo (ya en `logs/` local).
2. Ventana de compra con cuenta Qobuz nueva (+ tester sandbox nuevo si Apple lo exige): v2 ya instalado captura `productsResponse` (precio/producto real), `updatedTransactions`/SK2 `updates`, y el POST a `transactionSubscribed` con su respuesta.
3. v3 (solo tras 2): filtro de ruido de imágenes, hook `uploadTask`, presencia-en-keychain, y — si el replay de sesión funciona — PoC E2.

## 4. Addendum — Path B: Subscribe sin compra (cuenta nueva, sin sheet de Apple)

- Observado: en cuenta nueva, tap en `Subscribe` (sin precio) otorga la suscripción directamente — sin sheet, sin `productsResponse` (explica su ausencia en el log: nunca existió).
- Mecanismo hipotético líder (consistente con todo lo anterior): el tap no compra sino que **envía el receipt al backend** (`POST /appStore/transactionSubscribed` con el `sandboxReceipt`, que viene cargado de historial: entitlement CA vigente + tx US verificada + 21 SK1 pendientes) → Qobuz valida contra Apple sandbox → emite credential. Sin productos que resolver, no hay sheet.
- Soporte estático: rama `Matching offer found for product id:` vs `No offer found matching the app store product identifiers:` en `OffersViewModel`, y símbolo Swift `validateTransaction(with:ModelRaw, CredentialContainer, UInt64)` — la validación ata transacción↔credencial.
- Evidencia que lo confirma o refuta: el tail del log en el minuto del tap. Si aparece `NET POST …/appStore/transactionSubscribed -> 200` sin `SK1`/`SK2` previo → Path B confirmado y el exploit es rejugable sin Apple. Si no hay POST → el grant es local y hay que buscar el flag.
- El `receipt_timer_1790181402.bin` (25 KB, verificado en Filza) es la materia prima del replay: si el backend acepta receipt-por-POST, ese archivo es la llave E2.

## 5. Correlación receipt reescrito ↔ stream SK2 (comparativa binaria 2026-09-23)
- `phone-files/receipt_timer_1790181402.bin` (24864B, sha `9e82f34d…`, mtime 16:35:43) vs `phone-files/sandboxReceipt` (24894B, sha `723d0c0e…`, mtime 16:38:46): **el receipt cambió (+30B) 3s después** de `SK2 verified …16:38:43`. Ambos PKCS#7 (`30 82 61…`). Lectura: la entrega del stream SK2 dispara refresh del receipt — el receipt es un documento vivo, no un snapshot; cada copia timestamped vale por su momento.
