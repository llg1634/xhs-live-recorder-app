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

call("/cdp/events/clear", {})
print("reload:", call("/reload", {"tabId": TAB, "bypassCache": True}), flush=True)
time.sleep(9)

raw = call("/cdp/events?tabId=%s&limit=5000" % TAB)
events = raw.get("events") or []
print("events:", len(events))

seen = {}
for e in events:
    if e.get("method") != "Network.requestWillBeSent":
        continue
    req = (e.get("params") or {}).get("request") or {}
    u = req.get("url", "")
    if not u:
        continue
    t = (e.get("params") or {}).get("type", "")
    if ".flv" in u.lower() or "live" in t.lower() or ".m3u8" in u.lower():
        seen[u] = (t, req.get("headers"), req.get("method"))
print("candidate stream requests:", len(seen))
for u, (t, h, m) in seen.items():
    print("TYPE:", t, "METHOD:", m)
    print("URL:", u[:500])
    print("HEADERS:", json.dumps(h, ensure_ascii=False)[:600])
    print("-" * 90)

# dump all request URLs (short)
print("\nALL requestWillBeSent URLs (unique, 60):")
allu = []
for e in events:
    if e.get("method") != "Network.requestWillBeSent":
        continue
    u = ((e.get("params") or {}).get("request") or {}).get("url", "")
    if u and u not in allu:
        allu.append(u)
for u in allu[:60]:
    print("  " + u[:200])
