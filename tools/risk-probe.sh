#!/usr/bin/env bash
# tools/risk-probe.sh —— 小红书匿名风控压测（在 PC 上执行，模拟安卓 UA，不带 cookie / 不登录）
#
# 两组压测：
#   1) xhslink 短链连续跟随跳转 30 次（默认）：记录 HTTP 码 / 耗时 / 跳转次数 / 最终 URL；
#   2) FLV 直连连续 10 次、每次 3 秒：记录 HTTP 码 / 是否 FLV 头 / 下载速率。
#
# 产出：
#   verify/xhslink-attempts.tsv   短链每轮原始数据
#   verify/flv-attempts.tsv       FLV 每轮原始数据
#   verify/logs/xhslink-headers-{first,last}.txt  首/末轮完整响应头
#   verify/logs/xhslink-fail-*.txt                 失败现场（body 摘要）
#   verify/logs/flv-headers.txt                    每轮响应头
#   verify/risk-report.md         汇总报告（成功率、失败模式、可疑特征）
#
# 可覆盖的环境变量：
#   XHS_URL / FLV_URL / UA / XHS_ROUNDS / FLV_ROUNDS / FLV_SECONDS
#   例：FLV_ROUNDS=3 XHS_ROUNDS=5 tools/risk-probe.sh   # 小流量冒烟
#
# 流量控制：FLV 每次仅 3 秒（--max-time 3），默认 10 次；短链只请求重定向不下载正文。

# shellcheck source=tools/_common.sh
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
set +e   # 压测要容忍失败：失败本身就是结论

XHS_URL="${XHS_URL:-https://xhslink.com/o/9iND1710iyA}"
FLV_URL="${FLV_URL:-https://live-source-play.xhscdn.com/live/570501740524334550.flv}"
UA="${UA:-Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36}"
XHS_ROUNDS="${XHS_ROUNDS:-30}"
FLV_ROUNDS="${FLV_ROUNDS:-10}"
FLV_SECONDS="${FLV_SECONDS:-3}"

VERIFY="$ROOT/verify"
LOGS="$VERIFY/logs"
TMP="$VERIFY/.tmp"
XHS_TSV="$VERIFY/xhslink-attempts.tsv"
FLV_TSV="$VERIFY/flv-attempts.tsv"
REPORT="$VERIFY/risk-report.md"
FLV_HDR_ALL="$LOGS/flv-headers.txt"
mkdir -p "$LOGS"
rm -rf "$TMP"; mkdir -p "$TMP"

CURL="$(command -v curl || true)"
if [ -z "$CURL" ]; then
  echo "[risk] 找不到 curl" >&2
  exit 127
fi

START_TS="$(date '+%F %T %z')"
echo "[risk] ================= 小红书匿名风控压测 ================="
echo "[risk] 时间   : $START_TS"
echo "[risk] UA     : $UA"
echo "[risk] 短链   : $XHS_URL  (x$XHS_ROUNDS)"
echo "[risk] FLV    : $FLV_URL  (x$FLV_ROUNDS, 每次 ${FLV_SECONDS}s)"
echo "[risk] 无 cookie、无登录、不复用连接（每轮独立 curl 进程）"
echo ""

# ---------------------------------------------------------------- 公网出口（风控报告用）
PUBIP=""
for u in "https://ifconfig.me/ip" "https://api.ipify.org"; do
  PUBIP="$("$CURL" -sS -m 6 -A "$UA" "$u" 2>/dev/null | tr -d '\r\n ' | head -c 40)"
  [ -n "$PUBIP" ] && break
done
echo "[risk] 公网出口: ${PUBIP:-未知}"
echo ""

