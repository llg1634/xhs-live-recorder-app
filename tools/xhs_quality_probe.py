import json, sys, time, urllib.request

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
BASE = "http://127.0.0.1:17368"
PAGE = "https://www.xiaohongshu.com/livestream/570511686529001102"


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
time.sleep(12)

net = call("/network?tabId=%s&limit=500" % tab)
items = net.get("items") or []
print("rows:", len(items))
hits = [it for it in items if ".flv" in (it.get("url") or "") or "live-source" in (it.get("url") or "")]
print("flv-ish:", len(hits))
for it in hits[:10]:
    print(it.get("type"), it.get("status"), (it.get("url") or "")[:220])

# 页面内探测 player 配置里的流地址
probe = call("/eval", {"tabId": tab, "expression": """
(() => {
  const out = [];
  document.querySelectorAll('video').forEach(v => out.push({src: v.currentSrc || v.src, w: v.videoWidth, h: v.videoHeight}));
  const st = window.__INITIAL_STATE__ ? JSON.stringify(window.__INITIAL_STATE__).slice(0, 0) : '';
  return {videos: out, hasState: !!window.__INITIAL_STATE__};
})()
"""})
print("eval:", json.dumps(probe)[:600])
call("/close", {"tabId": tab})
