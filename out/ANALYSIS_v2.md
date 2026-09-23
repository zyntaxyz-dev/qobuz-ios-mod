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

## 6. Segunda sesión (relaunch 16:45:53, mismo contenedor) — deltas
- `pendingSK1`: **21 → 0**. La cola de 21 transacciones sin finalizar NO sobrevivió al relaunch (Apple la purgó o el delivery SK2 las cerró). Revisión E1: no se puede contar con acumulación en cola; la ventana de observación es la sesión viva.
- `RECEIPT[init]` ahora presente (24894B, sha `723d0c0e…` = el `sandboxReceipt` de `phone-files/`) + copia `receipt_init_1790181954.bin`. El watcher cubre ambos casos (missing→copy, present→copy).
- **Cero `productsRequest`** en esta sesión: la consulta de productos (US+DE) es disparada por la vista del paywall, no por el launch. Para capturar `productsResponse` hay que abrir el paywall con el logger vivo.
- Entitlement CA persiste (`count=1`). Ventana de tap aún no capturada: el log termina 16:45:54, el tap de cuenta nueva cae fuera de lo exportado.

## 7. Sesión estática dirigida — branch no-offer (2026-09-23, `tools/xref_string.py`)
- `No offer found matching…` vive en `__TEXT` va `0x101e886f0`, en página que concentra TODO el vocabulario IAP (`getOffer(forceRefresh:offerEligibility:)` … `validateAndCompleteTransaction(_:)`, `retryPendingTransaction()`, `monitorTransactionUpdates()`): cluster `getOffer`/OffersViewModel en `0x10128F–0x1012C`.
- `No offer returned from the API` (va `0x101e88650`) tiene 8 xrefs ADRP+ADD exactos (código `0x1012a94a0` entre ellos); el string `No offer found matching…` no tiene xref ADRP directo (literal outlineado o small-string; Hypothesis).
- **Límite validado**: symtab strippeado (6734 símbolos, todos valor `0x0`, solo binds de frameworks) → sin nombres de función de la app; el código es state-machine async Swift y smda no delimita la función. Atribución funcional estática = costosa. Decisión: la pregunta POST-vs-flag se responde en dinámico (log del tap), no en estático.
- Infra commiteada: `tools/xref_string.py` (scan ADRP por patrón de bytes + disasm local, escala a 28MB), `tools/funcmap.py` (experimental: bounds vía smda + BL/stubs vía LIEF).

## 8. Protocolo v3 en ventana activa (sin compra — la suscripción sigue viva)
Ordenado por valor, ninguno requiere evento de compra:
1. **Keychain probe al init**: revela dónde vive la credencial activa (servicio/cuenta redactada). Es el dato que E2 necesita para el replay de sesión. Si aparece un item nuevo vs. sesión anterior, el timer lo registra.
2. **Playback Hi-Res completo con v3**: al reproducir un track, el fetch de file-URL (full vs preview, `url_template` con `hmac`/`etsp`) debe pasar por `dataTask`/`uploadTask` hookeados. Capturarlo documenta el esquema de firma de URLs del servidor — requisito para evaluar replay fuera de la app.
3. **Tap al Subscribe muerto**: el marcador `TAP` + (ausencia de) red posterior confirma no-op vs. intento. Cuesta un tap.
4. **Heartbeat + diffs durante uso normal**: `reportStreamingStart/End`, revalidaciones de sesión y expiraciones parciales aparecen solos con el uso.
5. Precaución: reinstalar para v3 puede vaciar el contenedor — backup de `sandboxReceipt` + plist + `last.json` ANTES. Predicción split-brain: tras reinstalar, login con la misma cuenta restaura Hi-Res sin paywall (credencial server-side).

