#!/usr/bin/env bash
# 后台断流自愈回归测试（可重复执行）
#
# 正常模式（后台断网 N 秒，验证自动续录）：
#   tools/netdrop_test.sh 300 "https://www.xiaohongshu.com/livestream/570525164416427805"
#   或 tools/netdrop_test.sh --mode normal 300 "<url>"
#
# 404 模式（直播真的下播，验证宽限后 completed）：
#   tools/netdrop_test.sh --mode 404 60 "https://www.xiaohongshu.com/livestream/570523767964339555"
#
# 为什么不用 `svc wifi disable`：这台模拟器的 adb 也走 wlan0，一关 wifi adb 就
# 会 offline。脚本优先用 iptables owner match 按 App UID 丢包；该内核没有 owner
# 模块时自动退回按 TCP/UDP 80+443 丢包（adb 走 21503/5555，不受影响）。
# 所有 adb shell 都套 host 侧 `timeout 10`，避免任何远程命令卡死整个测试。
set -uo pipefail

# Git Bash/MSYS 会把 /storage/... 参数改写成 Windows 路径；必须禁用。
export MSYS2_ARG_CONV_EXCL='*'
export MSYS_NO_PATHCONV=1

ADB="${ADB:-/d/dev/android-sdk/platform-tools/adb}"
SERIAL="${SERIAL:-127.0.0.1:21503}"
PKG="com.liquidlab.live_recorder"
DEFAULT_ROOM="https://www.xiaohongshu.com/livestream/570525164416427805"
PORT="${PORT:-17346}"
OUT_DIR="${OUT_DIR:-tools/netdrop_logs}"

MODE="normal"
DOWN_SECONDS="60"
ROOM="$DEFAULT_ROOM"
if [ "${1:-}" = "--mode" ]; then
  MODE="${2:-normal}"
  DOWN_SECONDS="${3:-60}"
  ROOM="${4:-$DEFAULT_ROOM}"
else
  DOWN_SECONDS="${1:-60}"
  ROOM="${2:-$DEFAULT_ROOM}"
  MODE="${3:-normal}"
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$OUT_DIR/netdrop-$STAMP.log"
APP_UID=""
TASK_STARTED=0
LATEST=""
DROP_MODE=""
PREV_DIRS=""

mkdir -p "$OUT_DIR"

say() { echo "[netdrop] $*" | tee -a "$LOG"; }
fail() {
  echo "[netdrop][FAIL] $*" | tee -a "$LOG" >&2
  dump_diagnostics 2>/dev/null || true
  echo "[netdrop] 日志: $LOG" >&2
  exit 1
}

# 所有 adb shell 统一 10s 超时：中文目录名一旦被 shell 拆错，cat/read 可能
# 继承 stdin 永远挂着（19:24 那轮卡死 25 分钟就是这么来的）。
adb_shell() { timeout 10 "$ADB" -s "$SERIAL" shell "$@"; }

debug_json() {
  curl -s --max-time 3 "http://127.0.0.1:$PORT/debug" 2>/dev/null
}

# 当前 /debug 里所有任务的 outputDir（每行一个）。
debug_dirs() {
  debug_json | python -X utf8 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit
for t in data.get("tasks", []):
    p = t.get("outputDir") or ""
    if p:
        print(p)
'
}

# 读取 `state|bytes|segments|error`；目标路径通过环境变量传，避免 argv 里的
# 中文被 shell/MSYS 改写。
debug_task() {
  debug_json | WANT_DIR="$1" python -X utf8 -c '
import json, os, sys
want = os.environ.get("WANT_DIR", "")
try:
    data = json.load(sys.stdin)
except Exception:
    print("no-json")
    raise SystemExit
for t in data.get("tasks", []):
    if t.get("outputDir") == want:
        print("%s|%s|%s|%s" % (t.get("state"), t.get("bytes"), t.get("segments"), t.get("error")))
        break
else:
    print("missing")
'
}

# 从 /debug 里找本轮新建的任务目录（不在 PREV_DIRS 里），不再用 ls -dt 拼中文路径。
new_task_dir() {
  debug_json | PREV_DIRS="$PREV_DIRS" python -X utf8 -c '
import json, os, sys
prev = set(filter(None, os.environ.get("PREV_DIRS", "").splitlines()))
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit
for t in data.get("tasks", []):
    p = t.get("outputDir") or ""
    state = t.get("state") or ""
    if p and p not in prev and state in ("resolving", "recording", "reconnecting"):
        print(p)
        break
'
}

