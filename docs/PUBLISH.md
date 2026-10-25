# 发布准备（GitHub）

> 只做准备，不自动推送。确认无误后按下面命令执行。

## 1. 仓库信息建议

| 项 | 值 |
|---|---|
| 仓库名 | `live-recorder-android` |
| 描述（About） | 见 README「About」段落的一行文案 |
| Topics | `android`, `flutter`, `live-recorder`, `livestream-recorder`, `xiaohongshu`, `douyin`, `danmaku`, `flv`, `ass-subtitles` |
| 默认分支 | `main` |
| Release tag | `v1.0.0` |

## 2. 发布前检查清单

- [ ] `README.md` / `README.en.md` 中的仓库地址、版本号与实际一致
- [ ] `app/pubspec.yaml` 的 `version:` 为 `1.0.0+1`
- [ ] `flutter analyze` 无 error（当前：No issues found）
- [ ] 打包产物就位：`verify/app-release-arm64.apk`（arm64，约 19 MB）
- [ ] 截图（可选）：放在 `docs/screenshots/`，README 里引用
- [ ] 确认不包含敏感文件：`verify/*.apk` 已在 `.gitignore`，`plaza_net.json` 已忽略

## 3. 创建仓库并推送

```bash
cd "D:\renwu\261020小红书直播录制"

# 创建公开仓库（不初始化 README，本地已有）
gh repo create llg1634/live-recorder-android --public \
  --description "小红书 / 抖音直播录制 App：录制真实 FLV 视频流与真实弹幕，导出 partNN.flv + comments.ass/srt/jsonl。Xiaohongshu & Douyin live recorder for Android."

# 关联远程并推送
git remote add origin https://github.com/llg1634/live-recorder-android.git
git push -u origin main

# 设置 topics
gh repo edit llg1634/live-recorder-android \
  --add-topic android,flutter,live-recorder,livestream-recorder,xiaohongshu,douyin,danmaku,flv,ass-subtitles
```

## 4. 发布 Release

```bash
cd "D:\renwu\261020小红书直播录制"

gh release create v1.0.0 \
  "verify/app-release-arm64.apk#live-recorder-arm64-v1.0.0.apk" \
  --title "v1.0.0 — 首个公开版本" \
  --notes-file RELEASE_NOTES_v1.0.0.md
```

## 5. 发布后

- [ ] 在 Releases 里确认 APK 可下载、文件名正确
- [ ] 手机扫码/下载安装验证一次
- [ ] 把 Release 链接补进 README「安装」段落（可选）
