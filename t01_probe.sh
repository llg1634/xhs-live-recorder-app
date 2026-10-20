#!/usr/bin/env bash
# Preliminary probe for XHS live link variants
set -u
SHORT="https://xhslink.com/o/9iND1710iyA"
WEB="https://www.xiaohongshu.com/livestream/570501740524334550?track_id=live_lar_chat%406ad73d5c73776a001580ebf0&source=web_feed&xsec_token=ABFPAw1xLyH75xq7XlL13aqeF3m-785EZlevfaqqDczCjs129fmPuteyteUj0cVug"
DESKTOP_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
MOBILE_UA="Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

echo "=============== 1) SHORT LINK redirect chain (desktop UA) ==============="
curl -sS -m 25 -L -o /dev/null -w 'final_url=%{url_effective}\nhttp_code=%{http_code}\nnum_redirects=%{num_redirects}\n' \
  -A "$DESKTOP_UA" "$SHORT"

echo
echo "=============== 2) SHORT LINK raw headers, no follow (desktop) ==============="
curl -sS -m 25 -D - -o /dev/null -A "$DESKTOP_UA" "$SHORT" | tr -d '\r'

echo
echo "=============== 3) SHORT LINK redirect chain (mobile UA) ==============="
curl -sS -m 25 -L -o /dev/null -w 'final_url=%{url_effective}\nhttp_code=%{http_code}\nnum_redirects=%{num_redirects}\n' \
  -A "$MOBILE_UA" "$SHORT"

echo
echo "=============== 4) SHORT LINK location header (mobile UA) ==============="
curl -sS -m 25 -D - -o /dev/null -A "$MOBILE_UA" "$SHORT" | tr -d '\r'
