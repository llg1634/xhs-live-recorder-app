#!/usr/bin/env bash
set -u
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
ROOM=570501740524334550
HOST_ID=6523a46a000000002b003f5e

try () {
  local name="$1"; local url="$2"
  echo "===== $name ====="
  echo "URL: $url"
  curl -sS -m 15 -A "$UA" -H "Referer: https://www.xiaohongshu.com/" "$url" -o /tmp/api.json -w 'http=%{http_code} size=%{size_download}\n'
  head -c 900 /tmp/api.json; echo; echo
}

try "aggregate_business_info" "https://live-room.xiaohongshu.com/api/sns/red/live/web/v1/room/aggregate_business_info?room_id=$ROOM&host_id=$HOST_ID&client_type=1"
try "join_business_base_info" "https://live-room.xiaohongshu.com/api/sns/red/live/web/v1/room/join_business_base_info?room_id=$ROOM&source=web_live"
try "join_comment_info" "https://live-room.xiaohongshu.com/api/sns/red/live/web/v1/room/join_comment_info?room_id=$ROOM&source=web_live&pre_source=pc_web&track_id=&client_type=1"
