// QobuzLogger.m v2 — tweak instrumental jailed (ESign, sin jailbreak, iOS 16.4+ / 26)
// Log a Documents/qobuz_hook.log legible con Filza. Solo Foundation + StoreKit + ObjC runtime.
// v2 vs v1: red NSURLSession REAL con fallback pasivo, proxy de SKProductsRequest,
// receipt watcher con copias timestamped, heartbeat 60s, snapshots con diff, redacción de secretos.
// Todo va envuelto en @try: ante cualquier fallo loguea y sigue, jamás crashea la app.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <StoreKit/StoreKit.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>

// Estado de hooks (visible en heartbeat)
static BOOL gNetOK = NO, gUpOK = NO, gTapOK = NO, gVcOK = NO;

#pragma mark - Base logger

static NSString* QZDocDir(void){
  NSArray* d = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
  NSString* doc = d.firstObject;
  return doc ?: NSTemporaryDirectory();
}
static NSString* LogPath(void){
  return [QZDocDir() stringByAppendingPathComponent:@"qobuz_hook.log"];
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
    [h closeFile]; // cerrar en cada escritura = flush garantizado ante kill
  }@catch(...){}
}
// Puente C para Swift (declarado en QZBridge.h).
void QZLogC(const char *msg){
  @try{
    NSString* s = msg ? [NSString stringWithUTF8String:msg] : @"(null)";
    QZLog(@"%@", s);
  }@catch(...){}
}

#pragma mark - Redaction

// Muestra prefijo + longitud, nunca el secreto completo.
static NSString* QZRedact(NSString* s){
  if(!s) return @"(nil)";
  if(s.length <= 12) return @"***";
  return [NSString stringWithFormat:@"%@…(len=%lu)", [s substringToIndex:12], (unsigned long)s.length];
}
// Enmascara valores de claves sensibles dentro de cuerpos JSON/texto (respuesta de red).
static NSString* QZScrubBody(NSString* body){
  if(!body) return @"(nil)";
  @try{
    static NSRegularExpression* rx = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      rx = [NSRegularExpression regularExpressionWithPattern:@"\"(user_auth_token|hmac|jws|signature|receipt-data|receipt_data|key)\"\\s*:\\s*\"([^\"]{13,})\""
                                                     options:NSRegularExpressionCaseInsensitive error:nil];
    });
    NSMutableString* m = [body mutableCopy];
    NSArray* hits = [rx matchesInString:body options:0 range:NSMakeRange(0, body.length)];
    for(NSTextCheckingResult* r in [hits reverseObjectEnumerator]){
      NSRange vr = [r rangeAtIndex:2];
      NSString* v = [body substringWithRange:vr];
      [m replaceCharactersInRange:vr withString:[QZRedact(v) stringByReplacingOccurrencesOfString:@"(len=" withString:@"(scrub len="]];
    }
    return m;
  }@catch(...){ return @"(scrub-fail)"; }
}

#pragma mark - URL filter

static BOOL QZShouldLogURL(NSURL* u){
  if(!u) return NO;
  NSString* s = u.absoluteString;
  if(!s) return NO;
  return [s containsString:@"appStore"] || [s containsString:@"offerEligibility"] ||
         [s containsString:@"transactionSubscribed"] || [s containsString:@"reportStreaming"] ||
         [s containsString:@"qobuz"];
}

// v3: ruido de imágenes (portadas, resizer, CDN editorial) — se cuenta, no se loguea.
static unsigned long gNoiseCount = 0;
static BOOL QZIsNoise(NSURL* u){
  if(!u) return NO;
  NSString* s = u.absoluteString;
  if(!s) return NO;
  return [s containsString:@"/images/"] || [s containsString:@"resizer/v2"] || [s containsString:@"cloudfront"];
}

#pragma mark - Receipt watcher

static NSDate* gLastReceiptMtime = nil;

