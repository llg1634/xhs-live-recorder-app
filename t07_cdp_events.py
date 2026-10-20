import json, sys, urllib.request

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
BASE = "http://127.0.0.1:17368"
TAB = 101606499

def get(path):
    with urllib.request.urlopen(BASE + path, timeout=60) as r:
        return json.loads(r.read().decode())

raw = get("/cdp/events?tabId=%s&limit=2000" % TAB)
blob = json.dumps(raw, ensure_ascii=False)
print("events payload chars:", len(blob), "| keys:", list(raw.keys()))
events = raw.get("events") or raw.get("items") or []
print("event count:", len(events))
hits = [e for e in events if ".flv" in json.dumps(e, ensure_ascii=False)]
print("flv hits:", len(hits))
for e in hits[:5]:
    print(json.dumps(e, ensure_ascii=False)[:1500])
    print("-" * 80)

# also look for Network.requestWillBeSent method names present
from collections import Counter
c = Counter(e.get("method") or e.get("name") for e in events if isinstance(e, dict))
print(c.most_common(15))