# 失败/卡住时把现场写进日志：/debug 原始 JSON、目录、文件列表、logcat 关键行。
dump_diagnostics() {
  {
    echo "----- 诊断 $(date +%T) -----"
    echo "[debug raw]"
    debug_json || echo "curl failed"
    echo
    echo "[dirs from /debug]"
    debug_dirs
    if [ -n "${LATEST:-}" ]; then
      echo "[LATEST] $LATEST"
      adb_shell ls -la "$LATEST" 2>/dev/null
    fi
    echo "[logcat flutter rec/launch/task]"
    timeout 10 "$ADB" -s "$SERIAL" logcat -d -s flutter:V 2>/dev/null |
      grep -E '\[rec\]|\[launch\]|\[task|\[restore\]' | head -40
  } | tee -a "$LOG" >/dev/null
}

# 断网开关：owner match 优先，失败则按 Web 端口。
drop_network_start() {
  local uid="$1"
  if adb_shell iptables -I OUTPUT -m owner --uid-owner "$uid" -j DROP >/dev/null 2>&1; then
    DROP_MODE="owner"
    return 0
  fi
  # 先置 ports，保证第 2 条插入失败时 cleanup 也知道要删哪些规则。
  DROP_MODE="ports"
  for p in 80 443; do
    adb_shell iptables -I OUTPUT -p tcp --dport "$p" -j DROP >/dev/null 2>&1 || return 1
    adb_shell iptables -I OUTPUT -p udp --dport "$p" -j DROP >/dev/null 2>&1 || return 1
  done
  return 0
}

drop_network_stop() {
  case "$DROP_MODE" in
    owner)
      [ -n "$APP_UID" ] &&
        adb_shell iptables -D OUTPUT -m owner --uid-owner "$APP_UID" -j DROP >/dev/null 2>&1 || true
      ;;
    ports)
      for p in 80 443; do
        adb_shell iptables -D OUTPUT -p tcp --dport "$p" -j DROP >/dev/null 2>&1 || true
        adb_shell iptables -D OUTPUT -p udp --dport "$p" -j DROP >/dev/null 2>&1 || true
      done
      ;;
  esac
  DROP_MODE=""
}

cleanup() {
  # 无论 Ctrl-C 还是断言失败，都必须精确删掉本轮插入的规则。
  if [ -n "$DROP_MODE" ]; then
    drop_network_stop || true
    say "cleanup: 网络规则已清理"
  fi
  if [ "$TASK_STARTED" = "1" ]; then
    adb_shell am start -n "$PKG/.MainActivity" --es action stopall >/dev/null 2>&1 || true
    sleep 2
  fi
}
trap cleanup EXIT INT TERM

start_app() {
  PREV_DIRS="$(debug_dirs)"
  adb_shell am force-stop "$PKG" >/dev/null 2>&1 || true
  sleep 2
  timeout 10 "$ADB" -s "$SERIAL" logcat -c >/dev/null 2>&1 || true
  adb_shell am start -n "$PKG/.MainActivity" --es autostart "$ROOM" >/dev/null 2>&1 ||
    fail "启动 App / 自动录制失败"
  TASK_STARTED=1

  LATEST=""
  for _ in $(seq 1 45); do
    LATEST="$(new_task_dir)"
    [ -n "$LATEST" ] && break
    sleep 2
  done
  [ -n "$LATEST" ] || fail "没有找到本轮新录像目录（看 /debug）"
  say "本轮任务: $LATEST"
}

wait_by_debug() {
  local desc="$1" timeout_s="$2" check="$3"
  local deadline=$((SECONDS + timeout_s))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if eval "$check"; then return 0; fi
    sleep 2
  done
  fail "等待超时（${timeout_s}s）：$desc"
}

