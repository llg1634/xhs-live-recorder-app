# 直播录制 App：小红书直播怎么录制 / 抖音直播怎么录制 / 怎么下载视频和弹幕

English README: [README.en.md](README.en.md)

搜索关键词：小红书直播录制、抖音直播录制、小红书直播下载、抖音直播下载、小红书直播录像、抖音直播录像、小红书直播回放下载、抖音直播回放下载、小红书直播视频保存、抖音直播视频保存、直播弹幕下载、直播评论导出、直播弹幕导出、小红书直播弹幕、抖音直播弹幕、小红书直播评论、抖音直播评论、直播录制工具、直播下载工具、直播保存工具、直播 FLV、直播流下载、直播自动录制、多直播间同时录制、安卓直播录制、手机直播录制、直播录制 App、直播录制 APK、直播弹幕字幕、直播 ASS 字幕、小红书直播跟播、抖音直播跟播、XHS live recorder、Xiaohongshu live recorder、Douyin live recorder、TikTok live recorder、live stream recorder Android、live recorder APK。

`直播录制 / Live Recorder (Android App)` 是一个 Android 手机应用：把小红书或抖音的直播间链接（或 App 分享文案）粘进去，就能在手机上直接录制直播的**真实 FLV 视频流**和**真实弹幕评论**，停止后自动导出 `comments.ass` / `comments.srt` 弹幕字幕，可直接用 PotPlayer 加载。

它录制的是**真实网络流和真实弹幕**，不是录屏：视频流与播放器同源，弹幕来自直播间自己的长连接评论通道，所以画质不受屏幕分辨率影响，手机息屏、切后台也不影响录制。

重要提示：本工具仅用于您有权录制的内容。请遵守平台规则与主播意愿，不要用本工具录制付费内容、侵权内容或用于商业再利用。

## 功能

- 录制小红书直播的真实 FLV 视频流（与播放器同源，非录屏）
- 录制抖音直播的真实 FLV 视频流（自动解析带签名的拉流地址）
- 录制直播间真实弹幕评论（昵称 + 时间 + 内容，来自评论长连接）
  - 小红书：文本 JSON 帧，解析 `customData.type == "text"`
  - 抖音：二进制 protobuf 帧，解析 `PushFrame → gzip → WebcastChatMessage`
- **多直播间并发录制**：默认最多 6 路，每路独立状态、体积、速率和分段
- **边录边看**：录制中点「预览」直接播放正在写入的分段，不用等录完
- **弹幕字幕**：停止录制时自动生成 `comments.ass`（1080×1920、42 号字、8 秒右→左滚动、泳道避让）和 `comments.srt`
- **断流自动重连**：网络抖动 2~3 秒不误判；连续 3 次探测失败才判定直播结束并自动停止
- **划掉即停、数据不丢**：FLV 流式写盘，每秒 flush；从最近任务划掉 App 就停止录制，已录内容完整保留（最多丢最后 1 秒）
- **中断可续录**：每 2 秒写 `session.json`，重开 App 能看到「已中断 · 已保留 N 段」，点一下从 `part02` 接着录
- **录像库**：按时间排序（最新/最早可切换）、分段回放、显示弹幕条数、单场删除（二次确认可在设置关闭）
- **液态玻璃 UI**：深浅双主题 + 6 套主题色（粉紫/青蓝/薄荷绿/琥珀橙/玫瑰红/石墨灰），选择持久化
- **前台服务**：常驻通知显示录制路数与时长，Android 13+ 自动申请通知权限

## 安装（下载哪个文件，看这里）

方式一（推荐）：点击页面右侧 **Releases**，下载最新版本的 `live-recorder-arm64-v1.0.0.apk`。

方式二：从源码构建，见下方「从源码构建」。

1. 在手机浏览器或文件管理器里点开下载好的 APK
2. 系统提示「禁止安装未知来源应用」时，允许当前应用安装未知应用
3. 点击安装，等待完成
4. 打开 App，首次进入按提示允许通知权限（录制时常驻通知需要）

> 只提供 **arm64-v8a** 包（近几年的手机都是这个架构），体积约 19 MB，要求 **Android 7.0（API 24）及以上**。模拟器或特殊设备请用源码构建对应架构。

### 从源码构建

```bash
git clone https://github.com/llg1634/live-recorder-android.git
cd live-recorder-android/app
flutter pub get
flutter build apk --release --target-platform android-arm64
```

产物：`app/build/app/outputs/flutter-apk/app-release.apk`。
环境：Flutter 3.47 / Dart 3.13，Android SDK 34+。

## 使用

1. 打开 App，在「录制」页粘贴直播间链接或分享文案
2. 需要弹幕就打开「同时录弹幕」（默认关闭，每路约多占 400 MB 内存）
3. 点「开始录制」→ 卡片显示实时体积、速率、分段数
4. 录制中可点卡片进「预览」边录边看，也可以直接切后台或息屏
5. 点「停止」或等直播结束自动停止 → 录像目录里生成完整文件

