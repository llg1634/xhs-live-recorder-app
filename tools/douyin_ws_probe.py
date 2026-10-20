import json, sys, time, urllib.request, base64

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
BASE = "http://127.0.0.1:17368"
PAGE = "https://www.douyin.com/follow/live/346761239651?anchor_id=7457358305455981625"


def call(path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    headers = {"content-type": "application/json"} if body is not None else {}
    req = urllib.request.Request(BASE + path, data=data, headers=headers,
                                 method="POST" if body is not None else "GET")
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode())


print("health:", call("/health").get("ok"))
r = call("/open", {"url": PAGE, "active": True})
tab = r.get("tabId") or (r.get("tab") or {}).get("id")
print("tab:", tab)
time.sleep(18)

ev = call("/cdp/events?tabId=%s&limit=4000" % tab)
events = ev.get("events") or []
print("events:", len(events))

frames = [e for e in events if e.get("method") == "Network.webSocketFrameReceived"]
sent = [e for e in events if e.get("method") == "Network.webSocketFrameSent"]
print("recv frames:", len(frames), "sent:", len(sent))

for e in sent[:3]:
    p = (e.get("params") or {}).get("response") or {}
    print("SENT opcode=%s len=%d data=%s" % (p.get("opcode"), len(p.get("payloadData") or ""),
                                             (p.get("payloadData") or "")[:200]))

for i, e in enumerate(frames[:6]):
    p = (e.get("params") or {}).get("response") or {}
    data = p.get("payloadData") or ""
    print("\nRECV#%d opcode=%s len=%d head=%s" % (i, p.get("opcode"), len(data), data[:120]))
    if p.get("opcode") == 2:
        raw = base64.b64decode(data)
        print("  decoded bytes=%d hex=%s" % (len(raw), raw[:48].hex()))

# 页面是否有评论 DOM
js = r"""(function(){
  var v = document.querySelector('video');
  var txt = document.body ? document.body.innerText.slice(0,300) : '';
  return JSON.stringify({video: v ? {rs: v.readyState, w: v.videoWidth} : null,
                         text: txt, url: location.href});
})()"""
try:
    r2 = call("/eval", {"tabId": tab, "expression": js})
    for res in (r2.get("results") or []):
        val = (res.get("result") or {}).get("value")
        if val:
            print("\nPAGE:", json.loads(val)["url"])
            print("video:", json.loads(val)["video"])
            print("text:", json.loads(val)["text"][:200].replace("\n", " | "))
except Exception as e:
    print("eval error:", e)

call("/close", {"tabId": tab})