## 9. Primera sesión v3 (fresh install 18:47:01, contenedor B117… nuevo)
- Todo arriba (`net=1 up=1 tap=1`), keychain probe con 66 items, `imgSkipped=0`, cero crashes.
- **Credencial localizada (presencia)**: entradas propias `7UCG7QB3B7.com.qobuz.music/accessAuthTo…`, `/refreshAuthT…`, `/tokenExpires…` (+ `/RealmDatabas…`). El trío access/refresh/expiry vive en keychain del teamID de Qobuz; valores jamás logueados por diseño. Es el objetivo de E2: con login válido se reemiten, el replay sería reinyectarlas, no tocar StoreKit.
- Contenedor fresco repite el patrón: `RECEIPT[init] missing` → 24855B a los 2s (sha `93e1bb86…` nuevo, copia `receipt_timer_1790189282.bin`).
- `productsRequest ids={(20181112.studio.de)}`: esta vez SOLO DE (antes US+DE) — la consulta depende de la store/región del momento. Paywall visto a los 2s del launch.
- Entitlement CA persiste tras reinstall (cuenta sandbox Apple, server-side, esperado).
- `pendingSK1=20` en fresh install: la cola es de la cuenta sandbox, no del contenedor. Varía entre sesiones (21→0→20); la purga ocurre del lado Apple.
- `QobuzConnectDeviceID` nuevo (`63D88488…`): cada install genera deviceID distinto — anotado para la pregunta de amarre token↔dispositivo en E2.
- Aún sin `TAP` ni tráfico `/appStore/*`: el tap de cuenta nueva sigue pendiente de exportar.

## 14. Export de sesión OK + modelo de elegibilidad (2026-09-23, v5)
- `EXPORT[init] n=8 bytes=7935 file=session_export_init_1790198003.json` (`logs/qobuz_hook.log:17`, sesión 21:13:22, contenedor BACC nuevo). Contenido (solo metadatos): accessAuthToken 44B + refreshAuthToken 44B + tokenExpires `2026-10…` en claro + OAuth bplist 6880B + Realm-key 64B + UUIDs. Set E2 completo y verificado en estructura.
- `tasksTotal=71 / imgSkipped=45`: cobertura cuantificada — vemos todo, el resto es ruido filtrado.
- Modelo de elegibilidad (observado por ti, consistente con todo): trial 30d SOLO en cuentas Qobuz nuevas (server-side `offerEligibility`); cuenta vieja sin oferta en sideload porque ya consumió; subs web no existen en la app. TestFlight sí muestra oferta en cuenta vieja (Hypothesis: distinto contexto storefront/receipt o chequeo de elegibilidad distinto — pendiente de captura con logger si interesa).
- Higiene v5.1: el scrub ahora enmascara también `refreshToken|authToken|fid|*_token` (el log v5 traía JWT de Firebase en claro; solo telemetría, pero no se comparte).

## 10. Sesión de compra cuenta nueva (20:16:46–20:17:58, mismo contenedor B117)
- **Compra sandbox FRESCA por SK2**: `SK2 verified id=2000001…3333 product=20190214.studio.us date=2026-09-23 20:17:50 expires=2026-09-24 revoked=nil`. Timestamp de compra al segundo, sin sheet visible en log (el sheet es proceso Apple, fuera del tweak — esperado).
- **Credencial emitida alrededor de la compra** (diff keychain crudo init→timer, set limpio): NUEVO `7UCG7QB3B7.com.qobuz.music/accessAuthTo…` + `/refreshAuthT…` + `auth/***`. Nada desaparece. El trío aparece con el login/compra: confirma que la credencial Qobuz nace del flujo de compra y vive en keychain propio.
- `productsRequest ids={(20181112.studio.de)}` (solo DE otra vez) con delegates Mixpanel/APM envueltos — pero **cero `productsResponse`** en ventana: la respuesta no llegó antes del corte o va por otro delegate. Gap abierto.
- **Cero `TAP`**: el botón Subscribe del paywall es SwiftUI — no pasa por `sendAction:to:from:forEvent:`. Lección v4: el marcador de taps debe ser `presentViewController` (sheets del paywall y de Apple) en vez de target-action. El timestamp de compra ya lo da SK2 al segundo, así que no se perdió timing.
- **Cero `/appStore/*`**: el POST a `transactionSubscribed` ocurre DESPUÉS del corte (log termina en el `SK2 verified` 20:17:58; la validación+POST de la app sigue en segundos). Artefacto pendiente: tail de 2–3 min post-compra.
- Colateral: remote-config trae `subscription_external_link=true`, `trial_banner=0`, `player_wake_mode=local` (flags de paywall server-side).
- `pendingSK1=20` estable; receipt presente al init (24875B, reescrito 20:16:00).

