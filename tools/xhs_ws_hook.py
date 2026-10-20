import json, sys, time, urllib.request

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
BASE = "http://127.0.0.1:17368"
ROOM = "570501740524334550"
PAGE = "https://www.xiaohongshu.com/livestream/%s" % ROOM

HOOK = r"""
(function(){
  if (window.__wsHooked) return;
  window.__wsHooked = true;
  window.__ws = [];
  var OWS = window.WebSocket;
  function WS(u, p){
    try { window.__ws.push({url: String(u), protocols: p || null, t: Date.now()}); } catch(e){}
    return new OWS(u, p);
  }
  WS.prototype = OWS.prototype;
  WS.CONNECTING = 0; WS.OPEN = 1; WS.CLOSING = 2; WS.CLOSED = 3;
  window.WebSocket = WS;
})();
"""


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
print("inject:", call("/cdp", {"tabId": tab, "method": "Page.addScriptToEvaluateOnNewDocument",
                               "params": {"source": HOOK}}).get("ok"))
call("/reload", {"tabId": tab, "bypassCache": True})
time.sleep(14)

ev = call("/eval", {"tabId": tab, "expression": "JSON.stringify({ws:(window.__ws||[]), url:location.href})"})
for res in (ev.get("results") or []):
    v = (res.get("result") or {}).get("value")
    if v:
        d = json.loads(v)
        print("page:", d["url"][:100])
        for w in d["ws"]:
            print("WS URL:", w["url"])

call("/close", {"tabId": tab})
