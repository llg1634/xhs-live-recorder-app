import json, sys, time, urllib.request

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
BASE = "http://127.0.0.1:17368"
PAGE = "https://www.xiaohongshu.com/livestream/570501740524334550"

HOOK = r"""
(function(){
  if (window.__wsHooked) return 'already';
  window.__wsHooked = true;
  window.__ws = [];
  var OWS = window.WebSocket;
  function WS(u, p){
    try { window.__ws.push({url: String(u), t: Date.now()}); } catch(e){}
    return new OWS(u, p);
  }
  WS.prototype = OWS.prototype;
  WS.CONNECTING = 0; WS.OPEN = 1; WS.CLOSING = 2; WS.CLOSED = 3;
  window.WebSocket = WS;
  return 'hooked';
})();
"""


def call(path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    headers = {"content-type": "application/json"} if body is not None else {}
    req = urllib.request.Request(BASE + path, data=data, headers=headers,
                                 method="POST" if body is not None else "GET")
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode())


def ev(tab, expr):
    r = call("/eval", {"tabId": tab, "expression": expr})
    for res in (r.get("results") or []):
        return (res.get("result") or {}).get("value")
    return None


r = call("/open", {"url": "about:blank", "active": True})
tab = r.get("tabId") or (r.get("tab") or {}).get("id")
print("tab:", tab)

# 1) 先验证 hook 在普通页面是否生效
print("install:", ev(tab, HOOK))
print("test ws:", ev(tab, "(function(){ try { new WebSocket('wss://echo.websocket.events'); } catch(e) { return 'err:'+e.message } return JSON.stringify(window.__ws || []) })()"))

# 2) 导航到直播间，hook 会随文档重建消失，所以用 addScriptToEvaluateOnNewDocument 注入
call("/cdp", {"tabId": tab, "method": "Page.addScriptToEvaluateOnNewDocument", "params": {"source": HOOK}})
call("/cdp", {"tabId": tab, "method": "Page.navigate", "params": {"url": PAGE}})
time.sleep(16)

print("hooked?", ev(tab, "window.__wsHooked === true"))
print("ws list:", ev(tab, "JSON.stringify(window.__ws || [])"))

# 3) 检查 iframe / worker 痕迹
print("iframes:", ev(tab, "document.querySelectorAll('iframe').length"))
print("workers?", ev(tab, "typeof Worker"))
print("video:", ev(tab, "JSON.stringify((function(){var v=document.querySelector('video');return v?{src:(v.src||'').slice(0,80),rs:v.readyState,w:v.videoWidth}:null})())"))

call("/close", {"tabId": tab})
