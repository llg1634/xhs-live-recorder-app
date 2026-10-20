#!/usr/bin/env bash
# 把阿里云镜像注入到每个项目的 buildscript.repositories，
# 让第三方插件自带的 buildscript{google()} 在 dl.google.com 不可达时也能解析。
set -euo pipefail
F="$HOME/.gradle/init.d/cn-mirrors.gradle"
cp "$F" "$F.bak-$(date +%Y%m%d-%H%M%S)"
if grep -q "beforeProject" "$F"; then
  echo "already patched"
  exit 0
fi
cat >> "$F" <<'EOF'

// 追加：第三方插件自带 buildscript { repositories { google() } } 的 classpath
// 在项目评估阶段就要解析，projectsEvaluated 里重排太晚；
// 这里在每个项目评估前先把镜像塞进 buildscript 仓库列表最前面。
gradle.beforeProject { p ->
    try {
        addMirrors(p.buildscript.repositories)
        addMirrors(p.repositories)
    } catch (Throwable ignored) { }
}
EOF
echo "patched: $F"
tail -12 "$F"
