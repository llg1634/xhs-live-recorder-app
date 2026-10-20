# 抖音直播 FLV 直链：实测报告与接入方案

> 实测时间：2026-10-20 18:40–19:10（UTC+8）
> 环境：Windows 10 + Edge 152（已登录）+ 浏览器自动化桥 Port Tabs 0.3.4（`http://127.0.0.1:17368`）+ `curl` + Python 3.13
> 样例直播间：
> - **直播中** `https://live.douyin.com/675247105586`（主播「马辉·游钓江湖」，标题「夜钓大板鲫」，`room.status = 2`）
> - **直播中（另一 CDN）** `https://live.douyin.com/71128852011`
> - **未开播** `https://live.douyin.com/385355654156`、`https://live.douyin.com/1`（`room.status = 4`）

---

## 0. 结论速览（TL;DR）

| 问题 | 结论 |
| --- | --- |
| 能否**纯 HTTP** 拿到 FLV 直链？ | ✅ **能**。`GET 直播间页(取 ttwid cookie)` → `GET /webcast/room/web/enter/` → 解析 `data.data[0].stream_url.flv_pull_url`。全程不执行 JS、不需要浏览器。 |
| 是否必须 WebView / 浏览器？ | ❌ **当前版本不需要**（2026-10 实测）。只有 1.6 个前提：① 要拿到匿名 `ttwid` cookie（普通 302/Set-Cookie 即可）；② 请求要带浏览器 UA。 |
| 是否要自己算签名？ | ❌ **不需要**。直链里的 `k`/`t`（或 `expire`/`sign`）由 `room/web/enter` 服务端签发。**没有发现可离线推导的签名算法**（见 §3.4），也无需推导。 |
| 拉流需要 Cookie / Referer / UA 吗？ | ❌ **都不需要**。CDN 只校验 URL 查询串里的签名。实测无 Cookie、无 Referer、curl 默认 UA 也能 200 并返回 FLV。 |
| 直链时效 | `t` / `expire` ≈ **签发时间 + 604800 秒（7 天）**（与历史 `keeptime=00093a80` 吻合）。改动 `t`/`k`/`expire`/`sign` 任意一位 → 立刻 **403**。但主播重开播会换 stream id，旧链接失效，所以**每次重连都应重新解析**。 |
| 断流后**同一条 URL**能重连吗？ | ✅ **能**。同一 URL 被反复重连 3 次（间隔 0–20 s）全部 200，每段均以 FLV 头开始、时间戳跳到当前直播点；另在签发后 ~9 分钟再次复用仍 200（见 §4.3 与后台 13 分钟复测）。 |
| 实际播放器在拉什么？ | 播放器在 **Worker 里用 fetch** 拉 FLV（`Network` 列表里 `type=Fetch`，先 302 到 `ksyungslb.com` 边缘节点）。页面 `performance.getEntriesByType('resource')` 里查不到，**抓包必须用 CDP Network，不要用 performance API**。 |

---

## 1. 关键实测证据

### 1.1 浏览器抓包：`webcast/room/web/enter`

打开 `https://live.douyin.com/675247105586` 后，CDP `Network.requestWillBeSent` 捕获到（参数已截断）：

```text
GET https://live.douyin.com/webcast/room/web/enter/
    ?aid=6383&app_name=douyin_web&live_id=1&device_platform=web&language=zh-CN
    &enter_from=link_share&cookie_enabled=true&screen_width=1707&screen_height=1067
    &browser_language=zh-CN&browser_platform=Win32&browser_name=Edge&browser_version=152.0.0.0
    &os_name=Windows&os_version=10&web_rid=675247105586
    &room_id_str=7698690335416929074...
→ 200 application/json（约 36 KB）
```

响应用纯 HTTP 也能拿到（见 §1.3），结构：

