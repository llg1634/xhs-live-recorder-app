import re, sys, urllib.request, concurrent.futures

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36")
PAGE = "https://www.xiaohongshu.com/livestream/570501740524334550"


def get(url, timeout=40):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Referer": PAGE})
    return urllib.request.urlopen(req, timeout=timeout).read().decode("utf-8", "replace")


html = get(PAGE)
scripts = sorted(set(re.findall(r'https://fe-static\.xhscdn\.com/[^"\s]+?\.js', html)))
print("scripts:", len(scripts))


def find_apppush(url):
    try:
        body = get(url)
    except Exception as e:
        return None
    if "apppush-rws" in body:
        return (url, body)
    return None


hit = None
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
    for res in ex.map(find_apppush, scripts):
        if res:
            hit = res
            break
if not hit:
    print("not found")
    sys.exit(1)

url, body = hit
open("tools/_xhs_vendor.js", "w", encoding="utf-8").write(body)
print("saved:", url, len(body))

for key in ("apppush-rws", "socketId", "subscribe", "/rwp"):
    print("\n########", key, "hits:", body.count(key))
    for m in list(re.finditer(re.escape(key), body))[:2]:
        s = max(0, m.start() - 400)
        print(body[s:m.start() + 700].replace("\n", " ")[:1100])
        print("-----")
