// QobuzLogger.m — tweak instrumental jailed (ESign, sin jailbreak, iOS 16.4+ / 26)
// Log a Documents/qobuz_hook.log legible con Filza. Sin Substrate, solo runtime ObjC.
// Compilar en Mac/Xcode: clang -arch arm64 -dynamiclib -framework Foundation -framework StoreKit -o QobuzLogger.dylib QobuzLogger.m
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <StoreKit/StoreKit.h>

static NSString* LogPath(void){
  NSArray* d = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
  NSString* doc = d.firstObject ?: NSTemporaryDirectory();
  return [doc stringByAppendingPathComponent:@"qobuz_hook.log"];
}
static void QZLog(NSString* fmt, ...){
  @try{
    va_list a; va_start(a, fmt);
    NSString* msg = [[NSString alloc] initWithFormat:fmt arguments:a];
    va_end(a);
    NSString* line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
    NSLog(@"[QobuzLogger] %@", msg);
    NSString* p = LogPath();
    NSFileManager* fm = [NSFileManager defaultManager];
    if(![fm fileExistsAtPath:p]){ [@"" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
    NSFileHandle* h = [NSFileHandle fileHandleForWritingAtPath:p];
    [h seekToEndOfFile];
    [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
  }@catch(...){}
}

// --- NSURLSession hook: capturar /appStore/* y /track/report* ---
static void (*orig_DataTask)(id, SEL, NSURLRequest*, void(^)(NSData*,NSURLResponse*,NSError*));
static void swiz_DataTask(id self, SEL _cmd, NSURLRequest* req, void(^comp)(NSData*,NSURLResponse*,NSError*)){
  @try{
    NSString* u = req.URL.absoluteString ?: @"?";
    NSString* m = req.HTTPMethod ?: @"?";
    if([u containsString:@"appStore"]||[u containsString:@"offerEligibility"]||[u containsString:@"transactionSubscribed"]||[u containsString:@"reportStreaming"]||[u containsString:@"qobuz"]){
      QZLog(@"NET %@ %@ headers=%@ bodylen=%lu", m, u, req.allHTTPHeaderFields, (unsigned long)req.HTTPBody.length);
    }
  }@catch(...){}
  // llamar original via objc_msgSend es complejo con bloques; usamos implementación intercambiada:
  // Como usamos method_exchange, llamar swiz_DataTask llama al original. Truco: no llamamos orig directamente aquí.
  // Este cuerpo será el "nuevo" original tras exchange, así que re-despachamos:
  // Para evitar recursión, obtenemos IMP original guardado.
  // Simplificación: forward manual
  if(orig_DataTask) orig_DataTask(self, _cmd, req, ^(NSData* d, NSURLResponse* r, NSError* e){
    @try{
      NSHTTPURLResponse* hr = (id)r;
      if([req.URL.absoluteString containsString:@"appStore"] && d && d.length < 4000){
        NSString* body = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        QZLog(@"NET-RESP %@ %ld %@", req.URL.absoluteString, (long)hr.statusCode, [body substringToIndex:MIN(2000,body.length)]);
      }
    }@catch(...){}
    if(comp) comp(d,r,e);
  });
}

// --- SKPaymentQueue observer propio (no swizzle, solo observador) ---
@interface QZObserver : NSObject <SKPaymentTransactionObserver> @end
@implementation QZObserver
- (void)paymentQueue:(SKPaymentQueue*)q updatedTransactions:(NSArray<SKPaymentTransaction*>*)txs{
  for(SKPaymentTransaction* t in txs){
    QZLog(@"SK1 state=%ld product=%@ tid=%@ otid=%@ err=%@", (long)t.transactionState, t.payment.productIdentifier, t.transactionIdentifier, t.originalTransaction.transactionIdentifier, t.error);
  }
}
- (void)paymentQueue:(SKPaymentQueue*)q removedTransactions:(NSArray*)txs{ QZLog(@"SK1 removed %lu", (unsigned long)txs.count); }
- (void)paymentQueueRestoreCompletedTransactionsFinished:(SKPaymentQueue*)q{ QZLog(@"SK1 restore finished"); }
- (void)paymentQueue:(SKPaymentQueue*)q restoreCompletedTransactionsFailedWithError:(NSError*)e{ QZLog(@"SK1 restore fail %@", e); }
@end

// --- NSUserDefaults hook: capturar credential / hires flags ---
static void HookClass(NSString* clsName, SEL sel){
  @try{
    Class c = NSClassFromString(clsName);
    if(!c) return;
    Method m = class_getInstanceMethod(c, sel);
    if(!m){ QZLog(@"MISS %@ %@", clsName, NSStringFromSelector(sel)); return; }
    QZLog(@"FOUND %@ %@", clsName, NSStringFromSelector(sel));
  }@catch(...){}
}

__attribute__((constructor)) static void qz_init(void){
  @try{
    QZLog(@"=== QobuzLogger init bundle=%@ ===", [[NSBundle mainBundle] bundleIdentifier]);
    QZLog(@"receiptURL=%@", [[[NSBundle mainBundle] appStoreReceiptURL] path]);
    // 1. observer SK1
    @try{
      QZObserver* o = [QZObserver new];
      [[SKPaymentQueue defaultQueue] addTransactionObserver:o];
      QZLog(@"SK1 observer added. pending=%lu", (unsigned long)[[SKPaymentQueue defaultQueue] transactions].count);
      for(SKPaymentTransaction* t in [[SKPaymentQueue defaultQueue] transactions]){
        QZLog(@"SK1 pending state=%ld %@ %@", (long)t.transactionState, t.payment.productIdentifier, t.transactionIdentifier);
      }
    }@catch(NSException* e){ QZLog(@"SK1 observer fail %@", e); }
    // 2. NSURLSession swizzle (solo si existe)
    @try{
      Class c = [NSURLSession class];
      SEL s = @selector(dataTaskWithRequest:completionHandler:);
      Method m = class_getInstanceMethod(c, s);
      if(m){
        orig_DataTask = (void*)method_getImplementation(m);
        // Nota: exchange manual con función C es frágil; preferimos log pasivo vía observer.
        // No hacemos exchange agresivo en v1 para no crashear. Solo dejamos constancia.
        QZLog(@"FOUND NSURLSession dataTaskWithRequest:completionHandler: (passive v1, no exchange para estabilidad)");
      }
    }@catch(...){}
    // 3. Mapear clases Qobuz clave sin invocarlas (evidencia para Fase 3)
    for(NSString* cn in @[@"NSBundle",@"SKProductsRequest",@"SKPaymentQueue",@"NSURLSession",@"NSUserDefaults",@"AVPlayer"]){
      QZLog(@"class %@ exists=%d", cn, NSClassFromString(cn)!=nil);
    }
    // 4. UserDefaults snapshot (credential/hires)
    @try{
      NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
      NSDictionary* all = [d dictionaryRepresentation];
      NSMutableArray* hits = [NSMutableArray array];
      for(NSString* k in all){
        NSString* kl = k.lowercaseString;
        if([kl containsString:@"credential"]||[kl containsString:@"hires"]||[kl containsString:@"subscri"]||[kl containsString:@"trial"]||[kl containsString:@"offer"]||[kl containsString:@"entitle"]||[kl containsString:@"qobuz"]){
          [hits addObject:[NSString stringWithFormat:@"%@=%@", k, all[k]]];
        }
      }
      QZLog(@"NSUserDefaults hits=%lu %@", (unsigned long)hits.count, [hits componentsJoinedByString:@"; "]);
    }@catch(...){}
    // 5. Documentar StoreKit2 disponibilidad (iOS 15+)
    QZLog(@"StoreKit2 check: NSClass Transaction=%d Product=%d", NSClassFromString(@"_TtC8StoreKit11Transaction")!=nil, NSClassFromString(@"_TtC8StoreKit7Product")!=nil);
    QZLog(@"=== QobuzLogger ready: reproduce paywall -> trial -> HiRes playback, luego lee este log con Filza ===");
  }@catch(...){}
}