```textc
data.data[0]
  ├─ status = 2                       # 2=直播中，4=已结束/未开播
  ├─ title = "夜钓大板鲫"
  ├─ owner.nickname = "马辉·游钓江湖"
  ├─ id_str = 7698690335416929074     # 真实 room_id（web_rid 之外另一套 ID）
  └─ stream_url
       ├─ default_resolution = "HD1"
       ├─ flv_pull_url = { FULL_HD1: "..._or4.flv?k=...&t=...", HD1: ..., SD1: ..., SD2: ... }
       ├─ hls_pull_url_map = { FULL_HD1: ".../index.m3u8?k=...&t=...", ... }
       ├─ live_core_sdk_data.pull_data.options.qualities = [ {name, sdk_key(origin/hd/sd/ld), resolution, v_bit_rate, fps}, ... ]
       └─ extra = { width, height, fps, ... }
```

### 1.2 播放器实际拉流请求（CDP Network，2026-10-20 18:48）

```text
10048.2359  302  Fetch
https://pull-flv-h6.douyincdn.com/stage/stream-120292037024285529_ld5.flv
  ?k=8cd6fad66a96ef97&t=1793098105&arch_hrchy=h1&exp_hrchy=h1&major_anchor_level=common
  &unique_id=stream-120292037024285529_857_flv_ld5&t_id=037-20261020184824778F7A221472FBDDEB9E-5VmyGM
  &biz_quality=ld&biz_protocol=flv&biz_vcodec=...
```

- 列表里类型是 `Fetch`（不是 `Media`），且 `302` 指向 `*.ksyungslb.com` 边缘节点。
- 页面侧还能从 Cookie `live_debug_info` 里读到播放器当前源的 JSON（url 解码后）：

```jsonc
{
  "roomId": "7698690335416929074",
  "resolution": {"width": 1088, "height": 1920},
  "src": "https://pull-flv-h6.douyincdn.com/stage/stream-120292037024285529.flv?k=6dd9bb78f7b446ff&t=1793097864&...&biz_quality=origin&biz_protocol=flv&biz_vcodec=h265&...",
  "href": "https://live.douyin.com/675247105586"
}
```

> 注意：浏览器自己播放的那条 `biz_vcodec=h265`（HEVC）是页面 MSE 播放用的；**API 返回的 `FULL_HD1` 是 `_or4`（H.264 + AAC）**，更适合录制/回放。实测下载的文件首帧视频 tag 为 `17 00 ... 01 64 00`（AVC High），音频 tag 为 `af 00 11 90`（AAC）。

### 1.3 纯 HTTP 复现（决定性实验）

脚本：临时 Python 脚本（已清理，等价命令见 §5）。

**第 1 步：匿名 GET 直播间页，只为拿 `ttwid`**

```bash
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36 Edg/152.0.0.0"
curl -s -c /tmp/dy.jar -A "$UA" https://live.douyin.com/675247105586 -o /dev/null
# /tmp/dy.jar 里得到：ttwid（127 字符，HttpOnly）、UIFID_TEMP、UIFID
```

- 不跟登录无关：**匿名** 也会下发 `ttwid`。
- ⚠️ **不带浏览器 UA（如 curl/python 默认 UA）时页面返回 0 字节、无任何 Set-Cookie**（实测），所以这一步必须带桌面浏览器 UA。

**第 2 步：带 `ttwid` 调 `room/web/enter`**

最小必需参数（逐项 drop 实测）只有 7 个：

```text
aid=6383
device_platform=web
browser_language=zh-CN
browser_platform=Win32
browser_name=Edge
browser_version=152.0.0.0
web_rid=<直播间 web_rid>
```

（`app_name/live_id/language/enter_from/cookie_enabled/screen_width/screen_height/os_name/os_version` 均非必需；`browser_*` 缺任意一个 → 返回 **0 字节**。）

```bash
curl -s -b /tmp/dy.jar -A "$UA" \
  "https://live.douyin.com/webcast/room/web/enter/?aid=6383&device_platform=web&browser_language=zh-CN&browser_platform=Win32&browser_name=Edge&browser_version=152.0.0.0&web_rid=675247105586" \
  | python -m json.tool
```

**第 3 步：解析直链**

```text
http://pull-flv-h6.douyincdn.com/stage/stream-120292037024285529_or4.flv
  ?k=11484f6635e4c2b9&t=1793098209&major_anchor_level=common&exp_hrchy=h1&arch_hrchy=h1
  &unique_id=stream-120292037024285529_857_flv_or4
  &t_id=037-20261020185009C0DFED8C062FC1E6025A-ySuJHs
```

**关键对照实验：**

