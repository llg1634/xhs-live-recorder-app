# 小红书 / 抖音 直播录制：实测结论

> 2026-10-20 实测。环境：本机 Windows + 安卓模拟器（Android 9 / x86_64）+ 浏览器桥。

## 一、小红书（重点）

### 1. 链接 → 房间号（两条路都成立）

| 输入 | 处理方式 | 结果 |
|---|---|---|
| `https://www.xiaohongshu.com/livestream/570501740524334550?...xsec_token=...` | 正则取房间号 | ✅ |
| 分享短链 `https://xhslink.com/o/9iND1710iyA`（含整段分享文案） | **服务器端 302**（无需浏览器执行 JS） | ✅ 跳转到 `/livestream/{dynpath}/{roomId}?xsec_token=...` |

两种页路径都要兼容：
- 老版：`/livestream/{roomId}`
- 新版：`/livestream/{dynpath}/{roomId}`（`dynpath` 是路径扰动，不是房间号）

### 2. FLV 直链：房间号即可构造（关键结论）

```text
https://live-source-play.xhscdn.com/live/{roomId}.flv
```

已验证：
- **无签名、无 Cookie、无 Referer、无 UA 要求**，curl 默认参数即 200 + `video/x-flv`；
- 无效房间号返回 **404**（可用来判断"未开播/已结束"）；
- 带 `?userId=...&abr_pts=-3000` 或伪造 userId 均不影响；
- 直播页**不需要登录**（匿名可看，实测 `web_session` 不存在时正常播放）。

**这条结论直接绕开了"风控导致直播页打不开"的问题**：风控作用在页面/API 层，CDN 拉流层不受影响。

### 3. 编码：由 URL 后缀决定，不是 UA

| URL | codec |
|---|---|
| `/live/{roomId}.flv` | **H.264**（videocodecid=7） |
| `/live/{roomId}_hcv5401.flv` | HEVC（videocodecid=12） |

结论：录制统一用**裸 URL**（H.264），这样 flv.js 预览/回放都能播；`_hcv*` 是 HEVC 变体，不要用。

### 4. 断流与重连

- 断流后**同一条 URL 重新连接**即可从当前直播点继续，不需要刷新页面；
- 每次新连接都会重发 FLV 头，分段独立可播；
- 分段之间**不需要合并**（用户确认：分成几段视频即可）；
- 探测策略：断流后每 **5 秒**探测一次，连续 **3 次**失败才判定直播结束。

### 5. 分辨率实测

| 房间 | 裸 URL 分辨率 | 备注 |
|---|---|---|
| 570501740524334550（第五人格赛事） | 1920×1080 H.264 | 轮播重放，长期在线 |
| 570504953736339047（第五人格） | 1440×2560 H.264 | 竖屏手机开播 |
| 570504739410338837（王者荣耀赛事） | 1920×1080+ | 高码率 |

## 二、抖音（顺带支持）

纯 HTTP 即可拿直链，**不需要浏览器**：

```text
GET https://live.douyin.com/{web_rid}          # 带桌面 UA，取匿名 ttwid cookie
GET https://live.douyin.com/webcast/room/web/enter/?aid=6383&device_platform=web
     &browser_language=zh-CN&browser_platform=Win32&browser_name=Edge
     &browser_version=152.0.0.0&web_rid={web_rid}   # Cookie: ttwid=...
→ data.data[0].stream_url.flv_pull_url.{FULL_HD1|HD1|SD2|SD1}
```

- 直链带签名（`k`+`t` 或 `expire`+`sign`），有效期约 **7 天**，篡改即 403；
- **CDN 拉流不需要 Cookie/Referer/UA**；
- 断流后同 URL 可重连；稳妥做法是每次重连都重新解析（App 已实现）；
- 未开播：`status=4` 且 `flv_pull_url` 为空；
- 风控信号：接口 200 但 **body 长度 0** → 刷新 ttwid 重试；
- 详细证据见 [douyin.md](douyin.md)。

## 三、App 侧实现要点

| 环节 | 做法 |
|---|---|
| 输入 | 粘贴整段分享文案，正则抽链接 |
| 解析 | Dart `HttpClient` 手动跟随 302，不下载页面正文 |
| 录制 | `dart:io` HttpClient 流式写盘，无转码，FLV 直通 |
| 断流 | 5s × 3 次探测，成功 → 新分段文件 |
| 并发 | 每个任务一个 `FlvRecorder`，`RecordingManager` 统一调度 |
| 存储 | `/storage/emulated/0/Movies/直播录制/{平台}_{房间号}_{昵称}_{时间戳}/partNN.flv` |
| 预览 | 本地 HTTP 服务把实时字节流喂给 WebView 里的 flv.js（同源，无 CORS） |
| 后台 | 原生 Kotlin 前台服务（`RecordingForegroundService`）保活 |
