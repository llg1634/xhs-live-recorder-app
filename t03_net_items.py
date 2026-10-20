import json, sys, time, urllib.request

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
BASE = "http://127.0.0.1:17368"
TAB = 101606499

def call(path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    headers = {"content-type": "application/json"} if body is not None else {}
    req = urllib.request.Request(BASE + path, data=data, headers=headers,
                                 method="POST" if body is not None else "GET")
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode())

net = call("/network?tabId=%s&limit=500" % TAB)
items = net.get("items") or []
print("total:", net.get("total"), "matched:", net.get("matched"), "returned:", len(items))
print("-" * 100)
for it in items:
    u = it.get("url", "") or ""
    print("[%s] %s %s bytes=%s" % (it.get("status"), it.get("type"), it.get("method"), it.get("encodedDataLength")))
    print("     " + u[:300])
