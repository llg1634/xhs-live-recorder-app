# 开发契约（子代理必读）

项目：`app/` —— Flutter Android 直播录制器（小红书为主，抖音待接）。

## 已实现且**不要改**的契约

| 文件 | 作用 |
|---|---|
| `lib/models/live_room.dart` | `LiveRoom{platform, roomId, pageUrl, rawInput, title, anchorName}`、`LivePlatform`、`LinkResolveException` |
| `lib/models/record_task.dart` | `RecordTask`、`RecordSegment`、`TaskState`（resolving/recording/reconnecting/completed/stopped/error） |
| `lib/services/link_resolver.dart` | `LinkResolver.resolve(rawText) → Future<LiveRoom>`，内部处理 xhslink 302 |
| `lib/services/storage_service.dart` | `StorageService.root()` / `createTaskDir()` / `listSessions()` |
| `lib/services/flv_recorder.dart` | `FlvRecorder`：断流 5s×3 探测、分段写盘、`previewStream` 实时字节流、`prelude` |
| `lib/services/recording_manager.dart` | `RecordingManager extends ChangeNotifier`：`tasks`、`startTask(raw)`、`stopTask(id)`、`recorderFor(id)`、`activeCount` |
| `lib/services/local_server.dart` | `LocalStreamServer`：`/live/<taskId>.flv`、`/file?path=`、`/player.html?src=`、`baseUrl`、`liveUrl()`、`playerUrlForLive()`、`playerUrlForFile()` |

Provider 注入（`lib/main.dart`）：
- `RecordingManager`（ChangeNotifier）
- `ThemeController`（ChangeNotifier，`mode: ThemeMode`）
- `LocalStreamServer`
- `StorageService`

## 分工与写作用域（禁止越界写别人的文件）

| 角色 | 可写目录/文件 |
|---|---|
| lead | `lib/models/**`、`lib/services/**`、`lib/app.dart`、`lib/main.dart`、`android/**`、`docs/**` |
| ui-glass | `lib/theme/**`、`lib/ui/home_screen.dart`、`lib/ui/widgets/**`、`lib/ui/library/**`、`lib/ui/settings/**`、`lib/ui/task/**` |
| player-web | `lib/ui/preview/**`、`assets/web/**` |
| douyin | `lib/services/douyin_resolver.dart`、`docs/douyin.md` |
| emu-ops | `tools/**`、`verify/**` |

需要改别人的文件时，先发消息说明，不要直接改。

## 设计语言：液态玻璃（Liquid Glass）

- 背景：深色为近黑多色光斑渐变（#0B0D12 → 紫/洋红/青 低透明度 blob），浅色为雾白 + 同色系更淡光斑。
- 玻璃层：`BackdropFilter(blur)` + 半透明填充 + 1px 高光描边（`LinearGradient` 白 0.35→0.05）+ 内阴影。
- 圆角 20–28，卡片间距 12–16，触摸有水波/缩放。
- 深/浅色自动跟随系统，也可在设置里强制。
- 文字：标题字重 700–800，正文 13–14，次要信息 60% 透明度。
- 必须真实可读：模糊层下面要有内容，不能在纯色底上做"假玻璃"。

## 验收口径

- `flutter analyze` 无 error；`flutter build apk --debug` 成功；模拟器 `127.0.0.1:21503` 上可安装运行。
- 多任务并发录制、断流重连、分段落盘、实时预览、录像回放、深浅色切换都必须真机/模拟器实测通过。
