import struct, sys, time, urllib.request
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOM = "570501740524334550"
UA_ANDROID = ("Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 "
              "(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36")
UA_DESKTOP = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
              "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36")
UA_IOS = ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 "
          "(KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1")


def grab(url, ua, seconds=5, max_bytes=3_000_000):
    req = urllib.request.Request(url, headers={"User-Agent": ua, "Referer": "https://www.xiaohongshu.com/"})
    buf = bytearray()
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=12) as r:
            while len(buf) < max_bytes and time.time() - t0 < seconds:
                c = r.read(65536)
                if not c:
                    break
                buf.extend(c)
    except Exception as e:
        return bytes(buf), str(e)[:60]
    return bytes(buf), "ok"


def codec_info(buf):
    """返回 (videocodecid, 首帧视频 tag 前 8 字节 hex, 是否有 sequence header)"""
    if len(buf) < 13 or buf[:3] != b"FLV":
        return None
    pos = struct.unpack(">I", buf[5:9])[0] + 4
    seq = None
    first_video = None
    while pos + 11 <= len(buf):
        ttype = buf[pos] & 0x1F
        size = int.from_bytes(buf[pos+1:pos+4], "big")
        body = buf[pos+11:pos+11+size]
        if len(body) < size:
            break
        if ttype == 9 and len(body) >= 2:
            codecid = body[0] & 0x0F
            avc_packet = body[1]
            if avc_packet == 0:
                seq = codecid
            if first_video is None:
                first_video = body[:8].hex()
        pos += 11 + size + 4
    return seq, first_video


for name, ua in (("android", UA_ANDROID), ("desktop", UA_DESKTOP), ("ios", UA_IOS)):
    for suffix in ("", "_hcv5401"):
        url = f"https://live-source-play.xhscdn.com/live/{ROOM}{suffix}.flv"
        buf, status = grab(url, ua)
        info = codec_info(buf)
        codec = {7: "H.264", 12: "HEVC/H.265", None: "?"}.get(info[0] if info else None, str(info[0] if info else None))
        print(f"UA={name:8s} suffix={suffix or '<none>':10s} bytes={len(buf):8d} codecid={info[0] if info else None} ({codec}) first_video_tag={info[1] if info else '-'}")
