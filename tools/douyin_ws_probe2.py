import json, sys, time, urllib.request, base64

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
BASE = "http://127.0.0.1:17368"
PAGE = "https://live.douyin.com/346761239651"


def call(path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    headers = {"content-type": "application/json"} if body is not None else {}
    req = urllib.request.Request(BASE + path, data=data, headers=headers,
                                 method="POST" if body is not None else "GET")
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode())


r = call("/open", {"url": PAGE, "active": True})
tab = r.get("tabId") or (r.get("tab") or {}).get("id")
print("tab:", tab)
print("network/start:", call("/network/start", {"tabId": tab, "clear": True}))
time.sleep(2)
call("/reload", {"tabId": tab})
for i in range(8):
    time.sleep(2)
    ev = call("/cdp/events?tabId=%s&limit=3000" % tab)
    n = len(ev.get("events") or [])
    if i % 2 == 0:
        print("poll", i, "events:", n)
    if n:
        break

events = call("/cdp/events?tabId=%s&limit=3000" % tab).get("events") or []
ws = [e for e in events if "WebSocket" in (e.get("method") or "")]
print("websocket events:", len(ws))
for e in ws[:8]:
    m = e["method"]
    p = e.get("params") or {}
    if m == "Network.webSocketCreated":
        print("[CREATED]", p.get("url"))
    elif m == "Network.webSocketFrameReceived":
        d = (p.get("response") or {})
        print("[RECV] opcode=%s len=%d" % (d.get("opcode"), len(d.get("payloadData") or "")))
    elif m == "Network.webSocketFrameSent":
        d = (p.get("response") or {})
        print("[SENT] opcode=%s data=%s" % (d.get("opcode"), (d.get("payloadData") or "")[:100]))

# 网络聚合里找 ws 行
net = call("/network?tabId=%s&limit=200" % tab)
for it in (net.get("items") or []):
    u = it.get("url", "")
    if "webcast" in u or "im/push" in u:
        print("NETROW", it.get("type"), it.get("status"), u[:160])

call("/close", {"tabId": tab})
