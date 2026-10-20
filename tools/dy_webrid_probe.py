import json, sys, time, urllib.request

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
BASE = "http://127.0.0.1:17368"
PAGE = "https://webcast.amemv.com/douyin/webcast/reflow/7698716404685966095"


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
call("/network/start", {"tabId": tab, "clear": True})
time.sleep(1)
call("/reload", {"tabId": tab})
time.sleep(10)

net = call("/network?tabId=%s&limit=300" % tab)
items = net.get("items") or []
print("rows:", len(items))
api = []
for it in items:
    u = it.get("url", "")
    if "webcast" in u or "/aweme/" in u or "room" in u:
        api.append(it)
        print(it.get("type"), it.get("status"), u[:150])

for it in api[:6]:
    rid = it.get("requestId")
    if not rid:
        continue
    try:
        body = call("/network/body?tabId=%s&requestId=%s" % (tab, rid))
        text = body.get("body") or json.dumps(body)[:200]
        if "web_rid" in str(text) or "room_id" in str(text):
            print("\n=== body of", it.get("url", "")[:100])
            s = str(text)
            idx = s.find("web_rid")
            print(s[max(0, idx-200):idx+300] if idx >= 0 else s[:400])
    except Exception as e:
        print("body err", e)

call("/close", {"tabId": tab})
