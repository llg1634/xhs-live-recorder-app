# H.265（HEVC）直播流：为什么放不了，以及怎么放

> 2026-11-03 实测。测试房间：小红书 `570525164416427805`（直播中）、`570523767964339555`（已下播，样本已留存）。

## 一、结论先说

小红书直播 FLV 直链的**画质档位后缀决定编码**，不是 UA/Referer 决定：

| URL 后缀 | 编码 | 分辨率（实测） | 说明 |
|---|---|---|---|
| 无后缀 `/live/<roomId>.flv` | **H.264 (AVC)** | 1920×1080 | 兼容性最好，任何播放器都能放 |
| `_hcv5401` | **H.265 (HEVC)**，FLV video tag `codecId=12` | 960×540 | 540P 省流量档位 |
| `_sd` | H.264 (AVC) | 640×360 | 低清档，码率很低 |
| `_hcv7201` / `_hcv10801` / `_hd` / `_ld` / `_uhd` / `_or4` | — | — | 该房间不存在这些档位（404） |

App 的「默认画质」走 `_hcv5401`，于是**录出来的是 HEVC FLV**；而预览/回放用的 flv.js 只实现了 AVC 解封装（`Flv: Unsupported codec in video frame: 12`），所以报：

```
回放失败：解码失败：编码不支持（flv.js 仅支持 H.264/AAC，该流可能是 H.265）
```

## 二、为什么不能只改 flv.js

flv.js（1.6.2）的 FLV demuxer 里视频只走 `codecId == 7`（AVC）分支，其他值直接抛 `CODEC_UNSUPPORTED`；它也没有 HEVC 的 NALU 解析与 `hvcC` 处理。即使把 tag 解析补上，MSE 侧还要能接受 `video/mp4; codecs="hvc1.*"`——Android WebView 对 HEVC 的 MSE 支持并不普遍。

所以 HEVC 播放必须走**系统解码器**：`MediaCodec`（`video/hevc`）+ `MediaExtractor` 之外的**自己写的 FLV demux**。

## 三、原生播放器实现要点

代码：`app/android/app/src/main/kotlin/com/liquidlab/live_recorder/player/`

1. **FLV demux**（`FlvFlv.kt`）
   - 9 字节 FLV 头 + `PreviousTagSize` + tag（11 字节头：type/size/timestamp/timestampExt）。
   - 视频 tag：`[frameType<<4 | codecId][packetType][compositionTime 3B]`。
     - `codecId=7` → `video/avc`，`codecId=12` → `video/hevc`；
     - `packetType=0` → 解码器配置记录（AVC 的 `AVCDecoderConfigurationRecord` / HEVC 的 `HEVCDecoderConfigurationRecord`），直接作为 `csd-0`；
     - `packetType=1` → 长度前缀 NALU（长度位宽取自配置记录：AVC 第 4 字节低 2 位、HEVC 第 21 字节低 2 位），转成 Annex-B 后喂 `MediaCodec`；
     - PTS = DTS + compositionTime（24 位有符号）。
   - 音频 tag：`soundFormat=10` → AAC；`packetType=0` 的 `AudioSpecificConfig` 作 `csd-0`，`packetType=1` 裸帧直接喂 `audio/mp4a-latm`。
2. **渲染**：`TextureView` + `SurfaceTexture`；`setDefaultBufferSize(width, height)` 必须设成**视频尺寸**（不是 view 尺寸），否则模拟器的 `OMX.google.hevc.decoder` 会「输入全吃、零输出」。
3. **时钟**：以 `AudioTrack.playbackHeadPosition` 为主时钟，视频按 PTS 到点再 `releaseOutputBuffer(index, true)`；无音频时回退 `System.nanoTime`。
4. **回放 seek**：打开时扫一遍 FLV 建关键帧索引（时间戳 + 文件偏移），seek 时 flush 编解码器、跳到目标关键帧、重置时钟。1 GB 文件扫描只读 tag 头，不读 payload。
5. **直播预览**：`/live/<taskId>.flv` 是不断增长的分段文件，按 tail 方式持续读；EOF 后轮询文件长度，长时间无增长上报 buffering。
6. **降级**：设备没有 `video/hevc` 解码器时给明确中文提示，不黑屏。

## 四、Flutter 侧选择策略

`lib/ui/preview/live_preview_page.dart`：

- 打开前先探测编码（`FlvCodecProbe`：读文件头 512 KB，找第一个视频 tag 的 `codecId`，HEVC 还能从 hvcC 的 SPS 解析宽高）；
- `codecId=12` 或未知 → 原生播放器；
- `codecId=7` → 原 WebView + flv.js（成熟路径，保留）；
- WebView 报 `CodecUnsupported` → 自动切原生播放器兜底。

两条路径共用同一套 Flutter 外壳（进度、错误遮罩、全屏、静音、状态胶囊）。

## 五、样本与复现

```bash
# 抓 540P HEVC 样本（20 秒）
curl -o hevc_540p.flv \
  -A "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36" \
  -e "https://www.xiaohongshu.com/" \
  "https://live-source-play.xhscdn.com/live/<roomId>_hcv5401.flv"
```

用 `tools/flv_probe.py` 验证：`video_codec_ids: [12]`、`video_seq_headers: 1`、`audio_codec: 10`。