static void QZSnapshotReceipt(NSString* tag){
  @try{
    NSURL* rurl = [[NSBundle mainBundle] appStoreReceiptURL];
    if(!rurl){ QZLog(@"RECEIPT[%@] no receiptURL", tag); return; }
    NSFileManager* fm = [NSFileManager defaultManager];
    NSDictionary* at = [fm attributesOfItemAtPath:rurl.path error:nil];
    if(!at){ QZLog(@"RECEIPT[%@] missing at %@", tag, rurl.path); return; }
    NSDate* mt = at[NSFileModificationDate];
    unsigned long long sz = [at[NSFileSize] unsignedLongLongValue];
    if([tag isEqualToString:@"timer"] && gLastReceiptMtime && [mt isEqualToDate:gLastReceiptMtime]){
      return; // sin cambios: no duplicar el archivo de 25KB
    }
    gLastReceiptMtime = mt;
    // hash corto para detectar cambios reales
    NSData* d = [NSData dataWithContentsOfURL:rurl];
    NSString* h16 = @"?";
    if(d){
      unsigned char h[CC_SHA256_DIGEST_LENGTH];
      CC_SHA256(d.bytes, (CC_LONG)d.length, h);
      NSMutableString* ms = [NSMutableString string];
      for(int i=0;i<8;i++) [ms appendFormat:@"%02x", h[i]];
      h16 = ms;
    }
    NSString* dst = [QZDocDir() stringByAppendingPathComponent:
      [NSString stringWithFormat:@"receipt_%@_%.0f.bin", tag, [[NSDate date] timeIntervalSince1970]]];
    NSError* e = nil;
    [fm copyItemAtPath:rurl.path toPath:dst error:&e];
    QZLog(@"RECEIPT[%@] bytes=%llu sha16=%@ mtime=%@ copy=%@", tag, sz, h16, mt, e ? [@"FAIL " stringByAppendingString:e.localizedDescription] : [dst lastPathComponent]);
  }@catch(...){ QZLog(@"RECEIPT[%@] exception", tag); }
}

#pragma mark - NSUserDefaults snapshot with diff

static NSDictionary* gPrevDefaults = nil;

static void QZDumpUserDefaults(NSString* tag, BOOL force){
  @try{
    NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
    NSDictionary* all = [d dictionaryRepresentation];
    NSMutableDictionary* hits = [NSMutableDictionary dictionary];
    for(NSString* k in all){
      NSString* kl = [k lowercaseString];
      if([kl containsString:@"credential"]||[kl containsString:@"hires"]||[kl containsString:@"subscri"]||
         [kl containsString:@"trial"]||[kl containsString:@"offer"]||[kl containsString:@"entitle"]||
         [kl containsString:@"qobuz"]||[kl containsString:@"credential"]){
        id v = all[k];
        NSString* vs = ([v isKindOfClass:[NSString class]] && [[k lowercaseString] containsString:@"token"]) ? (id)QZRedact(v) : [v description];
        if(vs.length > 300) vs = [[vs substringToIndex:300] stringByAppendingString:@"…(trunc)"];
        hits[k] = vs;
      }
    }
    if(!force && gPrevDefaults && [hits isEqualToDictionary:gPrevDefaults]) return; // sin cambios
    gPrevDefaults = [hits copy];
    QZLog(@"DEFAULTS[%@] n=%lu %@", tag, (unsigned long)hits.count, hits);
  }@catch(...){ QZLog(@"DEFAULTS[%@] exception", tag); }
}

#pragma mark - NSURLSession interception (real, with fallback)

typedef NSURLSessionDataTask* (*QZDataTaskCH)(id, SEL, NSURLRequest*, void(^)(NSData*,NSURLResponse*,NSError*));

static void QZLogResponse(NSURLRequest* req, NSData* d, NSURLResponse* r){
  @try{
    NSHTTPURLResponse* hr = (id)r;
    long code = [hr isKindOfClass:[NSHTTPURLResponse class]] ? hr.statusCode : -1;
    NSString* body = @"";
    if(d && d.length && d.length < 20000){
      body = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"(binary)";
      if(body.length > 2000) body = [[body substringToIndex:2000] stringByAppendingString:@"…(trunc)"];
      body = QZScrubBody(body);
    } else if(d) {
      body = [NSString stringWithFormat:@"(large %luB, skipped)", (unsigned long)d.length];
    }
    QZLog(@"NET-RESP %@ -> %ld %@", req.URL.absoluteString, code, body);
  }@catch(...){}
}

