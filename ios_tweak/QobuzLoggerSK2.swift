// QobuzLoggerSK2.swift — StoreKit 2 listener (jailed, ESign, iOS 15+)
// Compiled into the same QobuzLogger.dylib. Started from ObjC via QZSK2Start().
// Writes to the same Documents/qobuz_hook.log through QZLogC (see QZBridge.h).
// No private API. All failures are logged, never thrown.
import Foundation
import StoreKit

private func sklog(_ s: String) {
    s.withCString { QZLogC($0) }
}

@_cdecl("QZSK2Start")
public func QZSK2Start() {
    sklog("SK2 listener start")
    if #available(iOS 15.0, *) {
        // Live stream of StoreKit 2 transactions (purchases, renewals, revocations).
        Task {
            for await result in Transaction.updates {
                switch result {
                case .verified(let t):
                    sklog("SK2 verified id=\(t.id) product=\(t.productID) date=\(t.purchaseDate) expires=\(String(describing: t.expirationDate)) revoked=\(String(describing: t.revocationDate))")
                    await t.finish()
                case .unverified(let t, let e):
                    sklog("SK2 UNVERIFIED id=\(t.id) product=\(t.productID) err=\(e)")
                }
            }
            sklog("SK2 updates stream ended (unexpected)")
        }
        // One-shot dump of current entitlements at launch.
        Task {
            var ids: [String] = []
            for await r in Transaction.currentEntitlements {
                if case .verified(let t) = r {
                    ids.append("\(t.productID)#\(t.id)")
                }
            }
            sklog("SK2 entitlements count=\(ids.count) [\(ids.joined(separator: ","))]")
        }
    } else {
        sklog("SK2 unsupported OS (<15)")
    }
}
