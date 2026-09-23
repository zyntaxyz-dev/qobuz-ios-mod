// QZBridge.h — bridging header for QobuzLoggerSK2.swift (jailed, ESign)
// Exposes the ObjC file logger to Swift so both write to Documents/qobuz_hook.log.
#import <Foundation/Foundation.h>

void QZLogC(const char *msg);
