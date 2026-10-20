import re, sys, urllib.request, concurrent.futures

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36")
PAGE = "https://www.xiaohongshu.com/livestream/570501740524334550"


def get(url, timeout=20):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Referer": PAGE})
    return urllib.request.urlopen(req, timeout=timeout).read()


html = get(PAGE).decode("utf-8", "replace")
scripts = sorted(set(re.findall(r'https://fe-static\.xhscdn\.com/[^"\s]+?\.js', html)))
print("scripts in html:", len(scripts))

# 页面 HTML 里也可能直接有 ws 地址
for m in re.finditer(r'(wss?://[^"\'\\\s<>]{5,200})', html):
    print("HTML WS:", m.group(1)[:200])

found = []


def scan(url):
    try:
        body = get(url, timeout=25).decode("utf-8", "replace")
    except Exception:
        return
    for key in ("apppush-rws", "wss://", "/rwp"):
        for m in re.finditer(re.escape(key), body):
            s = max(0, m.start() - 120)
            snippet = body[s:m.start() + 220]
            found.append((url.split("/")[-1], key, snippet))
            break


with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
    list(ex.map(scan, scripts))

print("matches:", len(found))
seen = set()
for name, key, snip in found:
    sig = key + snip[:60]
    if sig in seen:
        continue
    seen.add(sig)
    print("\n---", name, "key=", key)
    print(snip.replace("\n", " ")[:340])