run_normal() {
  say "设备=$SERIAL 模式=normal 断网=${DOWN_SECONDS}s 房间=$ROOM"
  start_app

  # 等首段数据；20s 没数据就把现场写进日志。
  local start=$SECONDS
  local dbg="" state="" bytes=""
  local ok=0 dumped=0
  while [ $((SECONDS - start)) -lt 90 ]; do
    dbg="$(debug_task "$LATEST")"
    state="$(echo "$dbg" | cut -d'|' -f1)"
    bytes="$(echo "$dbg" | cut -d'|' -f2)"
    if [ "$state" = "recording" ] && [ "${bytes:-0}" -gt 100000 ]; then
      ok=1
      break
    fi
    if [ $((SECONDS - start)) -ge 20 ] && [ "$dumped" = "0" ]; then
      say "启动 20s 仍无首段数据，写入诊断: debug=$dbg"
      dump_diagnostics
      dumped=1
    fi
    sleep 2
  done
  [ "$ok" = "1" ] || fail "等待超时（90s）：开始录制并写入首段数据"
  local before_kb
  before_kb="$(adb_shell du -sk "$LATEST" 2>/dev/null | cut -f1 | tr -d '\r')"
  say "断网前: dir=$LATEST size=${before_kb}KB debug=$(debug_task "$LATEST")"

  # 用户报障场景：App 在后台。
  adb_shell input keyevent KEYCODE_HOME >/dev/null 2>&1 || true
  sleep 2
  APP_UID="$(adb_shell stat -c %u "/data/data/$PKG" 2>/dev/null | tr -d '\r')"
  [ -n "$APP_UID" ] || fail "取不到 App UID"
  say "断网开始: uid=$APP_UID"
  drop_network_start "$APP_UID" || fail "iptables 规则插入失败（需要 root）"
  say "断网规则模式: $DROP_MODE"

  sleep "$((DOWN_SECONDS / 2))"
  say "断网中: debug=$(debug_task "$LATEST")"

  say "恢复网络: 删除 iptables 规则 (mode=$DROP_MODE)"
  drop_network_stop
  APP_UID=""

  wait_by_debug "网络恢复后自动续录出新分段" 180 \
    '[ "$(debug_task "$LATEST" | cut -d"|" -f1)" = "recording" ] && [ "$(debug_task "$LATEST" | cut -d"|" -f3)" -ge 2 ] && adb_shell ls "$LATEST" | grep -q "part02.flv"'

  local after_kb final_debug final_state
  after_kb="$(adb_shell du -sk "$LATEST" 2>/dev/null | cut -f1 | tr -d '\r')"
  final_debug="$(debug_task "$LATEST")"
  final_state="$(echo "$final_debug" | cut -d'|' -f1)"
  timeout 10 "$ADB" -s "$SERIAL" logcat -d -s flutter:V >"$LOG.raw" 2>/dev/null || true
  grep -E '\[rec\]|\[task .*state=' "$LOG.raw" | tee -a "$LOG" >/dev/null || true
  {
    echo "----- 结果 -----"
    echo "dir=$LATEST"
    echo "before=${before_kb}KB after=${after_kb}KB"
    echo "debug=$final_debug"
    echo "files:"
    adb_shell ls -l "$LATEST" 2>/dev/null
  } | tee -a "$LOG"

  [ "$final_state" = "recording" ] || fail "恢复后状态不是 recording（实际 $final_state）"
  [ "${after_kb:-0}" -gt "${before_kb:-0}" ] || fail "文件总大小没有增长（$before_kb → $after_kb KB）"
  [ "$(grep -c '\[rec\] part[0-9]* connecting' "$LOG.raw" 2>/dev/null || true)" -ge 2 ] ||
    fail "logcat 里没有多次重连记录"
  grep -q '\[task .*\] state=completed' "$LOG.raw" && fail "日志出现 state=completed（直播被误判结束）"
  say "PASS：后台断网 ${DOWN_SECONDS}s 后自动续录，状态=$final_state，${before_kb}KB→${after_kb}KB"
}

# 404 模式：不要求首段数据，只验证「reconnecting 保持到 120s → 宽限后 completed」。
run_404() {
  say "设备=$SERIAL 模式=404 房间=$ROOM"
  start_app
  local start=$SECONDS
  local seen=0 at120="" dbg="" state=""
  while [ $((SECONDS - start)) -lt 300 ]; do
    dbg="$(debug_task "$LATEST")"
    state="$(echo "$dbg" | cut -d'|' -f1)"
    [ "$state" = "reconnecting" ] && seen=1
    if [ -z "$at120" ] && [ $((SECONDS - start)) -ge 120 ]; then
      at120="$state"
    fi
    case "$state" in
      completed) break ;;
      interrupted) fail "404 模式：任务被标 interrupted，不是 completed ($dbg)" ;;
      error) fail "404 模式：任务进入 error 终态 ($dbg)" ;;
    esac
    sleep 5
  done
  local final_debug
  final_debug="$(debug_task "$LATEST")"
  [ "$seen" = "1" ] || fail "404 模式：从未进入 reconnecting（$final_debug）"
  [ "$at120" = "reconnecting" ] || fail "404 模式：120s 时状态应为 reconnecting，实际 $at120"
  [ "$(echo "$final_debug" | cut -d'|' -f1)" = "completed" ] ||
    fail "404 模式：宽限期后没有 completed（$final_debug）"
  {
    echo "----- 404 结果 -----"
    echo "dir=$LATEST"
    echo "120s_state=$at120"
    echo "final=$final_debug"
    timeout 10 "$ADB" -s "$SERIAL" logcat -d -s flutter:V 2>/dev/null |
      grep -E '\[task .*state=|\[rec\]' | tail -40
  } | tee -a "$LOG"
  say "PASS：404 宽限路径 completed，120s 时仍为 reconnecting"
}

timeout 10 "$ADB" connect "$SERIAL" >/dev/null 2>&1 || true
[ "$(adb_shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] ||
  fail "模拟器未就绪：$SERIAL"
timeout 10 "$ADB" -s "$SERIAL" forward "tcp:$PORT" "tcp:$PORT" >/dev/null 2>&1 ||
  fail "adb forward tcp:$PORT 失败"

case "$MODE" in
  404) run_404 ;;
  normal) run_normal ;;
  *) fail "未知模式：$MODE（只支持 normal / 404）" ;;
esac