static QZDataTaskCH gOrigDataTaskCH = NULL;
static NSURLSessionDataTask* qz_dataTaskCH(id self, SEL _cmd, NSURLRequest* req, void(^comp)(NSData*,NSURLResponse*,NSError*)){
  if(!gOrigDataTaskCH) return nil;
  if(QZIsNoise(req.URL)){ __sync_fetch_and_add(&gNoiseCount, 1); return gOrigDataTaskCH(self, _cmd, req, comp); }
  @try{
    if(QZShouldLogURL(req.URL)){
      QZLog(@"NET %@ %@ bodylen=%lu", req.HTTPMethod ?: @"?", req.URL.absoluteString, (unsigned long)req.HTTPBody.length);
    }
  }@catch(...){}
  void(^wrapped)(NSData*,NSURLResponse*,NSError*) = ^(NSData* d, NSURLResponse* r, NSError* e){
    @try{
      if(QZShouldLogURL(req.URL)) QZLogResponse(req, d, r);
      if(e && QZShouldLogURL(req.URL)) QZLog(@"NET-ERR %@ %@", req.URL.absoluteString, e);
    }@catch(...){}
    if(comp) comp(d, r, e);
  };
  return gOrigDataTaskCH(self, _cmd, req, wrapped);
}

typedef NSURLSessionDataTask* (*QZDataTaskPlain)(id, SEL, NSURLRequest*);
static QZDataTaskPlain gOrigDataTaskPlain = NULL;
static NSURLSessionDataTask* qz_dataTaskPlain(id self, SEL _cmd, NSURLRequest* req){
  if(!gOrigDataTaskPlain) return nil;
  if(QZIsNoise(req.URL)){ __sync_fetch_and_add(&gNoiseCount, 1); return gOrigDataTaskPlain(self, _cmd, req); }
  @try{
    if(QZShouldLogURL(req.URL)) QZLog(@"NET-CREATE %@ %@", req.HTTPMethod ?: @"?", req.URL.absoluteString);
  }@catch(...){}
  return gOrigDataTaskPlain(self, _cmd, req);
}

#pragma mark - uploadTask (v3: cubre stacks que suben JSON en vez de dataTask)

typedef NSURLSessionUploadTask* (*QZUploadData)(id, SEL, NSURLRequest*, NSData*, void(^)(NSData*,NSURLResponse*,NSError*));
static QZUploadData gOrigUploadData = NULL;
static NSURLSessionUploadTask* qz_uploadData(id self, SEL _cmd, NSURLRequest* req, NSData* body, void(^comp)(NSData*,NSURLResponse*,NSError*)){
  if(!gOrigUploadData) return nil;
  if(QZIsNoise(req.URL)) return gOrigUploadData(self, _cmd, req, body, comp);
  @try{
    if(QZShouldLogURL(req.URL)){
      QZLog(@"NET-UP %@ %@ bodylen=%lu", req.HTTPMethod ?: @"?", req.URL.absoluteString,
            (unsigned long)(req.HTTPBody.length + (body ? body.length : 0)));
    }
  }@catch(...){}
  void(^wrapped)(NSData*,NSURLResponse*,NSError*) = ^(NSData* d, NSURLResponse* r, NSError* e){
    @try{
      if(QZShouldLogURL(req.URL) && !QZIsNoise(req.URL)) QZLogResponse(req, d, r);
      if(e && QZShouldLogURL(req.URL)) QZLog(@"NET-ERR %@ %@", req.URL.absoluteString, e);
    }@catch(...){}
    if(comp) comp(d, r, e);
  };
  return gOrigUploadData(self, _cmd, req, body, wrapped);
}

