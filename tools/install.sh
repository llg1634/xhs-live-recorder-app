#!/usr/bin/env bash
# tools/install.sh —— 安装 debug APK 到模拟器。
#
# 用法：
#   tools/install.sh                        # 自动选 verify/app-debug.apk 或 build 产物
#   tools/install.sh path/to/app.apk        # 指定 APK
#
# 说明：默认 adb install -r；若遇到 INSTALL_FAILED_UPDATE_INCOMPATIBLE
#       （签名不同/旧包残留），会提示可执行 uninstall 后重试。

set -euo pipefail
# shellcheck source=tools/_common.sh
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

APK="${1:-}"
if [ -z "$APK" ]; then
  for c in \
    "$ROOT/verify/app-debug.apk" \
    "$ROOT/app/build/app/outputs/flutter-apk/app-debug.apk"; do
    if [ -f "$c" ]; then APK="$c"; break; fi
  done
fi
if [ -z "$APK" ] || [ ! -f "$APK" ]; then
  echo "[install] 找不到 APK，请先运行 tools/build.sh（或传入 APK 路径）" >&2
  exit 2
fi

require_device
LOCAL_APK="$(to_win_path "$APK")"
echo "[install] 设备 : $SERIAL (Android $("$ADB" -s "$SERIAL" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r'))"
echo "[install] APK  : $APK ($(stat -c %s "$APK") bytes)"
echo "[install] adb install -r $LOCAL_APK"

OUT="$("$ADB" -s "$SERIAL" install -r "$LOCAL_APK" 2>&1)" && rc=0 || rc=$?
printf '%s\n' "$OUT"

if [ "$rc" -eq 0 ] && printf '%s' "$OUT" | grep -q '^Success'; then
  echo "[install] ✅ 安装成功"
  "$ADB" -s "$SERIAL" shell dumpsys package "$PKG" 2>/dev/null \
    | tr -d '\r' | grep -E 'versionName=|versionCode=|firstInstallTime=' | head -5 || true
  exit 0
fi

echo "[install] ❌ 安装失败 rc=$rc" >&2
if printf '%s' "$OUT" | grep -q 'INSTALL_FAILED_UPDATE_INCOMPATIBLE'; then
  echo "[install] 提示：签名冲突，可执行 '$ADB -s $SERIAL uninstall $PKG' 后重装" >&2
elif printf '%s' "$OUT" | grep -q 'INSTALL_FAILED_ALREADY_EXISTS'; then
  echo "[install] 提示：改用 -r 覆盖安装（本脚本默认已带 -r）" >&2
elif printf '%s' "$OUT" | grep -q 'INSTALL_FAILED_NO_MATCHING_ABIS'; then
  echo "[install] 提示：APK 不含 x86_64，需构建支持 x86_64 的 debug APK" >&2
fi
exit "$rc"
