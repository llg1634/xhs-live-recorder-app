#!/usr/bin/env bash
# tools/shot.sh <name> —— 截取模拟器当前屏幕到 verify/shots/<name>.png
#
# 用法：
#   tools/shot.sh home            # -> verify/shots/home.png
#   tools/shot.sh                 # -> verify/shots/shot_<时间戳>.png
#
# 实际命令：adb exec-out screencap -p > verify/shots/<name>.png（并校验 PNG 魔数）

set -euo pipefail
# shellcheck source=tools/_common.sh
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

NAME="${1:-shot_$(date +%Y%m%d_%H%M%S)}"
# 去掉扩展名，统一补 .png
NAME="$(basename "${NAME%.png}")"
OUT="$ROOT/verify/shots/${NAME}.png"

require_device
take_shot "$OUT"
echo "[shot] ✅ $OUT"
