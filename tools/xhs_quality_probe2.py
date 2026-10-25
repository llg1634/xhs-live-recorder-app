import json, sys, time, urllib.request

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
BASE = "http://127.0.0.1:17368"
PAGE = "https://www.xiaohongshu.com/livestream/570511686529001102"


def call(path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    headers = {"content-type": "application/json"} if body is not None else {}
    req = urllib.request.Request(BASE + path, data=data, headers=headers,
                                 method="POST" if body is not None else "GET")
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode())


r = call("/open", {"url": PAGE, "active": False})
tab = r.get("tabId") or (r.get("tab") or {}).get("id")
print("tab:", tab)
call("/network/start", {"tabId": tab, "clear": True})
time.sleep(1)
call("/reload", {"tabId": tab})
time.sleep(14)

items = (call("/network?tabId=%s&limit=600" % tab).get("items") or [])
print("rows:", len(items))
cands = [it for it in items if it.get("type") in ("Fetch", "XHR", "Document")]
print("api-ish:", len(cands), [ (it.get('type'), (it.get('url') or '')[:60]) for it in cands[:5]])

found = 0
for it in cands:
    rid = it.get("requestId")
    if not rid:
        continue
    try:
        body = call("/network/body?tabId=%s&requestId=%s" % (tab, rid))
    except Exception:
        continue
    text = json.dumps(body, ensure_ascii=False)
    if "hcv" in text or "_flv" in text or "flv" in text.lower():
        found += 1
        idx = text.find("hcv")
        print("\n=== ", (it.get("url") or "")[:120])
        print(text[max(0, idx - 400):idx + 400] if idx >= 0 else text[:400])
        if found >= 5:
            break

print("\nfound bodies:", found)
call("/close", {"tabId": tab})