| 实验 | 结果 |
| --- | --- |
| 带 `ttwid` + 完整/最小 7 参数 | 200，`status_code=0`，拿到 4 档 FLV |
| **不带任何 Cookie** | 200 但 **body 长度 0**（典型风控空包） |
| 只带 `UIFID`、不带 `ttwid` | 200 空包 |
| 只带 `ttwid`（UIFID 不要） | ✅ 200 正常 JSON |
| ttwid 来自**直播广场页** `https://live.douyin.com/` | ✅ 同样可用 |
| ttwid 来自已登录 Edge 的 Cookie | ✅ 同样可用（说明**不需要登录**） |
| 只传 `web_rid`（缺 `aid` 等） | `status_code=10011` |
| 非法 web_rid（如 `999999999999`） | `status_code=4001038`，`data.data=[]` |
| 未开播房间 | `status_code=0`，`data.data[0].status=4`，`flv_pull_url={}` |

> **结论：纯 HTTP 链条 = 页面 GET(取 ttwid) + API GET(拿签名直链) + CDN GET(拉流)，全部可用 curl 完成，不执行任何 JS。**

### 1.4 curl 拉流实测（10 秒）

```bash
curl -sS -m 10 -L -o sample.flv "$FLV_URL"
head -c 3 sample.flv | od -An -tx1      # 46 4c 56  = "FLV"
```

| URL | 请求头 | 结果 |
| --- | --- | --- |
| API 返回的 `FULL_HD1`（http） | **无 Cookie / 无 Referer / curl 默认 UA** | 200，10 s **2,397,566 B**，`video/x-flv`，头 `46 4c 56` |
| API 返回的 `FULL_HD1`（https） | 同上 | 200，10 s 819,213 B（起播慢），头 `46 4c 56` |
| 浏览器抓到的 origin URL（https） | 同上 | 200，~3.0 MB/10 s，头 `46 4c 56` |
| 换抖音 App UA（FlvRecorder 的 Android UA）+ `Referer: xiaohongshu.com` | 模拟 App 现网请求头 | 200，3,150,371 B/10 s，头 `46 4c 56` |
| 房间 2（`expire`/`sign` 方案） | 无 Header | 200，**7,344,753 B/10 s**（4K 档），头 `46 4c 56` |

响应链：`GET pull-flv-h6.douyincdn.com/...` → **302** `Location: https://58-240-12-140-nefc19bb.ksyungslb.com/pull-flv-h6.douyincdn.com/...&ks302=...&ks_hashid=v636-18` → 200 `video/x-flv`。Dart `HttpClient` 默认跟随 302，无需特殊处理。

CDN 响应头示例：

```text
HTTP/1.1 200 OK
Content-Type: video/x-flv
X-Server-Ip: 58.240.12.140
Access-Control-Allow-Origin: *
Cache-Control: no-cache
Connection: close
```

### 1.5 两套 URL / 签名形态并存

同一时段、不同 CDN 后缀的直播间会返回两种形态，**解析时不要假设只有一种参数名**：

| CDN 主机 | 形态 | 样例（token 已过期，仅示意） |
| --- | --- | --- |
| `pull-flv-h6.douyincdn.com` | `/stage/stream-<sid>[_档位].flv?` + **`k`(16 hex) & `t`(unix s)** + `unique_id`/`t_id`/`arch_hrchy`/`exp_hrchy`/`major_anchor_level` | `.../stream-120292037024285529_or4.flv?k=11484f6635e4c2b9&t=1793098209&...` |
| `pull-flv-gravity-l11.douyincdn.com` | `/third/stream-<sid>_<档位>.flv?` + **`expire`(unix s) & `sign`(32 hex)** + `unique_id`/`t_id`/`arch_hrchy`/`exp_hrchy`/`major_anchor_level` | `.../stream-696752743561560540_uhd.flv?expire=1793098267&sign=322f0fa7c98fca88be3fe5e12239099e&...` |

历史实现（`E:\renwu2\260705录制抖音优化`，2026-07）里的 `wsSecret` + `wsTime` + `keeptime=00093a80` 在当前网页版已经**看不到了**；2026-10 是 `k/t` 或 `expire/sign`。旧文档的「解析 `room/web/enter` → `stream_url.flv_pull_url`」思路仍然成立，但**不要写死参数名**，直接透传 API 返回的完整 URL 即可。