typedef NSURLSessionUploadTask* (*QZUploadFile)(id, SEL, NSURLRequest*, NSURL*, void(^)(NSData*,NSURLResponse*,NSError*));
static QZUploadFile gOrigUploadFile = NULL;
static NSURLSessionUploadTask* qz_uploadFile(id self, SEL _cmd, NSURLRequest* req, NSURL* furl, void(^comp)(NSData*,NSURLResponse*,NSError*)){
  if(!gOrigUploadFile) return nil;
  if(QZIsNoise(req.URL)) return gOrigUploadFile(self, _cmd, req, furl, comp);
  @try{
    if(QZShouldLogURL(req.URL)) QZLog(@"NET-UPFILE %@ %@ file=%@", req.HTTPMethod ?: @"?", req.URL.absoluteString, furl.lastPathComponent ?: @"?");
  }@catch(...){}
  void(^wrapped)(NSData*,NSURLResponse*,NSError*) = ^(NSData* d, NSURLResponse* r, NSError* e){
    @try{
      if(QZShouldLogURL(req.URL) && !QZIsNoise(req.URL)) QZLogResponse(req, d, r);
    }@catch(...){}
    if(comp) comp(d, r, e);
  };
  return gOrigUploadFile(self, _cmd, req, furl, wrapped);
}

#pragma mark - Tap marker (v3: timestamp exacto del Subscribe)

typedef BOOL (*QZSendAction)(id, SEL, SEL, id, id, UIEvent*);
static QZSendAction gOrigSendAction = NULL;
static BOOL qz_sendAction(id self, SEL _cmd, SEL action, id to, id from, UIEvent* event){
  @try{
    NSString* a = NSStringFromSelector(action) ?: @"?";
    NSString* senderDesc = @"?";
    @try{
      if([from isKindOfClass:[UIButton class]]){
        senderDesc = [NSString stringWithFormat:@"UIButton[%@]", [(UIButton*)from currentTitle] ?: @"?" ];
      } else if(from) {
        senderDesc = NSStringFromClass([from class]);
      }
    }@catch(...){}
    BOOL hit = [a rangeOfString:@"ubscri" options:NSCaseInsensitiveSearch].location != NSNotFound ||
               [a rangeOfString:@"purchase" options:NSCaseInsensitiveSearch].location != NSNotFound ||
               [a rangeOfString:@"trial" options:NSCaseInsensitiveSearch].location != NSNotFound ||
               [senderDesc rangeOfString:@"ubscri" options:NSCaseInsensitiveSearch].location != NSNotFound;
    if(hit){
      QZLog(@"TAP action=%@ to=%@ sender=%@", a, to ? NSStringFromClass([to class]) : @"?", senderDesc);
      QZSnapshotReceipt(@"tap");
      QZDumpUserDefaults(@"tap", YES);
    }
  }@catch(...){}
  if(!gOrigSendAction) return NO;
  return gOrigSendAction(self, _cmd, action, to, from, event);
}

#pragma mark - Sheet marker (v4: paywall y sheets de Apple son UIKit/SwiftUI presentados)

typedef void (*QZPresentVC)(id, SEL, UIViewController*, BOOL, void(^)(void));
static QZPresentVC gOrigPresentVC = NULL;
static void qz_presentVC(id self, SEL _cmd, UIViewController* vc, BOOL animated, void(^comp)(void)){
  @try{
    NSString* cn = vc ? NSStringFromClass([vc class]) : @"(nil)";
    NSString* from = NSStringFromClass([self class]);
    // Solo presentaciones interesantes + resumen; los sheets son infrecuentes y de alta señal.
    QZLog(@"PRESENT %@ from=%@ animated=%d", cn, from, animated);
  }@catch(...){}
  if(!gOrigPresentVC) return;
  gOrigPresentVC(self, _cmd, vc, animated, comp);
}

static BOOL QZExchange(Class c, SEL s, IMP repl, IMP* outOrig){
  @try{
    if(!c) return NO;
    Method m = class_getInstanceMethod(c, s);
    if(!m){ QZLog(@"MISS %@ %@", NSStringFromClass(c), NSStringFromSelector(s)); return NO; }
    *outOrig = method_getImplementation(m);
    method_setImplementation(m, repl);
    QZLog(@"HOOK %@ %@", NSStringFromClass(c), NSStringFromSelector(s));
    return YES;
  }@catch(...){ return NO; }
}

#pragma mark - SKProductsRequest: product IDs + response proxy

