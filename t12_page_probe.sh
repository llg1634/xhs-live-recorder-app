#!/usr/bin/env bash
set -u
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
MUA="Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
OUT="D:/renwu/261020小红书直播录制"
PAGE="https://www.xiaohongshu.com/livestream/dynpathScH7KeS3/570501740524334550?timestamp=1792491036496&share_source=share_link&share_source_id=&source=share_out_of_app&host_id=6523a46a000000002b003f5e&xsec_token=UB2aG8c2aLqBvaNocWK_fpaSIofw4Vw-zpkwkWslBCigBThnR7ajl2cXGAinFMZE8-&xsec_source=app_share&share_id=bc54e330e15e4e7babb61a18089e0692"

echo "===== 1. page HTML: desktop UA ====="
curl -sS -m 20 -A "$UA" "$PAGE" -o "$OUT/page_desktop.html" -w 'http=%{http_code} size=%{size_download}\n'
echo "-- occurrences of key markers --"
for k in "live-source-play" ".flv" "streamUrl" "hcv" "xsec_token" "room_id"; do
  printf "%-20s %s\n" "$k" "$(grep -o "$k" "$OUT/page_desktop.html" 2>/dev/null | wc -l)"
done
echo "-- any flv-ish URL in HTML --"
grep -oE 'https:[^"'"'"' <>]{0,160}\.flv[^"'"'"' <>]{0,200}' "$OUT/page_desktop.html" | head -5

echo
echo "===== 2. page HTML: mobile UA ====="
curl -sS -m 20 -A "$MUA" "$PAGE" -o "$OUT/page_mobile.html" -w 'http=%{http_code} size=%{size_download}\n'
echo "-- any flv-ish URL in HTML --"
grep -oE 'https:[^"'"'"' <>]{0,160}\.flv[^"'"'"' <>]{0,200}' "$OUT/page_mobile.html" | head -5
echo "-- mobile page: is it an app-open landing? --"
grep -oiE '(open ?app|打开小红书|app_share|download)' "$OUT/page_mobile.html" | sort | uniq -c | head

echo
echo "===== 3. stream name suffix probing ====="
for suffix in "" "_hcv5400" "_hcv5401" "_hcv5402" "_hcv540" "_hd" "_origin"; do
  u="https://live-source-play.xhscdn.com/live/570501740524334550${suffix}.flv"
  code=$(curl -sS -m 5 -o /tmp/p.bin -w '%{http_code}' "$u" 2>/dev/null || echo "ERR")
  size=$(stat -c%s /tmp/p.bin 2>/dev/null || echo 0)
  hdr=$(head -c 3 /tmp/p.bin 2>/dev/null | tr -d '\0')
  printf "  %-12s http=%-6s bytes=%-8s hdr=%s\n" "${suffix:-<none>}" "$code" "$size" "$hdr"
done