###############################################################################
# 1) xhslink 短链：连续跟随 30 次
###############################################################################
echo "[risk] ---- 1) xhslink 短链连续跟随 x$XHS_ROUNDS ----"
printf 'idx\trc\thttp_code\ttotal_s\tlookup_s\tconnect_s\tappconnect_s\tnum_redirects\tremote_ip\teffective_url\tcurl_err\n' >"$XHS_TSV"
XHS_LAST=0
for i in $(seq 1 "$XHS_ROUNDS"); do
  body="$TMP/xhs_$i.body"
  hdr="$TMP/xhs_$i.hdr"
  errf="$TMP/xhs_$i.err"
  meta="$("$CURL" -sS -L --max-redirs 10 --connect-timeout 8 --max-time 20 \
    -A "$UA" \
    -H 'Accept: */*' \
    -H 'Accept-Language: zh-CN,zh;q=0.9' \
    -D "$hdr" -o "$body" \
    -w '%{http_code}\t%{time_total}\t%{time_namelookup}\t%{time_connect}\t%{time_appconnect}\t%{num_redirects}\t%{remote_ip}\t%{url_effective}' \
    "$XHS_URL" 2>"$errf")"
  rc=$?
  IFS=$'\t' read -r code total lookup conn appconn nredir ip eff <<<"$meta"
  [ -z "${code:-}" ] && code=000
  [ -z "${total:-}" ] && total=0
  [ -z "${lookup:-}" ] && lookup=0
  [ -z "${conn:-}" ] && conn=0
  [ -z "${appconn:-}" ] && appconn=0
  [ -z "${nredir:-}" ] && nredir=0
  [ -z "${ip:-}" ] && ip=-
  [ -z "${eff:-}" ] && eff=-
  err="$(tr '\r\n\t' '   ' <"$errf" 2>/dev/null | head -c 300)"

  # 失败现场留证：非 200 或 curl 报错
  if [ "$rc" -ne 0 ] || [ "$code" != "200" ]; then
    {
      echo "round=$i rc=$rc code=$code total=$total redirects=$nredir"
      echo "effective=$eff"
      echo "curl_err=$err"
      echo "---- body(前 800 字节) ----"
      head -c 800 "$body" 2>/dev/null | tr '\r' ' '
    } >"$LOGS/xhslink-fail-r$i.txt"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$i" "$rc" "$code" "$total" "$lookup" "$conn" "$appconn" "$nredir" "$ip" "$eff" "$err" >>"$XHS_TSV"
  rm -f "$body" "$errf"
  [ "$i" -eq 1 ] && cp "$hdr" "$LOGS/xhslink-headers-first.txt"
  XHS_LAST="$i"
  rm -f "$hdr"
  if [ "$i" -eq 1 ] || [ $((i % 5)) -eq 0 ] || [ "$i" -eq "$XHS_ROUNDS" ]; then
    echo "[risk]   [$i/$XHS_ROUNDS] code=$code total=${total}s redirects=$nredir ip=$ip"
  fi
done
# 末轮响应头（单独再抓一次首跳，观察 token/cookie 是否变化）
"$CURL" -sS -L --max-redirs 10 --connect-timeout 8 --max-time 20 \
  -A "$UA" -H 'Accept: */*' -D "$LOGS/xhslink-headers-last.txt" -o /dev/null "$XHS_URL" 2>/dev/null
echo "[risk]   短链数据: $XHS_TSV"
echo ""