typedef id (*QZProductsInit)(id, SEL, NSSet*);
static QZProductsInit gOrigProductsInit = NULL;
static id qz_productsInit(id self, SEL _cmd, NSSet* ids){
  @try{ QZLog(@"IAP productsRequest ids=%@", ids); }@catch(...){}
  if(!gOrigProductsInit) return self;
  return gOrigProductsInit(self, _cmd, ids);
}

// Proxy que envuelve el delegate real: loguea productIDs/precios y reenvía TODO.
@interface QZProductsProxy : NSProxy {
  id _real;
}
+ (instancetype)proxyWithReal:(id)r;
@end
@implementation QZProductsProxy
+ (instancetype)proxyWithReal:(id)r{
  QZProductsProxy* p = [QZProductsProxy alloc];
  p->_real = r;
  return p;
}
- (NSMethodSignature*)methodSignatureForSelector:(SEL)s{
  @try{
    NSMethodSignature* sig = [_real methodSignatureForSelector:s];
    if(sig) return sig;
    return [NSObject instanceMethodSignatureForSelector:@selector(init)];
  }@catch(...){ return [NSObject instanceMethodSignatureForSelector:@selector(init)]; }
}
- (void)forwardInvocation:(NSInvocation*)inv{
  @try{
    SEL s = inv.selector;
    if(s == @selector(productsRequest:didReceiveResponse:)){
      __unsafe_unretained SKProductsResponse* resp = nil;
      [inv getArgument:&resp atIndex:3];
      @try{
        NSMutableArray* arr = [NSMutableArray array];
        for(SKProduct* p in resp.products){
          [arr addObject:[NSString stringWithFormat:@"%@ [%@ %@]", p.productIdentifier, p.priceLocale.localeIdentifier, p.price]];
        }
        QZLog(@"IAP productsResponse n=%lu invalid=%@ | %@", (unsigned long)resp.products.count, resp.invalidProductIdentifiers, [arr componentsJoinedByString:@"; "]);
      }@catch(...){ QZLog(@"IAP productsResponse parse-fail"); }
    }
    [inv invokeWithTarget:_real];
  }@catch(...){}
}
- (BOOL)respondsToSelector:(SEL)s{ return [_real respondsToSelector:s]; }
- (BOOL)conformsToProtocol:(Protocol*)p{ return [_real conformsToProtocol:p]; }
- (Class)class{ return [_real class]; }
- (BOOL)isKindOfClass:(Class)c{ return [_real isKindOfClass:c]; }
- (NSString*)description{ return [_real description]; }
@end

typedef void (*QZSetDelegate)(id, SEL, id);
static QZSetDelegate gOrigSetDelegate = NULL;
static void qz_setDelegate(id self, SEL _cmd, id d){
  @try{
    if(d && ![d isKindOfClass:[QZProductsProxy class]]){
      QZLog(@"IAP wrap delegate %@", NSStringFromClass([d class]));
      d = [QZProductsProxy proxyWithReal:d];
    }
  }@catch(...){}
  if(gOrigSetDelegate) gOrigSetDelegate(self, _cmd, d);
}

#pragma mark - SK1 observer (fallback / pending count)

@interface QZObserver : NSObject <SKPaymentTransactionObserver> @end
@implementation QZObserver
- (void)paymentQueue:(SKPaymentQueue*)q updatedTransactions:(NSArray<SKPaymentTransaction*>*)txs{
  for(SKPaymentTransaction* t in txs){
    QZLog(@"SK1 state=%ld product=%@ tid=%@ otid=%@ err=%@", (long)t.transactionState, t.payment.productIdentifier, t.transactionIdentifier, t.originalTransaction.transactionIdentifier, t.error);
  }
  QZSnapshotReceipt(@"sk1-event");
  QZDumpUserDefaults(@"sk1-event", YES);
}
- (void)paymentQueue:(SKPaymentQueue*)q removedTransactions:(NSArray*)txs{ QZLog(@"SK1 removed %lu", (unsigned long)txs.count); }
- (void)paymentQueueRestoreCompletedTransactionsFinished:(SKPaymentQueue*)q{ QZLog(@"SK1 restore finished"); }
- (void)paymentQueue:(SKPaymentQueue*)q restoreCompletedTransactionsFailedWithError:(NSError*)e{ QZLog(@"SK1 restore fail %@", e); }
@end

