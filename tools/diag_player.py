import json, sys, time, urllib.request, urllib.parse

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
BASE = "http://127.0.0.1:17368"
TID = sys.argv[1] if len(sys.argv) > 1 else "8a6c5f0e-6159-43c1-9675-c1b33dd4e3cc"
PAGE = "http://127.0.0.1:17346/player.html?src=%s&title=live-test" % urllib.parse.quote("/live/%s.flv" % TID)


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
call("/console/start", {"tabId": tab})
time.sleep(15)

js = r"""(function(){
  var v = document.querySelector('video');
  var out = {
    text: (document.body ? document.body.innerText : '').slice(0, 300),
    video: v ? {cur: v.currentTime, rs: v.readyState, ns: v.networkState,
                paused: v.paused, err: v.error ? {code: v.error.code, msg: v.error.message} : null,
                w: v.videoWidth, h: v.videoHeight,
                buffered: v.buffered.length ? [v.buffered.start(0), v.buffered.end(0)] : null} : null,
    ms: (function(){ try { return v && v.src ? v.src.slice(0,40) : null; } catch(e){ return null; } })(),
    state: window.__playerState ? JSON.stringify(window.__playerState) : null
  };
  return JSON.stringify(out);
})()"""
ev = call("/eval", {"tabId": tab, "expression": js})
for res in (ev.get("results") or []):
    val = (res.get("result") or {}).get("value")
    if val:
        print(json.dumps(json.loads(val), ensure_ascii=False, indent=1))

print("=== console ===")
try:
    con = call("/console?tabId=%s&limit=80" % tab)
    items = con.get("items") or con.get("messages") or []
    for it in items[-30:]:
        print(it.get("level"), str(it.get("text"))[:220])
except Exception as e:
    print("console error:", e)

print("=== network flv ===")
try:
    net = call("/network?tabId=%s&limit=200" % tab)
    for it in (net.get("items") or []):
        u = it.get("url", "")
        if ".flv" in u or "live/" in u:
            print(it.get("status"), it.get("encodedDataLength"), u[:120])
except Exception as e:
    print("net error:", e)

call("/close", {"tabId": tab})