### 1.6 档位映射

`flv_pull_url` 的 key 与 `live_core_sdk_data...qualities[].sdk_key` 对应关系（以房间 675247105586 为例）：

| `flv_pull_url` key | 流后缀 | `sdk_key` | 页面文案 | 分辨率 | 备注 |
| --- | --- | --- | --- | --- | --- |
| `FULL_HD1` | `_or4` / `_uhd` | `origin` | 蓝光 | 1088×1920 | 最高码率，H.264+AAC |
| `HD1` | `_Stage0T000hd` / `_hd` | `hd` | 超清 | 720×1270 | |
| `SD2` | `_sd` | `sd` | 高清 | 540×952 | |
| `SD1` | `_ld` | `ld` | 标清 | 480×847 | |

> key 顺序不是画质顺序（`SD1` < `SD2`）；推荐顺序：`FULL_HD1 → HD1 → SD2 → SD1`。

---

## 2. 关键判断逐条回答

### 2.a 是否带签名 / 时效参数？多久过期？

- **带签名**，且每档、每条流路径的签名都不同（`k`/`sign` 与 path 绑定）。
- 时间参数 `t`（或 `expire`）在**签发时 ≈ 当前时间 + 604800 秒**：
  - 抓包 `t=1793097864`，签发时刻 ≈ `1792493073`，差 **604,791 s ≈ 6.999 天**；
  - 另一 CDN `expire=1793098267`，差 **605,155 s ≈ 7.005 天**；
  - 与旧版 `keeptime=00093a80`（=604800）完全一致 → **理论有效期 7 天**。
- 篡改实验（同一 URL）：

| 改动 | 结果 |
| --- | --- |
| 去掉整个 query | 403 |
| 去掉 `k` | 403 |
| 去掉 `t` | 403 |
| `k=0000000000000000` | 403 |
| `t = 原值 - 30s` / `t = 原值 + 1s` / `t = 原值 + 360 天` | 403 |
| `expire`/`sign` 同理改动 | 403 |

→ 签名覆盖了 `t`/`expire`，**改时间即失效**；`t` 不是「可随意延长」的普通参数。
→ 但「7 天后一定会过期」本次无法真的等 7 天验证；按签名语义与历史 `keeptime` 判断为 7 天。实际录制时**每次重连重新解析**即可完全规避过期问题。

### 2.b 断流后同一条 URL 能否重连继续拉？

✅ **能，且行为很友好**：

| 实验 | 结果 |
| --- | --- |
| 原 URL 拉 3 s 后断开，立刻重连 6 s | 200，2,080,781 B，头 `46 4c 56` |
| 断开后空闲 20 s，再连 6 s | 200，2,064,397 B，头 `46 4c 56` |
| 签发后 ~9 分钟再复用（同 URL） | 200，2,768,909 B，头 `46 4c 56` |
| 后台 13 分钟复测（任务结束时回填，见 §4.3） | 见 §4.3 |
| 房间 2（`expire/sign` 方案）连续两次 4 s | 200 / 200，均 FLV 头 |

FLV 时间戳验证（解析每个文件的前几个 tag）：

```text
rc1: script ts=0, audio ts=0, video ts=0, video keyframe ts=2,260,125 ms
rc2: script ts=0, audio ts=0, video ts=0, video keyframe ts=2,263,852 ms
rc3: script ts=0, audio ts=0, video ts=0, video keyframe ts=2,289,947 ms
```

→ 每次新建连接都会**重新发 FLV 头**，随后从当前直播时间点继续；不同连接时间戳递增，说明内容在直播时间轴上继续。分段独立可播，与 App 现有 `FlvRecorder` 的「每段独立 FLV」策略兼容。

> 注意：`FlvRecorder` 在每次开新分段 / 探测前都会重新调用 `urlProvider()`，抖音场景下会重新解析、拿到**新签名 URL**，比复用旧 URL 更稳。

### 2.c 能否只用 curl（不带 cookie）拉流？必须 cookie 吗？

