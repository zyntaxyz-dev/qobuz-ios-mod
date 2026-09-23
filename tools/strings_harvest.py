#!/usr/bin/env python3
"""strings_harvest.py - Level 0 stdlib string harvester.
Extracts ASCII strings >=4 from Mach-O, filters by RE-relevant patterns,
writes JSON buckets. No deps.
Usage: python tools/strings_harvest.py <binary> --out out/strings.json
"""
import re, sys, json, pathlib

PATTERNS = {
  "storekit": re.compile(r"SK[A-Z]\w*|StoreKit|Transaction|Product|subscription|Subscription|receipt|Receipt|verifyReceipt|appStoreReceipt", re.I),
  "qobuz_ids": re.compile(r"studio\.(fr|es|de|gb|us|it|be|at|ch|ie|lu|nl|au|dk|no|nz|se|fi)|InAppPurchase|20200924|2018\d+|2019\d+", re.I),
  "premium_flags": re.compile(r"isSubscribed|isPremium|hasSubscription|canPlay|credential|hires|Hi-Res|lossless|flac|format_id|file_type|expire|trial|restore|entitlement|Entitlement", re.I),
  "network": re.compile(r"https?://|qobuz\.com|streaming\.qobuz|api\.|/user/|/track/|/album/|/playlist/|getUrl|sessionStart|user_auth_token|app_id|hmac|etsp", re.I),
  "objc_runtime": re.compile(r"^[A-Z][A-Za-z0-9_]+(ViewController|Manager|Service|Store|Handler|Observer|Delegate|Client|Provider)$"),
  "quality": re.compile(r"192\s?kHz|96\s?kHz|44\.1|24-bit|16-bit|320\s?kbps|MP3|CD quality|Hi-Res", re.I),
  "sandbox": re.compile(r"sandbox|Sandbox|TestFlight|StoreKitConfiguration|DEBUG|adHoc|introductoryOffer|free.*trial|D841B473", re.I),
}

def extract_strings(path, minlen=4, max_bytes=120_000_000):
    data = pathlib.Path(path).read_bytes()
    if len(data) > max_bytes:
        # mmap-like: scan in chunks to avoid RAM spike on 41MB (fine, but safe)
        pass
    # ASCII strings
    ascii_re = re.compile(rb'[\x20-\x7e]{%d,}' % minlen)
    out = []
    for m in ascii_re.finditer(data):
        try:
            s = m.group().decode('ascii')
        except: continue
        if len(s) > 400: s = s[:400]
        out.append((m.start(), s))
    return out, len(data)

def main():
    binary = sys.argv[1]
    outp = "out/strings.json"
    if "--out" in sys.argv:
        outp = sys.argv[sys.argv.index("--out")+1]
    allstrs, fsize = extract_strings(binary)
    buckets = {k: [] for k in PATTERNS}
    buckets["total_ascii"] = len(allstrs)
    buckets["file_size"] = fsize
    seen = {k: set() for k in PATTERNS}
    for off, s in allstrs:
        for k, rx in PATTERNS.items():
            if rx.search(s):
                if s not in seen[k]:
                    seen[k].add(s)
                    # cap buckets to avoid 100k spam
                    if len(buckets[k]) < 3000:
                        buckets[k].append({"off": off, "s": s})
    # stats
    stats = {k: len(v) for k, v in buckets.items() if isinstance(v, list)}
    print(f"[+] file_size={fsize} total_ascii={len(allstrs)}")
    for k, n in stats.items():
        print(f"    {k}: {n}")
    pathlib.Path(outp).write_text(json.dumps(buckets, indent=2))
    print(f"[+] wrote {outp}")

if __name__ == "__main__":
    main()
