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


# 1) 先开空白页，提前 enable Network，再导航 —— 这样 webSocketCreated 一定被记录
r = call("/open", {"url": "about:blank", "active": False})
tab = r.get("tabId") or (r.get("tab") or {}).get("id")
print("tab:", tab)
call("/cdp/events/clear", {})
print("net.enable:", call("/cdp", {"tabId": tab, "method": "Network.enable", "params": {}}).get("ok"))
call("/cdp", {"tabId": tab, "method": "Page.navigate", "params": {"url": PAGE}})
time.sleep(14)

ev = call("/cdp/events?tabId=%s&limit=3000" % tab)
events = ev.get("events") or []
print("events:", len(events))

for e in events:
    m = e.get("method") or ""
    if "WebSocket" not in m:
        continue
    p = e.get("params") or {}
    if m == "Network.webSocketCreated":
        print("\n[CREATED]", p.get("url"))
    elif m == "Network.webSocketWillSendHandshakeRequest":
        print("[REQ] headers:", json.dumps(p.get("request", {}).get("headers"), ensure_ascii=False)[:300])
    elif m == "Network.webSocketHandshakeResponseReceived":
        print("[RESP] status:", (p.get("response") or {}).get("status"))
    elif m == "Network.webSocketFrameSent":
        d = (p.get("response") or {}).get("payloadData") or ""
        print("[SENT]", d[:300].replace("\n", " "))
    elif m == "Network.webSocketFrameReceived":
        d = (p.get("response") or {}).get("payloadData") or ""
        print("[RECV]", d[:200].replace("\n", " "))

# 2) 看看有没有 worker target
try:
    tg = call("/cdp", {"tabId": tab, "method": "Target.getTargets", "params": {}})
    infos = (((tg.get("result") or {}).get("result") or {}).get("targetInfos")) or []
    print("\n=== targets ===")
    for t in infos:
        print(t.get("type"), t.get("url", "")[:120])
except Exception as e:
    print("targets error:", e)

call("/close", {"tabId": tab})
