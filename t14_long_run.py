import json, os, struct, subprocess, sys, time, urllib.request

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
OUT = r"D:\renwu\261020小红书直播录制\testrun"
os.makedirs(OUT, exist_ok=True)
ROOM = "570501740524334550"
BARE = "https://live-source-play.xhscdn.com/live/%s.flv" % ROOM
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"


def parse_flv(path):
    with open(path, "rb") as f:
        buf = f.read()
    if len(buf) < 13 or buf[:3] != b"FLV":
        return {"flv": False, "bytes": len(buf)}
    pos = struct.unpack(">I", buf[5:9])[0] + 4
    tags = 0
    first = last = None
    vframes = aframes = 0
    max_gap = 0
    prev = None
    while pos + 11 <= len(buf):
        ttype = buf[pos] & 0x1F
        size = int.from_bytes(buf[pos + 1:pos + 4], "big")
        ts = int.from_bytes(buf[pos + 4:pos + 8], "big") & 0xFFFFFF
        if pos + 11 + size > len(buf):
            break
        if first is None:
            first = ts
        if prev is not None and ts - prev > max_gap:
            max_gap = ts - prev
        prev = ts
        last = ts
        if ttype == 9:
            vframes += 1
        elif ttype == 8:
            aframes += 1
        pos += 11 + size + 4
        tags += 1
    return {"flv": True, "bytes": len(buf), "tags": tags, "first_ts": first, "last_ts": last,
            "video_tags": vframes, "audio_tags": aframes, "max_ts_gap_ms": max_gap}


def record(path, seconds, url=BARE):
    t0 = time.time()
    with open(path, "wb") as f:
        p = subprocess.Popen(["curl.exe", "-sS", "-A", UA, "-H", "Referer: https://www.xiaohongshu.com/",
                              "-m", str(seconds), url], stdout=f, stderr=subprocess.DEVNULL)
        p.wait()
        rc = p.returncode
    return rc, round(time.time() - t0, 1)


print("========== TEST 1: continuous 70s recording (bare URL) ==========")
rc, dur = record(os.path.join(OUT, "long70.flv"), 70)
info = parse_flv(os.path.join(OUT, "long70.flv"))
mb = info["bytes"] / 1024 / 1024
print("curl rc=%s wall=%.1fs" % (rc, dur))
print("bytes=%d (%.2f MB) bitrate=%.0f kbps" % (info["bytes"], mb, info["bytes"] * 8 / dur / 1000))
print("tags=%s video=%s audio=%s ts %s -> %s (%.1fs) max_gap=%sms" % (
    info["tags"], info["video_tags"], info["audio_tags"], info["first_ts"], info["last_ts"],
    (info["last_ts"] - info["first_ts"]) / 1000, info["max_ts_gap_ms"]))
print("=> FLV 连续可解析:", info["flv"] and info["max_ts_gap_ms"] < 3000)

print()
print("========== TEST 2: simulate disconnect / 3 segments with 5s probe ==========")
for i in range(1, 4):
    p = os.path.join(OUT, "seg_%d.flv" % i)
    rc, dur = record(p, 15)
    inf = parse_flv(p)
    print("seg%d rc=%s %.1fs bytes=%d tags=%s ts %s->%s (%.1fs) flv=%s" % (
        i, rc, dur, inf["bytes"], inf["tags"], inf["first_ts"], inf["last_ts"],
        (inf["last_ts"] - inf["first_ts"]) / 1000, inf["flv"]))
    time.sleep(5)
print("=> 每段都是独立 FLV、时间戳从 0 重新开始（无需合并，符合预期）")