### 支持哪些链接

| 平台 | 链接形式 |
|---|---|
| 小红书 | `https://www.xiaohongshu.com/livestream/<roomId>?...`、`xhslink.com` 短链、App 分享文案 |
| 抖音 | `https://live.douyin.com/<web_rid>`、`https://www.douyin.com/follow/live/<web_rid>`、`v.douyin.com` 短链、App 分享文案 |

### 输出文件

每次录制在 `/storage/emulated/0/Movies/直播录制/` 下新建一个目录：

```text
xhs_570511686529001102_主播昵称_20261025-222924/
├── part01.flv        # 第 1 段视频（断流重连 / 续录会生成 part02、part03…）
├── part02.flv
├── comments.jsonl    # 结构化弹幕 {"ts":...,"user":"...","text":"...","commentId":"..."}
├── comments.ass      # 弹幕字幕（右→左滚动），PotPlayer 可直接加载
├── comments.srt      # 普通字幕
└── session.json      # 录制状态（中断恢复用，可删）
```

### PotPlayer 加载弹幕

用 PotPlayer 打开 `part01.flv`，把同目录的 `comments.ass` 拖进播放器窗口即可（同目录同名会自动加载）。多个分段连续播放时，字幕时间轴从第一段开始计算。

## About

一句话简介（复制到 GitHub 仓库 About 栏）：

```text
小红书 / 抖音直播录制 App：一键录制真实 FLV 视频流与真实弹幕评论，导出 partNN.flv + comments.ass/srt/jsonl，支持多直播间并发、边录边看、中断续录。Xiaohongshu & Douyin live recorder for Android.
```

## 目录结构

```text
live-recorder-android/
├── app/                          ← Flutter App
│   ├── lib/
│   │   ├── services/
│   │   │   ├── flv_recorder.dart      ← FLV 拉流、分段、断流探测
│   │   │   ├── recording_manager.dart ← 多任务调度、中断恢复
│   │   │   ├── comment_capture.dart   ← 双平台弹幕 hook（WebView）
│   │   │   ├── ass_export.dart        ← ASS / SRT 字幕生成
│   │   │   ├── douyin_resolver.dart   ← 抖音拉流地址解析
│   │   │   ├── session_store.dart     ← session.json 落盘
│   │   │   └── local_server.dart      ← 边录边看 / Range 服务
│   │   ├── ui/                        ← 液态玻璃 UI（录制 / 录像 / 设置）
│   │   ├── theme/                     ← 主题色与玻璃样式
│   │   └── models/
│   ├── android/                       ← 原生前台服务、通知
│   └── test/
├── docs/
│   ├── comments.md                    ← 弹幕协议逆向记录（小红书 / 抖音）
│   ├── douyin.md                      ← 抖音拉流地址解析记录
│   └── findings.md                    ← 播放与性能实测结论
├── tools/                             ← 逆向与验证脚本
└── verify/                            ← 验证产物
```

## 常见问题

- **录出来 0 字节 / 一开始就显示「直播结束」**：该房间的 FLV 直链已失效（已下播，或「重播」房间的流已结束）。换正在直播的房间再试。
- **弹幕一直是 0 条**：弹幕默认关闭，需要开始录制前打开「同时录弹幕」；另外直播间长时间没人发言也会是 0。
- **弹幕占内存**：每路采集 WebView 约 400 MB，多路请按手机内存酌情开启。
- **划掉 App 会怎样**：停止录制。因为边录边写盘，已录内容完整保留（最多丢最后 1 秒），录像页可直接回放。
- **被杀进程后还能接着录吗**：能。重开 App 后该任务显示「已中断 · 已保留 N 段」，点 ▶ 从下一个分段号继续。
- **分段能合并吗**：可以，`ffmpeg -f concat -safe 0 -i list.txt -c copy out.flv`，`list.txt` 里按顺序写 `file 'part01.flv'`。
- **预览打不开**：预览走本机 `127.0.0.1` 的 HTTP 服务，部分系统浏览器限制本地回环，用 App 内预览页即可。
- **支持登录才能看的直播吗**：不支持，只做匿名公开直播间。

## 开发与版本

- 当前版本：`1.0.0`
- 技术栈：Flutter + Dart，原生 Kotlin 前台服务；弹幕在 WebView 内注入 hook，用页面自身的长连接会话解码
- 关键实现记录：`docs/comments.md`（两平台协议差异、帧结构、内存与后台实测数据）、`docs/douyin.md`（拉流地址解析）

## 免责声明

本项目仅供个人学习与技术研究使用。使用者应自行确保录制行为符合当地法律法规及平台用户协议，并尊重主播的著作权与肖像权。因使用本工具产生的一切后果由使用者自行承担。
