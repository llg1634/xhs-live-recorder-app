import json, sys, time, urllib.request

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
BASE = "http://127.0.0.1:17368"
PAGE = "https://www.xiaohongshu.com/livestream/570501740524334550"


def call(path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    headers = {"content-type": "application/json"} if body is not None else {}
    req = urllib.request.Request(BASE + path, data=data, headers=headers,
                                 method="POST" if body is not None else "GET")
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode())


r = call("/open", {"url": "about:blank", "active": False})
tab = r.get("tabId") or (r.get("tab") or {}).get("id")
call("/cdp/events/clear", {})
call("/cdp", {"tabId": tab, "method": "Network.enable", "params": {}})
call("/cdp", {"tabId": tab, "method": "Page.navigate", "params": {"url": PAGE}})

found = []
for i in range(10):
    time.sleep(1.5)
    try:
        ev = call("/cdp/events?tabId=%s&limit=2000" % tab)
    except Exception:
        continue
    for e in ev.get("events") or []:
        m = e.get("method") or ""
        if "WebSocket" not in m:
            continue
        p = e.get("params") or {}
        sig = m + str(p.get("url") or (p.get("response") or {}).get("payloadData") or "")[:80]
        if sig in [f[0] for f in found]:
            continue
        found.append((sig, m, p))
    if any(f[1] == "Network.webSocketCreated" for f in found):
        break

print("found:", len(found))
for sig, m, p in found[:30]:
    if m == "Network.webSocketCreated":
        print("[CREATED]", p.get("url"))
    elif m == "Network.webSocketFrameSent":
        print("[SENT]", ((p.get("response") or {}).get("payloadData") or "")[:400])
    elif m == "Network.webSocketFrameReceived":
        d = ((p.get("response") or {}).get("payloadData") or "")
        print("[RECV]", d[:160].replace("\n", " "))
    elif m == "Network.webSocketWillSendHandshakeRequest":
        print("[REQHDR]", json.dumps((p.get("request") or {}).get("headers"), ensure_ascii=False)[:400])

call("/close", {"tabId": tab})
