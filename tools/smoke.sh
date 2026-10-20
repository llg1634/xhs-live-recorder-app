#!/usr/bin/env bash
# tools/smoke.sh —— 启动 App → 等待 → 截图 → 导出崩溃日志。
#
# 用法：
#   tools/smoke.sh                 # 标签默认 smoke_<时间戳>
#   tools/smoke.sh home            # -> verify/shots/home.png + verify/logs/home_*.{log,txt}
#
# 环境变量：
#   WAIT_SECONDS=12                启动后等待秒数
#
# 产物：
#   verify/shots/<tag>.png         启动后截图（已校验 PNG 魔数）
#   verify/logs/<tag>_logcat.txt   本次启动后的完整 logcat（清空后抓取）
#   verify/logs/<tag>_crash.txt    FATAL EXCEPTION / E/flutter 等崩溃摘要（可能为空）
#   verify/logs/<tag>_summary.txt  启动状态、PID、前台 Activity、崩溃判定
#
# 退出码：0=启动成功且未发现崩溃；3=启动异常或发现崩溃。

set -euo pipefail
# shellcheck source=tools/_common.sh
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

TAG="${1:-smoke_$(date +%Y%m%d_%H%M%S)}"
TAG="$(basename "${TAG%.png}")"
WAIT_SECONDS="${WAIT_SECONDS:-12}"
SHOTS="$ROOT/verify/shots"
LOGS="$ROOT/verify/logs"
mkdir -p "$SHOTS" "$LOGS"

SHOT="$SHOTS/${TAG}.png"
FULL_LOG="$LOGS/${TAG}_logcat.txt"
CRASH_LOG="$LOGS/${TAG}_crash.txt"
SUMMARY="$LOGS/${TAG}_summary.txt"

require_device
: >"$SUMMARY"

log() { echo "$@" | tee -a "$SUMMARY"; }

log "== smoke ${TAG} @ $(date '+%F %T') =="
log "serial : $SERIAL"
log "package: $PKG"
log "android: $("$ADB" -s "$SERIAL" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r') (sdk $("$ADB" -s "$SERIAL" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r'))"
log "model  : $("$ADB" -s "$SERIAL" shell getprop ro.product.model 2>/dev/null | tr -d '\r') $("$ADB" -s "$SERIAL" shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')"

log ""
log "== 1) 唤醒/解锁 =="
adb_s shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
adb_s shell wm dismiss-keyguard >/dev/null 2>&1 || true
sleep 1

log ""
log "== 2) 清空 logcat、冷启动 =="
adb_s logcat -c >/dev/null 2>&1 || true
START_OUT="$(adb_s shell am start -W -n "$ACTIVITY" 2>&1 | tr -d '\r' || true)"
printf '%s\n' "$START_OUT" | sed 's/^/  /' | tee -a "$SUMMARY"
START_STATUS="$(printf '%s\n' "$START_OUT" | awk -F': *' '/^Status:/{print $2; exit}')"
START_ACTIVITY="$(printf '%s\n' "$START_OUT" | awk -F': *' '/^Activity:/{print $2; exit}')"

log ""
log "== 3) 等待 ${WAIT_SECONDS}s 让 Flutter 首帧/权限弹窗出现 =="
sleep "$WAIT_SECONDS"

log ""
log "== 4) 进程与前台窗口 =="
PID="$(adb_s shell pidof "$PKG" 2>/dev/null | tr -d '\r' | tr -d '\n')"
if [ -z "$PID" ]; then
  # Android 9 无 pidof 时兜底用 ps
  PID="$(adb_s shell ps -A 2>/dev/null | tr -d '\r' | awk -v p="$PKG" '$0 ~ p {print $2; exit}')"
fi
log "pid    : ${PID:-<无进程>}"
FOCUS="$(adb_s shell dumpsys window windows 2>/dev/null | tr -d '\r' | grep -E 'mCurrentFocus|mFocusedApp' | head -2 || true)"
printf '%s\n' "$FOCUS" | sed 's/^/  /' | tee -a "$SUMMARY"

log ""
log "== 5) 截图 =="
if take_shot "$SHOT" 2>&1 | tee -a "$SUMMARY"; then :; else
  log "[smoke] 截图失败"
fi

log ""
log "== 6) 导出 logcat 与崩溃摘要 =="
adb_s logcat -d -v threadtime 2>/dev/null | tr -d '\r' >"$FULL_LOG" || true
log "完整日志: $FULL_LOG ($(wc -l <"$FULL_LOG" | tr -d ' ') 行)"

{
  grep -n -E 'FATAL EXCEPTION|E/flutter|Dart Error|Unhandled Exception|Force finishing|ANR in|signal [0-9]+ \(SIG' "$FULL_LOG" || true
} >"$CRASH_LOG"
# 附带崩溃点后 50 行上下文（stack trace）
if [ -s "$CRASH_LOG" ]; then
  {
    echo ""
    echo "==== 崩溃上下文（FATAL/E-flutter 后 60 行）===="
    awk '/FATAL EXCEPTION|E\/flutter|Unhandled Exception|Force finishing/ {n=60} n>0 {print; n--}' "$FULL_LOG"
  } >>"$CRASH_LOG"
fi
CRASH_HITS="$(grep -cE 'FATAL EXCEPTION|E/flutter|Unhandled Exception|Force finishing|ANR in' "$FULL_LOG" 2>/dev/null || true)"
CRASH_HITS="${CRASH_HITS:-0}"
log "崩溃行数: $CRASH_HITS （摘要: $CRASH_LOG）"
if [ -s "$CRASH_LOG" ]; then
  log "---- 崩溃摘要（前 20 行）----"
  head -n 20 "$CRASH_LOG" | sed 's/^/  /' | tee -a "$SUMMARY"
fi

log ""
log "== 7) 结论 =="
VERDICT_OK=1
if [ "$START_STATUS" != "ok" ]; then
  log "❌ am start Status=$START_STATUS（期望 ok）"
  VERDICT_OK=0
fi
if [ -z "$PID" ]; then
  log "❌ 启动后进程不存在（可能闪退）"
  VERDICT_OK=0
fi
if ! printf '%s' "$FOCUS" | grep -q "$PKG"; then
  log "⚠️ 前台窗口不是 $PKG（可能有权限弹窗/崩溃对话框）"
fi
if [ "$CRASH_HITS" -gt 0 ]; then
  log "❌ 发现崩溃/Flutter 异常日志 $CRASH_HITS 行"
  VERDICT_OK=0
fi
if [ "$VERDICT_OK" -eq 1 ]; then
  log "✅ 启动成功：Status=ok, pid=${PID}, 截图=$(basename "$SHOT"), 未发现崩溃日志"
  exit 0
fi
exit 3
