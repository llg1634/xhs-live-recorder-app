#!/usr/bin/env bash
set -u
FLV="https://live-source-play.xhscdn.com/live/570501740524334550_hcv5401.flv?userId=6591818f00000000220140e4&abr_pts=-3000"
DESKTOP_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
MOBILE_UA="Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
OUT="D:/renwu/261020小红书直播录制"

probe () {
  local name="$1"; shift
  echo "----- $name -----"
  curl -sS -m 8 -D /tmp/h.txt "$@" -o /tmp/b.bin -w 'http=%{http_code} size=%{size_download} ctype=%{content_type}\n' || true
  grep -iE "^(HTTP/|content-type|content-length|accept-ranges|cache|expires)" /tmp/h.txt | tr -d '\r' | head -8
  if [ -s /tmp/b.bin ]; then
    echo -n "first bytes: "; head -c 16 /tmp/b.bin | od -An -tx1 | head -2
    head -c 3 /tmp/b.bin | grep -q "FLV" && echo ">>> FLV header OK" || echo ">>> not FLV"
  fi
  echo
}

probe "desktop UA + referer (8s)" -A "$DESKTOP_UA" -H "Referer: https://www.xiaohongshu.com/" "$FLV"
probe "mobile UA only (8s)" -A "$MOBILE_UA" "$FLV"
probe "no UA (8s)" -H "User-Agent:" "$FLV"

echo "----- saved 6s sample with mobile UA -----"
curl -sS -m 6 -A "$MOBILE_UA" "$FLV" -o "$OUT/flv_mobile_6s.bin" -w 'http=%{http_code} size=%{size_download}\n'
ls -l "$OUT/flv_mobile_6s.bin" 2>/dev/null | awk '{print "bytes:", $5}'
head -c 3 "$OUT/flv_mobile_6s.bin" | grep -q FLV && echo "FLV header OK" || echo "no FLV header"