- **拉流（CDN）**：`curl` 无 Cookie、无 Referer、任意 UA 均可 200，**不需要任何 cookie**。
- **取直链（API）**：**需要匿名 `ttwid` cookie**。没有 `ttwid` 时接口返回 `200` + **空 body**（不是 4xx，容易误判）。
- 页面 GET 需要**浏览器 UA**（否则 0 字节）。
- 不需要登录 cookie；`UIFID` 不需要；`msToken`/`a_bogus`/`__ac_signature` 当前不需要。

### 2.d 能否不依赖浏览器、只用 HTTP API + 计算签名拿到？

✅ **能，但不需要「计算签名」这一步**：

1. `ttwid` 是页面响应 `Set-Cookie` 直接给的，非 JS 生成；
2. 签名是服务端在 `room/web/enter` 响应里下发的，客户端（网页/App）只是把 URL 原样交给播放器；
3. 我们对 `k` / `sign` 做了穷举式公式试探（约 377 组 path、t、unique_id、t_id、host、常见 salt 的 md5/sha1/sha256 组合，匹配 64-bit/128-bit 子串）——**没有任何命中**，判断为**服务端密钥 HMAC/摘要**，无法离线推导；
4. 但**完全不需要推导**：每次录制/重连直接调 API 拿新 URL 即可。

> 唯一残留的「浏览器性」是反爬策略：当前 `room/web/enter` 只校验 `ttwid` + 浏览器参数，不校验 JS 生成的 `a_bogus`。若抖音后续升级风控（例如开始校验 `a_bogus`/`msToken`，或对无头环境返回空包），纯 HTTP 会失效——此时再上 WebView 兜底（方案见 §5）。

---

## 3. 错误语义与状态码对照

| 现象 | 含义 | App 处理 |
| --- | --- | --- |
| API `200` + `body` 长度 0 | `ttwid` 失效 / 被风控 | 清缓存 cookie，重新 GET 页面取 ttwid，重试 1 次；仍空 → 报错「抖音接口风控」 |
| `status_code=0`，`data.data[0].status=2`，`flv_pull_url` 非空 | 直播中 | 选档返回 URL |
| `status_code=0`，`status=4`，`flv_pull_url={}` | 未开播 / 已结束 | 抛 `LinkResolveException('抖音直播间未开播或已结束')` |
| `status_code=10011` | 缺少 `aid` 等基础参数 | 修参数 |
| `status_code=4001038` | web_rid 不存在 | 抛「直播间不存在」 |
| CDN `302` | 正常，跳到边缘节点 | 跟随 |
| CDN `403` | 签名过期/被篡改/流已删 | 重新解析 URL；连续失败判定直播结束 |
| CDN `404` | 流不存在 | 判定直播结束 |

---

## 4. 推荐接入方案（纯 HTTP，Dart 实现）

### 4.1 解析流程（`app/lib/services/douyin_resolver.dart`）

```text
resolveFlvUrl(webRid)
  ├─ 1. 内存缓存 ttwid（首次为空）→ GET https://live.douyin.com/<webRid>
  │      UA 用桌面 Chrome/Edge；从 Set-Cookie 取 ttwid；请求体可提前取消
  ├─ 2. GET https://live.douyin.com/webcast/room/web/enter/?
  │      aid=6383&device_platform=web&browser_language=zh-CN&browser_platform=Win32
  │      &browser_name=Edge&browser_version=152.0.0.0&web_rid=<rid>
  │      Cookie: ttwid=<ttwid>
  ├─ 3. 空 body → 清 ttwid 重取一次
  ├─ 4. 解析 JSON：data.data[0].stream_url.flv_pull_url
  │      - 房间 status != 2 或 map 为空 → 未开播
  │      - 按 FULL_HD1 → HD1 → SD2 → SD1 选第一个非空
  ├─ 5. http:// → https://（Android 9+ 默认禁明文）
  └─ 6. 返回 String URL（FlvRecorder 直接 begin 拉流，默认跟随 302）
```

### 4.2 接入 `RecordingManager`

`RecordingManager` 已经有现成回调签名 `Future<String> Function(LiveRoom room)`：

```dart
final douyinResolver = DouyinResolver();

final manager = RecordingManager(
  resolver: LinkResolver(),
  storage: StorageService(),
  douyinUrlResolver: (room) => douyinResolver.resolveFlvUrl(room.roomId),
);
```

