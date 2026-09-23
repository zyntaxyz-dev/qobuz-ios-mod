# Qobuz iOS 10.1.0 (260911152300) — Mapa estático v1
# Bundle: com.qobuz.music | Bin: 41.7MB thin arm64 LE | cryptid=0 (desencriptada) | uuid 9f914f0b...
# SHA256 bin: aa56c34c745f9bbb9861f6ca7055fe055344ad324bbc21ea062107f14f5ff4a2

## 1. StoreKit — híbrido SK1 + SK2 [Confirmado]
- Link: /System/Library/Frameworks/StoreKit.framework/StoreKit (LC_LOAD_DYLIB)
- SK1 strings: SKPaymentTransaction, SKProductsRequest, SKProductsRequestDelegate, SKPaymentTransactionObserver, SKProduct, SKError
- SK2 strings: monitorTransactionUpdates(), verifyTransaction(_:), retryPendingTransaction(), hasUnfinishedTransaction, unfinishedTransactionId, transactionRetryCount, /appStore/transactionSubscribed, Transaction verification failed, Verified transaction with id ... received for product:
- Archivo clave: QobuzModules/Sources/Domain/InAppPurchase/InAppPurchaseManager.swift + Offers/OffersViewModel.swift + Routing/InAppPurchaseRouter.swift
- Métodos: getOffer(forceRefresh:offerEligibility:), verifyTransaction(_:), validateAndCompleteTransaction(_:), retryPendingTransaction(), monitorTransactionUpdates(), isCurrentSubscriptionIntroOffer(), Product identifiers extracted:, Matching offer found for product id:, No offer found matching the app store product identifiers:

## 2. Backend Qobuz IAP [Confirmado]
- Service: QobuzModules/Sources/Data/RemoteRepository/QobuzAPIServices/AppStoreService.swift
- Endpoints: /appStore/offerEligibility , /appStore/transactionSubscribed
- Flujo inferido: StoreKit purchase -> verifyTransaction local -> POST transactionSubscribed -> backend otorga credential + user_auth_token
- Otros endpoints: /track/reportStreamingStart|End|EndJson, /track/lyricsUrl, /user/*, /playlist/*, /favorite/*, /purchase/getUserPurchases
- Hosts: prod qobuz-qobuz-prod.web.arc-cdn.net, sandbox qobuz-qobuz-sandbox.web.arc-cdn.net, preprod.qobuz.com, open/play/rec-play/static .qobuz.com

## 3. Entitlement / calidad [Fuertemente apoyado]
- credential.parameters: lossy_streaming, lossless_streaming, hires_streaming, hires_purchases_streaming, mobile_streaming, offline_streaming, included_format_group_ids [1,2,3,4]
- Flags: isHiresStreamable, hiresStreamable == true, isHiResPurchased, User has lost lossless right, hasSubscriptionStarted, Error checking current subscription trial status:, logTrialStatus(), AUDIO_QUALITY_HIRES_LEVEL1/2/3
- Mocks en bundle: getUrlFullAudioRespnseSuccess.json (file_type full, format_id 6, 16/44.1, url_template streaming.qobuz.com/file?uid=&eid=&fmt=&hmac=) vs getUrlPreviewAudioRespnseSuccess.json (file_type preview, 30s mp3/flac)
- fileUrl:trackId:xorMask: , QobuzDASHAudioFile, SingleAudioFile — streaming con xorMask + AudioFileID, reportStreamingStart/End para telemetría

## 4. Sandbox permisivo [Hipótesis fuerte, a validar con logger]
- StoreKitConfiguration.storekit EMBEBIDO en release con 18 subs studio.* (ej 20181112.studio.es, 20190214.studio.us) todas P1M displayPrice 20 + introductoryOffer free P1M. No debería shipearse en App Store.
- String sandboxReceipt (1 ocurrencia, zona Firebase, pero indica chequeo receipt disponible)
- DebugMenu/ + Qobuz/DebugTools.swift + APIEnvironment update(with:envArcXP:) sugiere cambio env prod/sandbox/preprod en runtime
- Paywall observado: Unlock a new music experience / Start your 30-day free trial -> tras sandbox purchase desbloquea Hi-Res 24/192 full-track (tu screenshot PIXELATED KISSES 00:01/-01:49 + Default audio quality Hi-Res 24-bit up to 192kHz)
- Interpretación: resignado ESign => receipt adhoc/missing => StoreKit sandbox devuelve purchased sin cargo => /appStore/transactionSubscribed lo acepta y emite token real con TTL horas => servidor sirve FLAC real. Fail-open, no solo UI.

## 5. Superficie para tweak jailed
- Hook puntos mínimos: SKPaymentQueue updatedTransactions, StoreKit2 Transaction.currentEntitlements, NSBundle appStoreReceiptURL, SKReceiptRefreshRequest, NSURLSession (capturar /appStore/* + /track/reportStreaming*), QBUser credential update, player quality setter, getOffer/product identifiers
- Log destino: Documents/qobuz_hook.log (legible con Filza en iOS 26 jailed)
- Siguiente: ios_tweak/QobuzLogger.m + tools/inject_dylib.py (LC_LOAD_DYLIB @executable_path/Frameworks) + ESign
