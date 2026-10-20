import json, struct, sys, time, urllib.request, urllib.error

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
ROOM = "570501740524334550"
BASE = "https://live-source-play.xhscdn.com/live/%s" % ROOM

def grab(url, seconds=6, max_bytes=4_000_000):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Referer": "https://www.xiaohongshu.com/"})
    buf = bytearray()
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            while len(buf) < max_bytes and time.time() - t0 < seconds:
                chunk = r.read(65536)
                if not chunk:
                    break
                buf.extend(chunk)
    except Exception as e:
        return bytes(buf), "%s" % type(e).__name__, getattr(e, "code", None)
    return bytes(buf), "ok", 200

def amf0_parse(data, pos):
    """Minimal AMF0 parser: returns (value, pos)."""
    t = data[pos]; pos += 1
    if t == 0x00:
        v = struct.unpack(">d", data[pos:pos+8])[0]; return float(v), pos+8
    if t == 0x01:
        return bool(data[pos]), pos+1
    if t == 0x02:
        ln = struct.unpack(">H", data[pos:pos+2])[0]; pos += 2
        return data[pos:pos+ln].decode("utf-8", "replace"), pos+ln
    if t == 0x03:
        obj = {}
        while True:
            klen = struct.unpack(">H", data[pos:pos+2])[0]; pos += 2
            if klen == 0 and data[pos] == 0x09:
                pos += 1; break
            k = data[pos:pos+klen].decode("utf-8", "replace"); pos += klen
            v, pos = amf0_parse(data, pos)
            obj[k] = v
        return obj, pos
    if t == 0x05:
        return None, pos
    if t == 0x06:
        return None, pos
    if t == 0x08:
        pos += 4
        obj = {}
        while True:
            klen = struct.unpack(">H", data[pos:pos+2])[0]; pos += 2
            if klen == 0 and data[pos] == 0x09:
                pos += 1; break
            k = data[pos:pos+klen].decode("utf-8", "replace"); pos += klen
            v, pos = amf0_parse(data, pos)
            obj[k] = v
        return obj, pos
    raise ValueError("unsupported AMF0 type %d at %d" % (t, pos))

def parse_flv(buf):
    out = {}
    if len(buf) < 13 or buf[:3] != b"FLV":
        out["flv"] = False
        return out
    out["flv"] = True
    out["flags"] = buf[4]
    hdr_size = struct.unpack(">I", buf[5:9])[0]
    pos = hdr_size + 4
    tags = 0
    first_ts = None
    last_ts = None
    meta = None
    vres = None
    while pos + 11 <= len(buf) and tags < 400:
        tag_type = buf[pos] & 0x1F
        data_size = int.from_bytes(buf[pos+1:pos+4], "big")
        ts = int.from_bytes(buf[pos+4:pos+8], "big") & 0xFFFFFF
        body = buf[pos+11:pos+11+data_size]
        if len(body) < data_size:
            break
        if first_ts is None:
            first_ts = ts
        last_ts = ts
        tags += 1
        if tag_type == 18 and meta is None:
            try:
                name, p = amf0_parse(body, 0)
                val, p = amf0_parse(body, p)
                meta = val if isinstance(val, dict) else {}
            except Exception as e:
                meta = {"parse_error": str(e)}
        pos += 11 + data_size + 4
    out["tags"] = tags
    out["first_ts"] = first_ts
    out["last_ts"] = last_ts
    if meta:
        keep = {k: meta.get(k) for k in ("duration", "width", "height", "videodatarate",
                                         "framerate", "videocodecid", "audiodatarate") if k in meta}
        out["meta"] = keep
    return out

variants = ["", "_hcv5400", "_hcv5401", "_hcv5402", "_hcv540"]
print("%-10s %-6s %-9s %-6s %-6s %-6s %s" % ("suffix", "bytes", "sec", "tags", "ts_from", "ts_to", "meta"))
for suf in variants:
    url = BASE + suf + ".flv"
    buf, status, code = grab(url, seconds=6, max_bytes=4_000_000)
    info = parse_flv(buf)
    meta = info.get("meta", {})
    brief = "w=%s h=%s fr=%s vdr=%s dur=%s" % (meta.get("width"), meta.get("height"),
                                               meta.get("framerate"), meta.get("videodatarate"),
                                               meta.get("duration"))
    print("%-10s %-6d %-9s %-6s %-6s %-6s %s" % (suf or "<none>", len(buf), status,
                                                 info.get("tags"), info.get("first_ts"),
                                                 info.get("last_ts"), brief))

print()
print("== bogus room ==")
for name in ["123456789", "1", "abc"]:
    url = "https://live-source-play.xhscdn.com/live/%s.flv" % name
    buf, status, code = grab(url, seconds=5, max_bytes=1_000_000)
    info = parse_flv(buf)
    print("%-12s status=%-8s bytes=%-8d flv=%s tags=%s code=%s" % (name, status, len(buf), info.get("flv"), info.get("tags"), code))
