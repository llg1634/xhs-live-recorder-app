import json, sys, time, urllib.request

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
BASE = "http://127.0.0.1:17368"
PAGE = "https://live.douyin.com/346761239651"

HOOK = r"""
window.__hooked = false; window.__wsUrls = []; window.__frames = [];
(function(){
  var OWS = window.WebSocket;
  function WS(u, p) {
    try { window.__wsUrls.push(String(u)); } catch(e){}
    var s = new OWS(u, p);
    try {
      s.addEventListener('message', function(ev){
        var d = ev.data;
        var info = {t: typeof d};
        try {
          if (d instanceof ArrayBuffer) { info.len = d.byteLength;
            var u8 = new Uint8Array(d.slice(0,16)); info.hex = Array.from(u8).map(b=>b.toString(16).padStart(2,'0')).join('');
          } else { info.len = String(d).length; info.head = String(d).slice(0,120); }
        } catch(e) { info.err = String(e); }
        window.__frames.push(info);
        if (window.__frames.length > 50) window.__frames.shift();
      });
    } catch(e){}
    return s;
  }
  WS.prototype = OWS.prototype;
  WS.CONNECTING=0; WS.OPEN=1; WS.CLOSING=2; WS.CLOSED=3;
  window.WebSocket = WS;
  window.__hooked = true;
})();
'ok'
"""


def call(path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    headers = {"content-type": "application/json"} if body is not None else {}
    req = urllib.request.Request(BASE + path, data=data, headers=headers,
                                 method="POST" if body is not None else "GET")
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode())


r = call("/open", {"url": "about:blank", "active": True})
tab = r.get("tabId") or (r.get("tab") or {}).get("id")
print("tab:", tab)

inj = call("/devtools/send", {"tabId": tab, "method": "Page.addScriptToEvaluateOnNewDocument",
                              "params": {"source": HOOK}})
print("inject:", json.dumps(inj, ensure_ascii=False)[:200])

nav = call("/devtools/send", {"tabId": tab, "method": "Page.navigate", "params": {"url": PAGE}})
print("nav:", json.dumps(nav, ensure_ascii=False)[:160])

time.sleep(16)

for expr in ["window.__hooked", "JSON.stringify(window.__wsUrls||[])", "JSON.stringify((window.__frames||[]).slice(0,5))", "JSON.stringify((window.__frames||[]).length)"]:
    try:
        ev = call("/devtools/evaluate", {"tabId": tab, "expression": expr})
        val = None
        for res in (ev.get("results") or []):
            val = (res.get("result") or {}).get("value")
        print(expr, "=>", str(val)[:300])
    except Exception as e:
        print(expr, "ERR", e)

call("/close", {"tabId": tab})
