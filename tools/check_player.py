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
print("opened tab:", tab, PAGE)
time.sleep(8)

js = r"""(function(){
  var v = document.querySelector('video');
  var out = {
    url: location.href,
    title: document.title,
    text: (document.body ? document.body.innerText : '').slice(0, 400),
    hasFlv: typeof flvjs !== 'undefined',
    support: (typeof flvjs !== 'undefined') ? flvjs.isSupported() : null,
    state: window.__playerState || window.PV && window.PV.state ? (window.__playerState || window.PV.state()) : null,
    video: v ? {cur: v.currentTime, rs: v.readyState, paused: v.paused,
                err: v.error ? v.error.code : null,
                w: v.videoWidth, h: v.videoHeight} : null
  };
  return JSON.stringify(out);
})()"""
ev = call("/eval", {"tabId": tab, "expression": js})
for res in (ev.get("results") or []):
    val = (res.get("result") or {}).get("value")
    if val:
        print(json.dumps(json.loads(val), ensure_ascii=False, indent=1))

call("/close", {"tabId": tab})
print("closed")
