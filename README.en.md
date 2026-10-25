# Live Recorder (Android): record Xiaohongshu / Douyin live streams with danmaku

中文说明：[README.md](README.md)

Search keywords: Xiaohongshu live recorder, Douyin live recorder, XHS live downloader, Douyin live downloader, record live stream on Android, live stream recorder APK, live recorder Android, danmaku export, live comments export, FLV downloader, ASS danmaku subtitles, multi-room live recording, mobile live recorder, TikTok live recorder.

`Live Recorder (Android App)` records **real FLV streams** and **real live comments (danmaku)** from Xiaohongshu and Douyin. Paste a room link or share text, hit record, and the app writes segmented FLV files plus `comments.jsonl` / `comments.ass` / `comments.srt` that PotPlayer can load directly.

It records the **network stream**, not the screen: video comes from the same source as the player, comments come from the room's own long-lived connection, so quality is independent of your display and recording keeps running with the screen off.

> Notice: only record content you have the right to record. Respect platform rules and the streamer's wishes. Do not record paid or infringing content, or use it for commercial redistribution.

## Features

- Record real FLV video from Xiaohongshu live rooms
- Record real FLV video from Douyin live rooms (signed pull URLs resolved at runtime)
- Record real live comments (nickname + time + text) from the comment channel
  - Xiaohongshu: text JSON frames, `customData.type == "text"`
  - Douyin: binary protobuf, `PushFrame → gzip → WebcastChatMessage`
- **Concurrent multi-room recording** (up to 6 rooms), independent state per room
- **Preview while recording** — play the segment being written, no need to wait
- **Danmaku subtitles** — `comments.ass` (1080×1920, 42 px, 8 s right-to-left scroll, lane avoidance) and `comments.srt`
- **Auto reconnect** on stalls; 3 failed probes ⇒ stream ended, stop automatically
- **Swipe = stop, data kept** — FLV streamed to disk and flushed every second; swiping the app away keeps everything recorded
- **Resume after interruption** — `session.json` written every 2 s; reopen the app and continue at `part02`
- **Library** — sort by time, per-segment playback, danmaku count, delete with optional confirmation
- **Liquid-glass UI** — light/dark themes with 6 accent palettes, persisted
- **Foreground service** — persistent notification with room count and elapsed time

## Install (which file to download)

Option 1 (recommended): open **Releases**, download `live-recorder-arm64-v1.0.0.apk`.

Option 2: build from source (see below).

1. Open the downloaded APK on your phone
2. Allow "install unknown apps" for the file manager / browser
3. Install and launch
4. Allow notifications when prompted (needed for the recording notification)

> Only an **arm64-v8a** build is provided (~19 MB), requiring **Android 7.0 (API 24)+**. For emulators or unusual devices, build from source.

### Build from source

```bash
git clone https://github.com/llg1634/xhs-live-recorder-app.git
cd xhs-live-recorder-app/app
flutter pub get
flutter build apk --release --target-platform android-arm64
```

Output: `app/build/app/outputs/flutter-apk/app-release.apk`. Requires Flutter 3.47 / Dart 3.13, Android SDK 34+.

## Usage

1. Paste a live-room link or share text into the Record tab
2. Enable "record danmaku" if needed (off by default, ~400 MB RAM per room)
3. Tap Record — live size, bitrate and segment count are shown on the card
4. Tap the card to preview while recording, or just background the app
5. Tap Stop (or wait for the stream to end) and collect the files

### Supported links

| Platform | Link forms |
|---|---|
| Xiaohongshu | `https://www.xiaohongshu.com/livestream/<roomId>?...`, `xhslink.com` short links, share text |
| Douyin | `https://live.douyin.com/<web_rid>`, `https://www.douyin.com/follow/live/<web_rid>`, `v.douyin.com` short links, share text |

### Output

```text
xhs_570511686529001102_nick_20261025-222924/
├── part01.flv        # segment 1 (part02, part03 … after reconnects / resume)
├── part02.flv
├── comments.jsonl    # {"ts":...,"user":"...","text":"...","commentId":"..."}
├── comments.ass      # scrolling danmaku subtitles
├── comments.srt      # plain subtitles
└── session.json      # recording state for crash recovery (safe to delete)
```

### PotPlayer

Open `part01.flv` in PotPlayer and drag `comments.ass` into the window (same folder and name loads automatically).

## Project layout

```text
xhs-live-recorder-app/
├── app/                          ← Flutter app
│   ├── lib/
│   │   ├── services/             ← recorder, resolvers, danmaku, subtitles, local server
│   │   ├── ui/                   ← liquid-glass UI (record / library / settings)
│   │   ├── theme/
│   │   └── models/
│   ├── android/                  ← native foreground service
│   └── test/
├── docs/                         ← protocol notes and findings
├── tools/                        ← reverse-engineering and verification scripts
└── verify/                       ← verification artifacts
```

## FAQ

- **0-byte file / "stream ended" immediately** — the FLV URL is dead (room offline or replay finished). Try a room that is live.
- **No danmaku** — capture is off by default; enable it before recording. Quiet rooms produce nothing.
- **Memory** — each danmaku WebView costs ~400 MB; enable only as many rooms as your phone can handle.
- **Swiping the app away** — recording stops and everything written stays on disk (at most the last second is lost).
- **After a process kill** — reopen the app, the task shows "interrupted · N segments kept"; tap ▶ to continue.
- **Merging segments** — `ffmpeg -f concat -safe 0 -i list.txt -c copy out.flv`.
- **Login-only rooms** — not supported; anonymous public rooms only.

## Version

- Current: `1.0.0`
- Stack: Flutter + Dart, native Kotlin foreground service, WebView-injected danmaku hooks
- Protocol notes: `docs/comments.md`, `docs/douyin.md`

## Disclaimer

For personal study and research only. You are responsible for complying with local laws, platform terms and the streamer's rights.
