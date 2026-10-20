import json, sys, time, urllib.request, urllib.parse

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

BASE = "http://127.0.0.1:17368"
RESOLVED = ("https://www.xiaohongshu.com/livestream/dynpathScH7KeS3/570501740524334550"
            "?timestamp=1792491036496&share_source=share_link&share_source_id="
            "&source=share_out_of_app&host_id=6523a46a000000002b003f5e"
            "&xsec_token=UB2aG8c2aLqBvaNocWK_fpaSIofw4Vw-zpkwkWslBCigBThnR7ajl2cXGAinFMZE8-"
            "&xsec_source=app_share&share_id=bc54e330e15e4e7babb61a18089e0692")
TAB = 101606499

def call(path, body=None, method=None):
    data = None
    headers = {}
    if body is not None:
        data = json.dumps(body).encode()
        headers["content-type"] = "application/json"
    req = urllib.request.Request(BASE + path, data=data, headers=headers,
                                 method=method or ("POST" if body is not None else "GET"))
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode())

def ev(expr):
    r = call("/eval", {"tabId": TAB, "expression": expr})
    out = []
    for res in (r.get("results") or []):
        v = (res.get("result") or {}).get("value")
        if v is not None:
            out.append(v)
    return out

def main():
    print("== network/start ==", call("/network/start", {"tabId": TAB}))
    print("== reload ==", call("/reload", {"tabId": TAB, "bypassCache": True}))
    time.sleep(10)

    state = ev(r"""(function(){
      const out = {url:location.href, title:document.title};
      const v = document.querySelector('video');
      out.video = v ? {src:(v.currentSrc||v.src||'').slice(0,300), paused:v.paused, dw:v.videoWidth, dh:v.videoHeight, t:v.currentTime, rs:v.readyState} : null;
      out.perfFlv = performance.getEntriesByType('resource').map(e=>e.name).filter(n=>/\.flv|m3u8|live-source|stream/i.test(n)).slice(0,20);
      out.login = !!document.cookie.match(/web_session/);
      out.text = (document.body?document.body.innerText:'').slice(0,500);
      return JSON.stringify(out);
    })()""")
    print("== page state ==")
    for s in state:
        print(s)

    print("== network rows ==")
    net = call("/network?tabId=%s&limit=500" % TAB)
    rows = net.get("rows") or net.get("requests") or net.get("entries") or []
    print("row count:", len(rows), "| keys:", list(net.keys()))
    for row in rows:
        u = row.get("url", "") or ""
        print("  [%s] %s %s" % (row.get("status"), row.get("type"), u[:200]))

if __name__ == "__main__":
    main()