#pragma mark - Keychain presence probe (v3: solo metadatos, jamás secretos)

static NSString* gKeychainSig = nil;

static void QZKeychainProbe(NSString* tag, BOOL force){
  @try{
    NSMutableArray* items = [NSMutableArray array];
    for(id cls in @[(id)kSecClassGenericPassword, (id)kSecClassInternetPassword]){
      NSDictionary* q = @{ (id)kSecClass: cls,
                           (id)kSecReturnAttributes: @YES,
                           (id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll };
      CFTypeRef out = NULL;
      OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)q, &out);
      if(st == errSecSuccess && out != NULL){
        @try{
          for(NSDictionary* a in (__bridge NSArray*)out){
            NSString* svc = [NSString stringWithFormat:@"%@", a[(id)kSecAttrService] ?: a[(id)kSecAttrServer] ?: @"?"];
            NSString* acct = [NSString stringWithFormat:@"%@", a[(id)kSecAttrAccount] ?: @"?"];
            if(svc.length > 80) svc = [svc substringToIndex:80];
            [items addObject:[NSString stringWithFormat:@"%@/%@", svc, QZRedact(acct)]];
          }
        }@catch(...){}
        CFRelease(out);
      } else if(st != errSecItemNotFound){
        QZLog(@"KEYCHAIN[%@] status=%d", tag, (int)st);
        return;
      }
    }
    NSString* sig = [[items sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@";"];
    if(!force && gKeychainSig && [sig isEqualToString:gKeychainSig]) return; // sin cambios
    gKeychainSig = [sig copy];
    QZLog(@"KEYCHAIN[%@] n=%lu %@", tag, (unsigned long)items.count, sig);
  }@catch(...){ QZLog(@"KEYCHAIN[%@] exception", tag); }
}

#pragma mark - Heartbeat (verificación en vivo vía Filza)

static void QZHeartbeat(void){
  @try{
    NSUInteger pending = 0;
    @try{ pending = [[SKPaymentQueue defaultQueue] transactions].count; }@catch(...){}
    NSURL* rurl = [[NSBundle mainBundle] appStoreReceiptURL];
    NSDictionary* at = rurl ? [[NSFileManager defaultManager] attributesOfItemAtPath:rurl.path error:nil] : nil;
    QZLog(@"alive pendingSK1=%lu receipt=%@B mtime=%@ imgSkipped=%lu hooks(net=%d,up=%d,tap=%d,vc=%d)", (unsigned long)pending,
          at ? at[NSFileSize] : @"?", at ? at[NSFileModificationDate] : @"?", gNoiseCount, gNetOK, gUpOK, gTapOK, gVcOK);
    if(at && (!gLastReceiptMtime || ![at[NSFileModificationDate] isEqualToDate:gLastReceiptMtime])){
      QZSnapshotReceipt(@"timer"); // el receipt cambió: preservar
    }
    QZDumpUserDefaults(@"timer", NO); // solo loguea si hubo cambios
    QZKeychainProbe(@"timer", NO);    // solo loguea si hubo cambios
  }@catch(...){}
}

#pragma mark - Init

