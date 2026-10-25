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
time.sleep(12)

js = r"""
(() => {
  const out = {};
  const st = window.__INITIAL_STATE__;
  if (st) {
    out.keys = Object.keys(st).slice(0, 40);
    const walk = (obj, path, depth) => {
      if (!obj || depth > 3) return;
      for (const k of Object.keys(obj)) {
        const v = obj[k];
        if (typeof v === 'string' && v.includes('.flv')) { out.flv = out.flv || []; out.flv.push([path + '.' + k, v.slice(0, 300)]); }
        if (Array.isArray(v) && v.length && typeof v[0] === 'object' && depth < 2) walk(v[0], path + '.' + k + '[0]', depth + 1);
        else if (v && typeof v === 'object' && depth < 2) walk(v, path + '.' + k, depth + 1);
      }
    };
    walk(st, 'state', 0);
  }
  return out;
})()
"""
res = call("/eval", {"tabId": tab, "expression": js})
print(json.dumps(res, ensure_ascii=False)[:2000])
call("/close", {"tabId": tab})
