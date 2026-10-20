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

for rid in ("29952.297", "29952.223"):
    try:
        d = call("/network/detail?tabId=%s&requestId=%s" % (TAB, rid))
    except Exception as e:
        print(rid, "detail error:", e); continue
    blob = json.dumps(d, ensure_ascii=False)
    print(rid, "len:", len(blob))
    item = d.get("item") or d.get("request") or {}
    print("  url:", item.get("url"))
    print("  type:", item.get("type"), "status:", item.get("status"), "bytes:", item.get("encodedDataLength"))
    # find the requestWillBeSent event to grab headers
    events = d.get("events") or d.get("rawEvents") or []
    print("  events:", len(events))
    for e in events[:2]:
        print("   ev:", json.dumps(e, ensure_ascii=False)[:800])
    print("-" * 90)