## 13. Corrección de rumbo: el POST no es load-bearing (2026-09-23)
- Corrección honesta: vendí renewals acelerados, pero el expiry observado de Apple es +24h (20:17:50→09-24), no minutos. Esperar 4 min podía no traer nada. Los renewals llegarán en horario Apple, no nuestro.
- Sin el POST no se cae nada. Vía E2-trasplante (v5): el dylib ya corre dentro de la app con su mismo keychain — lee los VALORES de `accessAuthToken/refreshAuthToken` y los guarda en `Documents/session_export_*.json` (init + cada rotación). Respaldado fuera, ese archivo + un restaurador v6 (reinyectar pre-login post-expiración) es el PoC E2 completo sin depender del formato del POST.
- Cobertura verificable: `tasksTotal` en el heartbeat demuestra si vemos todo el tráfico o si hay vía no hookeada. Diagnóstico, no suposición.

## 11. Paywall cuenta nueva (11:37 local): precio en texto, no en botón
- El paywall muestra `Free for 30 days, then USD 16.99/month` + `Start your 30-day free trial`, y el Hi-Res con tracks completos funciona en la cuenta nueva.
- Lectura: el 16.99 es **texto de oferta server-driven** (viene de `/appStore/offerEligibility`, backend Qobuz), NO precio de `SKProduct` — el botón no lleva precio porque `productsResponse` nunca resolvió productos de Apple. Doble fuente confirmada: backend sí responde oferta, StoreKit no devuelve productos.
- Esto explica por qué el flujo completa la compra igual (el producto se compra por ID directo: `20190214.studio.us` en el tx SK2) sin mostrar precio Apple en ningún sheet.
- Pendiente sin cambios: tail post-compra con el POST `transactionSubscribed` (formato exacto a rejugear para E2).

## 12. Sesión v4 (20:37:56–20:47:14, contenedor CC42 nuevo): navegación + login mapeados
- Hook `presentViewController` operativo (`vc=1`): `PRESENT SFAuthenticationViewController from=Qobuz.QobuzNavigationController` (20:38:34, 20:39:31) = login OAuth vía browser; luego onboarding SwiftUI (`HostedViewController…ArtistSelectionView_`, `…NotificationView_`) y navegación `QobuzNavigationController`/`TabBar`. Primer mapa de pantallas sin tocar la app.
- Entitlements SK2 = 2 (US compra de hoy + CA histórico). Keychain 67→70 con entradas `com.facebook.sdk.loginmanager/tokencache` = login con Facebook en esta sesión.
- `pendingSK1`: 0 al launch → 20 durante la sesión. La cola se llena EN caliente (no es resto de install): `retryPendingTransaction` genera reintentos en vivo. La purga observada (21→0) fue del lado Apple entre sesiones.
- `imgSkipped` 0→170: el filtro de ruido funciona; el log queda legible.
- El POST `transactionSubscribed` sigue sin aparecer: ocurrió en el gap 20:17:58–20:37:56. **Vía sin compra**: la sub sandbox renueva a ritmo acelerado (cada renovación entrega nuevo tx por `Transaction.updates` y la app debería re-POSTear). Dejar la app viva / relanzar periódicamente con v4 puede capturar un renewal-POST sin comprar nada.
