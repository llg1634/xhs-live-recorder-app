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
  const ls = window.__INITIAL_STATE__ && window.__INITIAL_STATE__.liveStream;
  if (!ls) return {err: 'no liveStream'};
  const flat = [];
  const walk = (v, path, depth) => {
    if (depth > 4 || v == null) return;
    if (typeof v === 'string') {
      if (v.includes('flv') || v.includes('stream') || v.includes('quality')) flat.push([path, v.slice(0, 200)]);
      return;
    }
    if (typeof v === 'number' || typeof v === 'boolean') { flat.push([path, v]); return; }
    if (Array.isArray(v)) { v.slice(0, 6).forEach((x, i) => walk(x, path + '[' + i + ']', depth + 1)); return; }
    if (typeof v === 'object') { Object.keys(v).slice(0, 40).forEach(k => walk(v[k], path + '.' + k, depth + 1)); }
  };
  walk(ls, 'liveStream', 0);
  return {keys: Object.keys(ls), flat: flat.slice(0, 120)};
})()
"""
res = call("/eval", {"tabId": tab, "expression": js})
val = res.get("results", [{}])[0].get("result", {}).get("value")
print(json.dumps(val, ensure_ascii=False, indent=1)[:4000])
call("/close", {"tabId": tab})