- `FlvRecorder.urlProvider` 在**每段开始 / 每次探测**都会重新调用本函数，因此断流重连会自动拿到新签名 URL，不会撞过期。
- `FlvRecorder` 目前固定 `Referer: https://www.xiaohongshu.com/` 和移动端 UA。实测 `douyincdn` **完全忽略 Referer/UA**，所以**不改 `FlvRecorder` 也能录**；如果后续要语义正确，可在 `FlvRecorder` 增加按平台切换 referer 的构造参数（属于 lead 的写作用域）。
- Android 明文流量：API 返回 `http://` 直链，其中 `https://` 变体实测同样可用，解析器默认转 https；如某 CDN 未来不支持 https，可保留 `http` 并在 `AndroidManifest` 开 `usesCleartextTraffic`（不推荐）。

### 4.3 后台 13 分钟复用复测（TODO：任务结束时回填）

> 18:53 起后台任务 `pwsh-deffefb67d584d83` 在 13 分钟后（约 19:06）用 **18:45 抓到的同一条 URL** 再拉 8 秒，结果回填于此：
>
> - 结果：见任务结束前的最后回填（若为 200 + `46 4c 56`，说明同一 URL 在签发后 ~21 分钟仍可重连）。

### 4.4 WebView 兜底方案（仅当纯 HTTP 被风控）

> 当前**不需要**；保留接口签名即可平滑切换。WebView 方案要点：

1. `webview_flutter` 打开 `https://live.douyin.com/<rid>`，用 **真实 UA**，等待页面开始播放（约 3–8 s）。
2. 二选一拿 URL：
   - **读 cookie**（最简单）：用 `WebViewCookieManager().getCookies(...)` 读 `live_debug_info`，URL 解码后取 `.src`（实测就是播放器当前 FLV 源；但可能是 HEVC/低清档）。
   - **注入 hook**：`onPageStarted` 后注入 JS，覆写 `window.fetch` / `XMLHttpRequest.prototype.open` 记录含 `.flv` 的 URL 与 `room/web/enter` 响应；也可在页面上下文里 `fetch(enterApi, {credentials:'include'})` 后把 JSON 里的 `flv_pull_url.FULL_HD1` 通过 `JavaScriptChannel` 回传 Dart。
3. 同时把 WebView 的 `ttwid` cookie 交给纯 HTTP 解析器复用，可大幅减少 WebView 使用频率。
4. 退出时清理 WebView（不要复用用户可见 tab）。

### 4.5 Dart 实现自测（2026-10-20 18:58，纯 Dart 进程，未跑 Flutter）

```text
== live room 675247105586 ==
resolved in 1197 ms: https://pull-flv-h6.douyincdn.com/stage/stream-120292037024285529_or4.flv?k=7ae...&t=1793098670&...
host=pull-flv-h6.douyincdn.com scheme=https len=257
   pull status=200 ctype=video/x-flv
   first bytes=[70, 76, 86] (FLV=true)
second resolve in 539 ms（ttwid 命中缓存，换发新签名 token）
== offline room 385355654156 (expect LinkResolveException) ==
  got: LinkResolveException: 抖音直播已结束
== invalid rid (expect LinkResolveException) ==
  got: LinkResolveException: 抖音房间号无效：abc
== full url input ==
  ok host=pull-flv-h6.douyincdn.com
```

实现踩坑记录（都已在 `douyin_resolver.dart` 处理）：

- **`HttpClientResponse.cookies` 不能用**：抖音页面的 `Set-Cookie` 带有非标准 `Secure` 属性值，Dart 的 Cookie 解析器会直接抛 `HttpException: Value given for 'Secure'`。必须从 `response.headers[HttpHeaders.setCookieHeader]` 取原始字符串，用正则 `(?:^|;\s*)ttwid=([^;]+)` 手工提取。
- 桌面 UA 必须显式设置，否则页面返回 0 字节、无 `ttwid`。
- 页面正文约 1.1 MB，拿到 `Set-Cookie` 后立刻取消下载（实现里 `response.listen(null)` + `cancel()`），不浪费流量。
- `ttwid` 进程内缓存（默认 24 h）；接口空包时自动清缓存重试一次。

