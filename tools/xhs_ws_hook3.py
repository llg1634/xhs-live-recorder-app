import json, sys, time, urllib.request, urllib.error

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
BASE = "http://127.0.0.1:17368"
PAGE = "https://www.xiaohongshu.com/livestream/570501740524334550"


def call(path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    headers = {"content-type": "application/json"} if body is not None else {}
    req = urllib.request.Request(BASE + path, data=data, headers=headers,
                                 method="POST" if body is not None else "GET")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        print("HTTP", e.code, "on", path, "->", e.read().decode()[:300])
        return {}


def ev(tab, expr):
    r = call("/eval", {"tabId": tab, "expression": expr})
    for res in (r.get("results") or []):
        return (res.get("result") or {}).get("value")
    return None


r = call("/open", {"url": PAGE, "active": False})
tab = r.get("tabId") or (r.get("tab") or {}).get("id")
print("tab:", tab)
print("basic eval:", ev(tab, "1+1"))

HOOK = """
window.__wsHooked = false; window.__ws = []; window.__workers = [];
(function(){
  var OWS = window.WebSocket;
  function WS(u, p){ try { window.__ws.push(String(u)); } catch(e){} return new OWS(u, p); }
  WS.prototype = OWS.prototype;
  window.WebSocket = WS;
  window.__wsHooked = true;
  var OW = window.Worker;
  if (OW) {
    function W(src, opt){ try { window.__workers.push(String(src).slice(0,200)); } catch(e){} return new OW(src, opt); }
    W.prototype = OW.prototype;
    window.Worker = W;
  }
  return 'ok';
})();
"""
print("install:", ev(tab, HOOK))
print("self-test:", ev(tab, "(function(){ try { new WebSocket('wss://echo.websocket.events'); } catch(e) { return 'err:'+e.message; } return JSON.stringify({ws: window.__ws}); })()"))

call("/reload", {"tabId": tab, "bypassCache": False})
time.sleep(15)
print("after reload hooked:", ev(tab, "window.__wsHooked"))
print("ws:", ev(tab, "JSON.stringify(window.__ws || [])"))
print("workers:", ev(tab, "JSON.stringify(window.__workers || [])"))

call("/close", {"tabId": tab})
