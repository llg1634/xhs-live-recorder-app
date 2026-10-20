import json, sys, time, urllib.request

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
BASE = "http://127.0.0.1:17368"
PAGE = "https://www.xiaohongshu.com/livestream/570501740524334550"

SETUP = r"""
window.__cmt = window.__cmt || {events: [], candidates: []};
(function(){
  var out = [];
  // 找所有可能承载评论的容器：文本较多、子节点多、class 含 comment/chat/message
  var all = document.querySelectorAll('*');
  for (var i = 0; i < all.length; i++) {
    var el = all[i];
    var cls = (el.className && el.className.toString) ? el.className.toString() : '';
    if (!/comment|chat|message|danmu|barrage|live-?feed|note/i.test(cls)) continue;
    if (el.children.length < 3) continue;
    out.push({cls: cls.slice(0, 120), kids: el.children.length,
              text: (el.innerText || '').slice(0, 120).replace(/\n/g, ' | ')});
    if (out.length > 12) break;
  }
  window.__cmt.candidates = out;

  // 用 MutationObserver 统计 20 秒内新增文本
  var obs = new MutationObserver(function(muts){
    for (var m of muts) {
      for (var n of m.addedNodes) {
        var t = (n.innerText || n.textContent || '').trim();
        if (t && t.length < 120) {
          window.__cmt.events.push({t: Date.now(), text: t.slice(0, 100)});
          if (window.__cmt.events.length > 200) window.__cmt.events.shift();
        }
      }
    }
  });
  obs.observe(document.body, {childList: true, subtree: true});
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


r = call("/open", {"url": PAGE, "active": True})
tab = r.get("tabId") or (r.get("tab") or {}).get("id")
print("tab:", tab)
time.sleep(10)

ev = call("/eval", {"tabId": tab, "expression": SETUP})
for res in (ev.get("results") or []):
    print("setup:", (res.get("result") or {}).get("value"))

time.sleep(22)

ev = call("/eval", {"tabId": tab, "expression":
    "JSON.stringify({candidates: window.__cmt.candidates, count: window.__cmt.events.length, sample: window.__cmt.events.slice(-15)})"})
for res in (ev.get("results") or []):
    v = (res.get("result") or {}).get("value")
    if v:
        d = json.loads(v)
        print("\n=== 候选容器 ===")
        for c in d["candidates"]:
            print("kids=%-3s cls=%s" % (c["kids"], c["cls"]))
            print("      text:", c["text"][:100])
        print("\n=== 20 秒内新增文本节点:", d["count"], "===")
        for s in d["sample"]:
            print("  ", s["text"])

call("/close", {"tabId": tab})