__attribute__((constructor)) static void qz_init(void){
  @try{
    QZLog(@"=== QobuzLogger v4 init bundle=%@ ===", [[NSBundle mainBundle] bundleIdentifier]);
    QZLog(@"receiptURL=%@", [[[NSBundle mainBundle] appStoreReceiptURL] path]);

    // 1. SK1 observer (fallback + conteo de pendientes)
    @try{
      QZObserver* o = [QZObserver new];
      [[SKPaymentQueue defaultQueue] addTransactionObserver:o];
      QZLog(@"SK1 observer added. pending=%lu", (unsigned long)[[SKPaymentQueue defaultQueue] transactions].count);
    }@catch(NSException* e){ QZLog(@"SK1 observer fail %@", e); }

    // 2. NSURLSession: intercepción real (con fallback documentado)
    @try{
      IMP o = NULL;
      if(QZExchange([NSURLSession class], @selector(dataTaskWithRequest:completionHandler:), (IMP)qz_dataTaskCH, &o)){
        gOrigDataTaskCH = (QZDataTaskCH)o; gNetOK = YES;
      }
    }@catch(...){}
    @try{
      IMP o = NULL;
      if(QZExchange([NSURLSession class], @selector(dataTaskWithRequest:), (IMP)qz_dataTaskPlain, &o)){
        gOrigDataTaskPlain = (QZDataTaskPlain)o;
      }
    }@catch(...){}
    // 2b. uploadTask (v3): stacks que suben JSON en vez de dataTask
    @try{
      IMP o = NULL;
      if(QZExchange([NSURLSession class], @selector(uploadTaskWithRequest:fromData:completionHandler:), (IMP)qz_uploadData, &o)){
        gOrigUploadData = (QZUploadData)o; gUpOK = YES;
      }
    }@catch(...){}
    @try{
      IMP o = NULL;
      if(QZExchange([NSURLSession class], @selector(uploadTaskWithRequest:fromFile:completionHandler:), (IMP)qz_uploadFile, &o)){
        gOrigUploadFile = (QZUploadFile)o; gUpOK = YES;
      }
    }@catch(...){}
    if(!gNetOK && !gUpOK) QZLog(@"NET-FALLBACK passive mode (exchange failed, SK1+polling only)");
    // 2c. Tap marker (v3): timestamp exacto de cada Subscribe/purchase
    @try{
      IMP o = NULL;
      if(QZExchange([UIApplication class], @selector(sendAction:to:from:forEvent:), (IMP)qz_sendAction, &o)){
        gOrigSendAction = (QZSendAction)o; gTapOK = YES;
      }
    }@catch(...){}
    if(!gTapOK) QZLog(@"TAP-FALLBACK sendAction not hooked");
    // 2d. Sheet marker (v4): el paywall SwiftUI no usa target-action; los sheets sí dejan huella aquí
    @try{
      IMP o = NULL;
      if(QZExchange([UIViewController class], @selector(presentViewController:animated:completion:), (IMP)qz_presentVC, &o)){
        gOrigPresentVC = (QZPresentVC)o; gVcOK = YES;
      }
    }@catch(...){}
    if(!gVcOK) QZLog(@"VC-FALLBACK presentViewController not hooked");
    // 3. SKProductsRequest: IDs al init + proxy de respuesta
    @try{
      Class c = NSClassFromString(@"SKProductsRequest");
      IMP o1 = NULL, o2 = NULL;
      if(QZExchange(c, @selector(initWithProductIdentifiers:), (IMP)qz_productsInit, &o1)) gOrigProductsInit = (QZProductsInit)o1;
      if(QZExchange(c, @selector(setDelegate:), (IMP)qz_setDelegate, &o2)) gOrigSetDelegate = (QZSetDelegate)o2;
    }@catch(...){ QZLog(@"IAP hook fail"); }

    // 4. Baseline: receipt + defaults + keychain (solo presencia)
    QZSnapshotReceipt(@"init");
    QZDumpUserDefaults(@"init", YES);
    QZKeychainProbe(@"init", YES);

    // 5. StoreKit 2 listener (Swift, símbolo opcional: dlsym, sin link duro)
    @try{
      void (*sk2start)(void) = dlsym(RTLD_DEFAULT, "QZSK2Start");
      if(sk2start){ QZLog(@"SK2 symbol found, starting"); sk2start(); }
      else QZLog(@"SK2 symbol missing (ObjC-only build), SK2 via red+polling");
    }@catch(...){}

    // 6. Heartbeat en main runloop (verificable en vivo con Filza)
    dispatch_async(dispatch_get_main_queue(), ^{
      @try{
        [NSTimer scheduledTimerWithTimeInterval:60.0 repeats:YES block:^(NSTimer* t){ QZHeartbeat(); }];
        QZLog(@"heartbeat armed (60s). Reproduce flujo y observa el log crecer.");
      }@catch(...){}
    });
    QZLog(@"=== QobuzLogger v4 ready (net=%d up=%d tap=%d vc=%d) ===", gNetOK, gUpOK, gTapOK, gVcOK);
  }@catch(...){}
}