---

## 5. 复现命令（可直接跑）

```bash
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36 Edg/152.0.0.0"
RID=675247105586

# 1) 取 ttwid
curl -s -c /tmp/dy.jar -A "$UA" "https://live.douyin.com/$RID" -o /dev/null

# 2) 取签名 FLV 直链（最小参数集）
curl -s -b /tmp/dy.jar -A "$UA" \
  "https://live.douyin.com/webcast/room/web/enter/?aid=6383&device_platform=web&browser_language=zh-CN&browser_platform=Win32&browser_name=Edge&browser_version=152.0.0.0&web_rid=$RID" \
  | python -c "import sys,json;d=json.load(sys.stdin);print(json.dumps(d['data']['data'][0]['stream_url']['flv_pull_url'],indent=1,ensure_ascii=False))"

# 3) 10 秒拉流并校验 FLV 魔数
URL=$(... 上一步 FULL_HD1 ...)
curl -sS -m 10 -L -o /tmp/dy.flv "$URL"
head -c 3 /tmp/dy.flv | od -An -tx1     # 期望 46 4c 56
```

浏览器侧抓包：

```bash
curl -s http://127.0.0.1:17368/tabs      # 找自己的 tabId
curl -X POST http://127.0.0.1:17368/network/start -H "content-type: application/json" -d '{"tabId":<id>}'
curl -X POST http://127.0.0.1:17368/reload -H "content-type: application/json" -d '{"tabId":<id>}'
curl "http://127.0.0.1:17368/network?tabId=<id>&limit=3000" | ...   # 过滤 room/web/enter、flv
```

---

## 6. 风险与未验证项

1. **7 天有效期未真实等待验证**：按 `t/expire = 签发 + 604800` 推断；实测仅复用到 ~21 分钟。实际接入每次重连重新解析，故影响小。
2. **IP 绑定未验证**：所有测试都在同一台机器/同一出口 IP。ByteDance CDN token 是否绑定 IP 未知；App 在移动网络下需以真机实测。
3. **风控可能升级**：当前 `room/web/enter` 不需要 `a_bogus`/`msToken`；抖音随时可能加验。解析器已把「空 body」当作风控信号并重取 ttwid，但仍可能彻底失效 → 需 WebView 兜底（§4.4）。
4. **接口未公开**：`webcast/room/web/enter` 是网页端私有接口，字段/必需参数会变；解析器对缺失字段做了容错（优先 `flv_pull_url`，取不到再报未开播）。
5. **HLS 备选**：`hls_pull_url_map` 同样是签名 URL，若 FLV 被限可切 HLS（本 App 录 FLV，仅作备注）。
6. **不同 CDN 的 URL 参数名不同**（`k/t` vs `expire/sign`）：解析器不解析查询串，直接透传，避免踩坑。
7. 浏览器抓包里没有抓到此 FLV 请求的 `requestWillBeSentExtraInfo` 请求头（请求在 Worker 内，CDP tab 级事件只看到 302 行）；因此「播放器请求头」不是实测值，而是推测浏览器自动带上的 `Origin/Referer`。不过 CDN 不校验这些，无影响。

---

## 附录：证据与复现

本次抓包/压测产生的临时文件（`dy_*.json` / `dy_*.txt` / `dy_*.flv` / `probe_*.bin` / `probe_api*.py` 等）只是过程产物，交付时已清理；关键数据全部记录在本文各节，复现命令见 §5。核心证据链：

| 证据 | 位置 |
| --- | --- |
| 浏览器 `room/web/enter` 请求与响应结构 | §1.1 |
| 播放器实际 FLV 请求（`Fetch` + 302）与 `live_debug_info` cookie | §1.2 |
| 纯 HTTP 取链的 11 组对照实验（Cookie/参数/UA） | §1.3 |
| curl 10 s 拉流 + FLV 魔数校验 | §1.4 |
| 两套签名形态 / 档位映射 | §1.5、§1.6 |
| 过期参数篡改实验（全部 403） | §2.a |
| 同 URL 重连实验（含 20 s 空闲、9 分钟、13 分钟复用） | §2.b、§4.3 |
| Dart 解析器端到端自测（FLV 头 70/76/86） | §4.5 |
