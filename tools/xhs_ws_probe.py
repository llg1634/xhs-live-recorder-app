import json, sys, time, urllib.request, urllib.parse

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


print("health:", call("/health").get("ok"))
r = call("/open", {"url": PAGE, "active": False})
tab = r.get("tabId") or (r.get("tab") or {}).get("id")
print("tab:", tab)
call("/cdp/events/clear", {})
call("/network/start", {"tabId": tab})
time.sleep(1)
call("/reload", {"tabId": tab, "bypassCache": False})
print("waiting 15s for ws handshake + frames...")
time.sleep(15)

ev = call("/cdp/events?tabId=%s&limit=5000" % tab)
events = ev.get("events") or []
print("events:", len(events))

ws_created = [e for e in events if e.get("method") == "Network.webSocketCreated"]
print("\n=== webSocketCreated ===")
for e in ws_created:
    print(json.dumps(e.get("params"), ensure_ascii=False)[:600])

hs = [e for e in events if e.get("method") == "Network.webSocketHandshakeResponseReceived"]
print("\n=== handshake responses ===")
for e in hs:
    p = e.get("params") or {}
    resp = p.get("response") or {}
    print("url:", resp.get("url"))
    print("status:", resp.get("status"), "headers:", json.dumps(resp.get("headers"), ensure_ascii=False)[:500])
    if resp.get("requestHeaders"):
        print("reqHeaders:", json.dumps(resp.get("requestHeaders"), ensure_ascii=False)[:800])

frames = [e for e in events if e.get("method") == "Network.webSocketFrameReceived"]
print("\n=== frames received:", len(frames), "===")
for e in frames[:6]:
    p = e.get("params") or {}
    resp = p.get("response") or {}
    payload = resp.get("payloadData") or ""
    print("opcode=%s len=%d head=%s" % (resp.get("opcode"), len(payload), payload[:300].replace("\n", " ")))

call("/close", {"tabId": tab})
print("\nclosed")
