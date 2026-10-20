#!/usr/bin/env bash
set -u
OUT="D:/renwu/261020小红书直播录制"
FLV="https://live-source-play.xhscdn.com/live/570501740524334550_hcv5401.flv?userId=6591818f00000000220140e4&abr_pts=-3000"
BARE="https://live-source-play.xhscdn.com/live/570501740524334550_hcv5401.flv"
OTHERID="https://live-source-play.xhscdn.com/live/570501740524334550_hcv5401.flv?userId=000000000000000000000000&abr_pts=-3000"

echo "===== A. bare URL (no query) ====="
curl -sS -m 6 -o /tmp/a.bin -w 'http=%{http_code} size=%{size_download}\n' "$BARE" || true
head -c 3 /tmp/a.bin | od -An -c | head -1
echo "===== B. forged userId ====="
curl -sS -m 6 -o /tmp/b.bin -w 'http=%{http_code} size=%{size_download}\n' "$OTHERID" || true
head -c 3 /tmp/b.bin | od -An -c | head -1

echo
echo "===== C. record seg1: 20s ====="
curl -sS -m 20 -o "$OUT/seg1.flv" "$FLV" -w 'http=%{http_code} size=%{size_download}\n' || true
ls -l "$OUT/seg1.flv" 2>/dev/null | awk '{print "seg1 bytes:", $5}'

echo "===== D. sleep 5s then reconnect SAME url: 20s ====="
sleep 5
curl -sS -m 20 -o "$OUT/seg2.flv" "$FLV" -w 'http=%{http_code} size=%{size_download}\n' || true
ls -l "$OUT/seg2.flv" 2>/dev/null | awk '{print "seg2 bytes:", $5}'
echo -n "seg2 header: "; head -c 3 "$OUT/seg2.flv" | od -An -c | head -1

echo
echo "===== E. tooling ====="
command -v ffprobe >/dev/null 2>&1 && echo "ffprobe: $(command -v ffprobe)" || echo "ffprobe: missing"
command -v ffmpeg  >/dev/null 2>&1 && echo "ffmpeg:  $(command -v ffmpeg)"  || echo "ffmpeg: missing"
