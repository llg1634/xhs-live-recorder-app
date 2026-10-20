import struct, sys, time, urllib.request

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"


def grab(url, seconds=6, max_bytes=3_000_000):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Referer": "https://www.xiaohongshu.com/"})
    buf = bytearray()
    t0 = time.time()
    code = None
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            code = r.status
            while len(buf) < max_bytes and time.time() - t0 < seconds:
                chunk = r.read(65536)
                if not chunk:
                    break
                buf.extend(chunk)
    except urllib.error.HTTPError as e:
        return bytes(buf), "HTTPError", e.code
    except Exception as e:
        return bytes(buf), type(e).__name__, code
    return bytes(buf), "ok", code


def amf0(data, pos):
    t = data[pos]; pos += 1
    if t == 0x00:
        return struct.unpack(">d", data[pos:pos+8])[0], pos + 8
    if t == 0x01:
        return bool(data[pos]), pos + 1
    if t == 0x02:
        ln = struct.unpack(">H", data[pos:pos+2])[0]; pos += 2
        return data[pos:pos+ln].decode("utf-8", "replace"), pos + ln
    if t == 0x03:
        obj = {}
        while True:
            klen = struct.unpack(">H", data[pos:pos+2])[0]; pos += 2
            if klen == 0 and data[pos] == 0x09:
                pos += 1; break
            k = data[pos:pos+klen].decode("utf-8", "replace"); pos += klen
            v, pos = amf0(data, pos); obj[k] = v
        return obj, pos
    if t in (0x05, 0x06):
        return None, pos
    raise ValueError("amf type %d" % t)


def parse(buf):
    if len(buf) < 13 or buf[:3] != b"FLV":
        return {"flv": False, "bytes": len(buf)}
    pos = struct.unpack(">I", buf[5:9])[0] + 4
    tags = 0; first = last = None; meta = None; v = 0; a = 0
    while pos + 11 <= len(buf):
        ttype = buf[pos] & 0x1F
        size = int.from_bytes(buf[pos+1:pos+4], "big")
        ts = int.from_bytes(buf[pos+4:pos+8], "big") & 0xFFFFFF
        body = buf[pos+11:pos+11+size]
        if len(body) < size:
            break
        if first is None: first = ts
        last = ts; tags += 1
        if ttype == 9: v += 1
        elif ttype == 8: a += 1
        elif ttype == 18 and meta is None:
            try:
                _, p = amf0(body, 0)
                m, _ = amf0(body, p)
                meta = m if isinstance(m, dict) else {}
            except Exception:
                meta = {}
        pos += 11 + size + 4
    res = {"flv": True, "bytes": len(buf), "tags": tags, "video": v, "audio": a,
           "first_ts": first, "last_ts": last}
    if meta:
        res["size"] = "%sx%s" % (meta.get("width"), meta.get("height"))
        res["fps"] = meta.get("framerate")
        res["vdr"] = meta.get("videodatarate")
    return res


for room in ("570504953736339047", "570501740524334550"):
    for suf in ("", "_hcv5401"):
        url = "https://live-source-play.xhscdn.com/live/%s%s.flv" % (room, suf)
        buf, status, code = grab(url)
        info = parse(buf)
        print("room=%s suf=%-9s status=%-9s code=%-4s bytes=%-8d flv=%s tags=%s v=%s a=%s ts=%s->%s %s %s %s" % (
            room, suf or "<none>", status, code, info["bytes"], info.get("flv"), info.get("tags"),
            info.get("video"), info.get("audio"), info.get("first_ts"), info.get("last_ts"),
            info.get("size", ""), info.get("fps", ""), info.get("vdr", "")))
