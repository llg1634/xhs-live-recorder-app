#!/usr/bin/env bash
# tools/logs.sh —— 导出并过滤 logcat（flutter / AndroidRuntime / 应用包名）。
#
# 用法：
#   tools/logs.sh                     # 打印过滤后的日志到终端
#   tools/logs.sh -o verify/logs/x.log
#   tools/logs.sh -c                  # 先清空 logcat 再抓（配合复现）
#   tools/logs.sh 'SocketException'   # 追加自定义过滤正则
#
# 默认抓取并保留的行：E/flutter、I/flutter、AndroidRuntime、FATAL EXCEPTION、
# com.liquidlab.live_recorder、libc（native crash）。

set -euo pipefail
# shellcheck source=tools/_common.sh
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

CLEAR=0
OUT=""
while getopts ":co:h" opt; do
  case "$opt" in
    c) CLEAR=1 ;;
    o) OUT="$OPTARG" ;;
    h) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "未知参数 -$OPTARG" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
EXTRA_PATTERN="${1:-}"

FILTER='flutter|AndroidRuntime|com\.liquidlab\.live_recorder|FATAL EXCEPTION|libc'
if [ -n "$EXTRA_PATTERN" ]; then
  FILTER="$FILTER|$EXTRA_PATTERN"
fi

require_device
if [ "$CLEAR" -eq 1 ]; then
  adb_s logcat -c
  echo "[logs] 已清空 logcat"
fi

mkdir -p "$ROOT/verify/logs"
if [ -n "$OUT" ]; then
  case "$OUT" in
    /*) ;; # 绝对路径原样使用
    *) OUT="$ROOT/$OUT" ;;
  esac
  mkdir -p "$(dirname "$OUT")"
  adb_s logcat -d -v threadtime 2>/dev/null | tr -d '\r' | grep -Ei "$FILTER" >"$OUT" || true
  echo "[logs] 写入 $OUT ($(wc -l <"$OUT" | tr -d ' ') 行)"
  echo "[logs] 最近 30 行："
  tail -n 30 "$OUT" || true
else
  adb_s logcat -d -v threadtime 2>/dev/null | tr -d '\r' | grep -Ei "$FILTER" || true
fi
