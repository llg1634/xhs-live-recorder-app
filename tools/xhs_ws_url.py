import json, sys, time, urllib.request

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
BASE = "http://127.0.0.1:17368"
ROOM = "570501740524334550"
PAGE = "https://www.xiaohongshu.com/livestream/%s" % ROOM


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
time.sleep(12)

# 逐页扫描 CDP 事件里的 webSocket* 类型
seen = {}
for off in (0, 500, 1000, 1500):
    try:
        ev = call("/cdp/events?tabId=%s&limit=500&offset=%d" % (tab, off))
    except Exception as e:
        break
    events = ev.get("events") or []
    for e in events:
        m = e.get("method") or ""
        if "ebSocket" in m or "websocket" in m.lower():
            p = e.get("params") or {}
            key = (m, p.get("url") or (p.get("response") or {}).get("url"))
            seen[key] = p
print("=== websocket events ===")
for (m, u), p in seen.items():
    print(m, "->", str(u)[:400])
    if m == "Network.webSocketWillSendHandshakeRequest":
        print("   headers:", json.dumps(p.get("request", {}).get("headers"), ensure_ascii=False)[:400])

call("/close", {"tabId": tab})
