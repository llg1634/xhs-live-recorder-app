import json, sys, time, urllib.request

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
BASE = "http://127.0.0.1:17368"
TAB = 101606499

HOOK = r"""
(function(){
  if (window.__cap) return;
  var cap = window.__cap = [];
  var of = window.fetch;
  window.fetch = function(input, init){
    try {
      var u = (typeof input === 'string') ? input : (input && input.url);
      cap.push({k:'fetch', u:String(u), method:(init&&init.method)||'GET',
                headers: init && init.headers ? JSON.stringify(init.headers).slice(0,400) : '',
                credentials: init && init.credentials, mode: init && init.mode});
    } catch(e){}
    return of.apply(this, arguments);
  };
  var XO = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function(m,u){
    try { cap.push({k:'xhr', u:String(u), method:String(m)}); } catch(e){}
    return XO.apply(this, arguments);
  };
  var OWS = window.WebSocket;
  function WS(u,p){ try{ cap.push({k:'ws', u:String(u)}); }catch(e){} return new OWS(u,p); }
  WS.prototype = OWS.prototype; WS.CONNECTING=0; WS.OPEN=1; WS.CLOSING=2; WS.CLOSED=3;
  window.WebSocket = WS;
  var OES = window.EventSource;
  if (OES){ function ES(u,c){ try{ cap.push({k:'es', u:String(u)}); }catch(e){} return new OES(u,c); } ES.prototype=OES.prototype; window.EventSource=ES; }
})();
"""

def call(path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    headers = {"content-type": "application/json"} if body is not None else {}
    req = urllib.request.Request(BASE + path, data=data, headers=headers,
                                 method="POST" if body is not None else "GET")
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode())

print("inject:", call("/cdp", {"tabId": TAB, "method": "Page.addScriptToEvaluateOnNewDocument",
                               "params": {"source": HOOK}}))
print("reload:", call("/reload", {"tabId": TAB, "bypassCache": True}))
time.sleep(12)

r = call("/eval", {"tabId": TAB, "expression": "JSON.stringify({url:location.href, cap:(window.__cap||[]), video:(function(v){return v?{src:(v.currentSrc||v.src||'').slice(0,200),paused:v.paused,t:v.currentTime,dw:v.videoWidth}:null})(document.querySelector('video'))})"})
for res in (r.get("results") or []):
    v = (res.get("result") or {}).get("value")
    if not v:
        continue
    d = json.loads(v)
    print("PAGE:", d["url"][:120])
    print("VIDEO:", d["video"])
    print("CAPTURED:", len(d["cap"]))
    for c in d["cap"]:
        u = c.get("u", "")
        mark = "  <<< FLV" if ".flv" in u.lower() else ""
        print("  %-6s %-6s %s%s" % (c.get("k"), c.get("method"), u[:260], mark))