###############################################################################
# 2) FLV 直连：连续 10 次、每次 3 秒
###############################################################################
echo "[risk] ---- 2) FLV 直连 x$FLV_ROUNDS（每次 ${FLV_SECONDS}s）----"
printf 'idx\trc\thttp_code\tcontent_type\tsize_bytes\ttime_s\tspeed_Bps\ttime_starttransfer_s\tnum_redirects\tflv_magic\tfirst16_hex\tcurl_err\n' >"$FLV_TSV"
: >"$FLV_HDR_ALL"
for i in $(seq 1 "$FLV_ROUNDS"); do
  body="$TMP/flv_$i.bin"
  hdr="$TMP/flv_$i.hdr"
  errf="$TMP/flv_$i.err"
  meta="$("$CURL" -sS -L --max-redirs 5 --connect-timeout 8 --max-time "$FLV_SECONDS" \
    -A "$UA" \
    -H 'Accept: */*' \
    -H 'Accept-Language: zh-CN,zh;q=0.9' \
    -D "$hdr" -o "$body" \
    -w '%{http_code}\t%{time_total}\t%{size_download}\t%{speed_download}\t%{time_starttransfer}\t%{num_redirects}\t%{content_type}' \
    "$FLV_URL" 2>"$errf")"
  rc=$?
  IFS=$'\t' read -r code total size speed ttfb nredir ctype <<<"$meta"
  [ -z "${code:-}" ] && code=000
  [ -z "${total:-}" ] && total=0
  size="$(stat -c %s "$body" 2>/dev/null || echo 0)"
  [ -z "${speed:-}" ] && speed=0
  [ -z "${ttfb:-}" ] && ttfb=0
  [ -z "${nredir:-}" ] && nredir=0
  [ -z "${ctype:-}" ] && ctype=-
  err="$(tr '\r\n\t' '   ' <"$errf" 2>/dev/null | head -c 300)"

  magic=0
  first16=""
  if [ "$size" -ge 3 ]; then
    first3="$(head -c 3 "$body" | od -An -tc | tr -d ' \n')"
    case "$first3" in
      FLV*) magic=1 ;;
    esac
    first16="$(head -c 16 "$body" | od -An -tx1 | tr -d ' \n' | head -c 32)"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$i" "$rc" "$code" "$ctype" "$size" "$total" "$speed" "$ttfb" "$nredir" "$magic" "${first16:--}" "$err" >>"$FLV_TSV"

  {
    echo "########## attempt $i (rc=$rc code=$code magic=$magic size=$size) ##########"
    tr -d '\r' <"$hdr" 2>/dev/null
    echo ""
  } >>"$FLV_HDR_ALL"

  rm -f "$body" "$errf" "$hdr"
  echo "[risk]   [$i/$FLV_ROUNDS] code=$code flv_magic=$magic bytes=$size speed=$(awk -v s="$speed" 'BEGIN{printf "%.1f", s/1024}')KiB/s ttfb=${ttfb}s rc=$rc"
  sleep 0.3
done
echo "[risk]   FLV 数据: $FLV_TSV"
echo ""

###############################################################################
# 3) 生成报告
###############################################################################
END_TS="$(date '+%F %T %z')"
pick_python() {
  local c
  for c in python3 python py; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys' >/dev/null 2>&1; then
      command -v "$c"
      return 0
    fi
  done
  return 1
}
PYTHON="$(pick_python || true)"
if [ -n "$PYTHON" ]; then
  RISK_UA="$UA" RISK_XHS_URL="$XHS_URL" RISK_FLV_URL="$FLV_URL" \
  RISK_XHS_ROUNDS="$XHS_ROUNDS" RISK_FLV_ROUNDS="$FLV_ROUNDS" RISK_FLV_SECONDS="$FLV_SECONDS" \
  RISK_START="$START_TS" RISK_END="$END_TS" RISK_PUBIP="${PUBIP:-未知}" \
  RISK_XHS_HDR_FIRST="$LOGS/xhslink-headers-first.txt" \
  RISK_XHS_HDR_LAST="$LOGS/xhslink-headers-last.txt" \
  RISK_FLV_HDR="$FLV_HDR_ALL" \
    "$PYTHON" "$(to_win_path "$ROOT/tools/risk_report.py")" \
    "$(to_win_path "$XHS_TSV")" "$(to_win_path "$FLV_TSV")" "$(to_win_path "$REPORT")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "[risk] ⚠️ 报告生成失败 rc=$rc（原始数据仍在 $XHS_TSV / $FLV_TSV）" >&2
  fi
else
  echo "[risk] ⚠️ 没有 python，跳过 markdown 报告生成（原始 TSV 已保留）" >&2
  exit 4
fi

rm -rf "$TMP"
echo ""
echo "[risk] ✅ 完成，报告: $REPORT"
