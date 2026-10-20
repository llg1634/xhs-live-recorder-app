#!/usr/bin/env bash
# tools/build.sh —— 构建 debug APK（首次约 5~10 分钟）。
#
# 用法：
#   tools/build.sh                 # cd app && flutter build apk --debug
#   tools/build.sh --verbose       # 额外参数透传给 flutter build
#
# 日志：verify/logs/build_<时间戳>.log（同时输出到终端）
# 产物：app/build/app/outputs/flutter-apk/app-debug.apk

set -euo pipefail
# shellcheck source=tools/_common.sh
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

FLUTTER="$FLUTTER_HOME/bin/flutter"
if [ ! -x "$FLUTTER" ]; then
  echo "[build] 找不到 flutter：$FLUTTER（可用 FLUTTER_HOME 覆盖）" >&2
  exit 127
fi
export PATH="$FLUTTER_HOME/bin:$(dirname "$ADB"):$PATH"

LOG_DIR="$ROOT/verify/logs"
mkdir -p "$LOG_DIR"
STAMP="$(date +%Y%m%d_%H%M%S)"
LOG="$LOG_DIR/build_$STAMP.log"

echo "[build] flutter : $($FLUTTER --version 2>/dev/null | head -1)"
echo "[build] project : $ROOT/app"
echo "[build] git HEAD: $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo n/a)"
echo "[build] log     : $LOG"
echo "[build] 开始构建（首次较慢，请耐心等待）…"

cd "$ROOT/app"
set +e
"$FLUTTER" build apk --debug "$@" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
set -e

if [ "$rc" -ne 0 ]; then
  echo "" >&2
  echo "[build] ❌ 构建失败 rc=$rc" >&2
  echo "[build] 完整日志：$LOG" >&2
  echo "[build] 末尾 40 行：" >&2
  tail -n 40 "$LOG" >&2 || true
  exit "$rc"
fi

APK="$ROOT/app/build/app/outputs/flutter-apk/app-debug.apk"
if [ ! -f "$APK" ]; then
  echo "[build] 构建返回成功但找不到 APK：$APK" >&2
  exit 1
fi

echo ""
echo "[build] ✅ 构建成功"
echo "[build] APK  : $APK"
echo "[build] 大小 : $(stat -c %s "$APK") bytes ($(du -h "$APK" | cut -f1))"
echo "[build] sha256: $(sha256sum "$APK" | cut -d' ' -f1)"
echo "[build] 日志 : $LOG"
