import json, sys, urllib.request

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
for it in items:
    if not it.get("url"):
        print(json.dumps(it, ensure_ascii=False, indent=2)[:2000])
        print("=" * 80)

print("### cdp/events sample ###")
try:
    ev = call("/cdp/events?tabId=%s&limit=30" % TAB)
    print(json.dumps(ev, ensure_ascii=False)[:3000])
except Exception as e:
    print("cdp/events error:", e)
