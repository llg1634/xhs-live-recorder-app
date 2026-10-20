#!/usr/bin/env bash
# tools/_common.sh —— 所有 tools/*.sh 共享的环境探测与 adb 封装。
# 被 source，不直接执行。
#
# 可用环境变量覆盖：
#   FLUTTER_HOME  flutter SDK 根目录（默认 /d/dev/flutter）
#   ANDROID_SDK   Android SDK 根目录（默认 /d/dev/android-sdk，或 $ANDROID_HOME）
#   ADB           adb 可执行文件路径
#   ANDROID_SERIAL / SERIAL  目标设备序列号（默认 127.0.0.1:21503）
#   PKG           Android 包名（默认 com.liquidlab.live_recorder）

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER_HOME="${FLUTTER_HOME:-/d/dev/flutter}"
ANDROID_SDK="${ANDROID_SDK:-${ANDROID_HOME:-/d/dev/android-sdk}}"
PKG="${PKG:-com.liquidlab.live_recorder}"
ACTIVITY="${ACTIVITY:-$PKG/.MainActivity}"
SERIAL="${ANDROID_SERIAL:-${SERIAL:-127.0.0.1:21503}}"

# Windows 路径 <-> MSYS 路径
win_to_posix() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -u "$1" 2>/dev/null || printf '%s' "$1"
  else
    printf '%s' "$1"
  fi
}

to_win_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1" 2>/dev/null || printf '%s' "$1"
  else
    printf '%s' "$1"
  fi
}

_find_adb() {
  local c
  if command -v adb >/dev/null 2>&1; then
    command -v adb
    return 0
  fi
  for c in \
    "/d/dev/android-sdk/platform-tools/adb.exe" \
    "/d/dev/android-sdk/platform-tools/adb" \
    "$(win_to_posix "$ANDROID_SDK")/platform-tools/adb.exe" \
    "$(win_to_posix "$ANDROID_SDK")/platform-tools/adb"; do
    if [ -x "$c" ]; then
      printf '%s' "$c"
      return 0
    fi
  done
  echo "找不到 adb，请用 ADB=/path/to/adb 指定" >&2
  return 127
}

ADB="${ADB:-$(_find_adb)}"

adb_s() { "$ADB" -s "$SERIAL" "$@"; }

require_device() {
  local state
  state="$("$ADB" devices 2>/dev/null | tr -d '\r' | awk -v s="$SERIAL" '$1==s {print $2; exit}')"
  if [ "$state" != "device" ]; then
    echo "[device] 错误：$SERIAL 不可用（state='${state:-未连接}'）" >&2
    echo "[device] 当前 adb devices：" >&2
    "$ADB" devices -l 2>/dev/null | tr -d '\r' >&2 || true
    exit 1
  fi
}

# 截图并校验 PNG 魔数；$1=输出文件路径
take_shot() {
  local out="$1" sig
  mkdir -p "$(dirname "$out")"
  adb_s exec-out screencap -p >"$out" || true
  sig="$(head -c 8 "$out" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  if [ "$sig" != "89504e470d0a1a0a" ]; then
    echo "[shot] 截图失败：$out 不是有效 PNG（magic=${sig:-空}）" >&2
    return 1
  fi
  printf '%s (%s bytes)\n' "$out" "$(stat -c %s "$out")"
}
