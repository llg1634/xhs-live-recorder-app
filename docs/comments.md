# 小红书直播弹幕采集（已验证）

> 状态：**链路已跑通**（2026-10-20 实测，模拟器 Android 9 + Chrome 104 WebView）
> 抖音弹幕未做，见文末。

## 1. 原脚本用的是哪条路

`E:\renwu2\260705录制抖音优化\xhs-live-webui-recorder.js` **不是从 DOM 扒弹幕**，
而是用 CDP 监听页面自身长连接的 WebSocket 帧：

```
Network.webSocketFrameReceived
  → JSON.parse(frame)
  → outer.b.d.b[]                      // 批量消息数组
  → item.d 是 base64
  → base64 解码成 JSON
  → JSON.customData.type === "text"    // 进场是 audience_join_v2、点赞是 praise…
  → JSON.customData.desc               // 评论正文
  → JSON.customData.profile.nickname   // 昵称
```

## 2. Android 上没有 CDP，怎么等价实现

用 **WebView + 注入 hook** 替代 CDP，实测可行：

| 环节 | 实测结果 |
|---|---|
| WebView 打开直播间（桌面 UA） | ✅ 页面正常，视频能播（1920×1080，readyState=4） |
| 长连接地址 | ✅ `wss://apppush-rws.xiaohongshu.com/rwp` |
| 长连接是否在主线程 | ✅ **在主线程**，`window.WebSocket` 构造函数 hook 有效（不在 Worker 里） |
| 帧解码 | ✅ base64 → customData → type/desc/profile 全部正确 |
| 匿名（不登录） | ✅ 可以收到评论 |
| 1×1 极小视口隐藏 | ❌ **收不到评论帧**（只收到进场/点赞），页面没挂载评论区就不订阅评论 topic |
| 真实视口 + 不透明层覆盖 | ✅ **能收到**，用户看不见页面 |
| 采集时暂停页面 `<video>` | ✅ 评论照收，省 CPU/流量 |

结论：**隐藏采集 = 真实尺寸 WebView（不透明层盖住）+ 文档早期注入 hook + 暂停 video**。

## 3. 注入脚本要点（可直接复用）

```js
// 必须在文档早期注入（Flutter 侧在 onPageStarted 注入，幂等 guard）
var OWS = window.WebSocket;
function WS(u, p) {
  var sock = new OWS(u, p);
  sock.addEventListener('message', function (ev) { handleFrame(ev.data); });
  return sock;
}
WS.prototype = OWS.prototype;
window.WebSocket = WS;

function handleFrame(data) {
  var outer = JSON.parse(data);                 // {v,t,m,b}
  if (!outer.b || !outer.b.d || !Array.isArray(outer.b.d.b)) return;
  outer.b.d.b.forEach(function (item) {
    var payload = JSON.parse(b64utf8(item.d));  // item.d 是 base64
    var cd = typeof payload.customData === 'string'
        ? JSON.parse(payload.customData) : payload.customData;
    if (cd && cd.type === 'text') {
      // cd.profile.nickname + cd.desc + cd.commentId + payload.ts
    }
  });
}
```

注意：`customData` 是**字符串形式的 JSON**，要再 parse 一层。

## 4. 实测抓到的一条完整数据

```json
{
  "command": 1,
  "customData": "{\"type\":\"text\",\"current_time\":1792505550473,\"source\":\"web_live\",
    \"translated\":false,\"origin_language\":\"num_sp_ch\",
    \"commentId\":\"7698752710945605068\",
    \"profile\":{\"avatar\":\"https://...\",\"nickname\":\"momo\",\"role\":0,
                 \"user_id\":\"6591818f00000000220140e4\",\"follow_status\":0},
    \"desc\":\"1\",\"comment_type\":0,\"aggregate\":false,\"goods_status\":false,
    \"ack_code\":1}",
  "msgId": "1429834670444060672",
  "priority": 2,
  "roomId": "570501740524334550",
  "roomType": "LIVE",
  "ts": 1792505550509
}
```

常见的非评论类型（全部忽略即可）：
`audience_join_v2`（进场）、`praise`（点赞）、`light`（点亮）、`refresh`（房间统计）、
`letter_refresh`、`live_banner_resource`、`goods_rank_entrance_im`、`fansgroup_join_room_effect`。

## 5. 正式实现（已集成）

- 开关：首页输入区「同时录弹幕」，**默认关**，用户按任务手动开启（不设并发上限）。
- 采集层：`lib/ui/widgets/comment_capture_layer.dart` 挂在 `MaterialApp.builder` 里
  **App 内容下面**，所有采集 WebView 共用同一位置 `(0,0,420×900)` 叠放，
  最上面一层挡板 + App 自身不透明背景双重遮盖，用户不可见、不影响操作。
- 服务：`lib/services/comment_capture.dart`
  - `CommentCapture`：单房间采集，注入 hook、解帧、落盘、计数
  - `CommentCaptureManager`：多房间调度 + 看门狗（8 分钟无帧自动重载页面）
- 落盘：`{任务目录}/comments.jsonl`，一行一条评论：
  ```json
  {"ts":1792506440347,"user":"momo","text":"好","commentId":"7698756533492796684"}
  ```
- 展示：任务卡片副标题显示「弹幕 N 条 / 弹幕连接中 / 弹幕采集失败」；
  「录像」页每个场次显示「弹幕 N 条」。

## 6. 稳定性实测（模拟器 Android 9）

| 场景 | 结果 |
|---|---|
| 前台（被覆盖隐藏） | ✅ 22:12:27 抓到「1」 |
| 按 HOME 切后台 | ✅ 22:15:39 抓到「[微笑R]」，10s TICK 未断 |
| 息屏（`mWakefulness=Asleep`） | ✅ 22:16:14 抓到「[飞吻R]」 |
| 录制 + 弹幕同时跑 | ✅ `part01.flv` 与 `comments.jsonl` 同时正常写入 |
| 页面视频暂停后 | ✅ 评论照收（采集不需要拉视频流） |

## 7. 成本与风险

- **内存**：单房间采集时进程 RSS ≈ **450 MB**（含 Flutter 与 Chromium 渲染器）。
  多路会线性叠加，所以默认关、由用户自己决定开几路。
- **风控**：真实桌面 UA 的浏览器会话，与 PC 跑脚本等价；匿名访问未触发验证码。
  若出现验证页，表现为长时间收不到 `text` 帧，看门狗会在 8 分钟后重载页面。
- **后台**：前台服务（`dataSync`）运行期间 WebView 未被系统冻结，实测息屏仍正常。

## 8. 抖音弹幕（已实现）

与小红书完全不同的通道：WebSocket + **二进制 protobuf** 帧。

**已实测通的链路**
- 长连接：`wss://webcast*-ws-web-hl.douyin.com/webcast/im/push/v2/?...&signature=...`
  （URL 由页面自己拼，含 `signature`，我们只旁观，不参与签名）
- 长连接同样在**主线程**，`window.WebSocket` hook 有效
- 帧结构：`PushFrame{ 1:seqid, 2:logid, 3:service, 4:method, 5:headers, 6:payloadEncoding, 7:payloadType, 8:payload }`
- **压缩标记在 headers 里**：`compress_type=gzip`（不是 payloadEncoding，后者是 `pb`）
- payload 解压后是 `Response{ 1: repeated Message }`，
  `Message{ 1: method, 2: payload }`，只处理 `method == "WebcastChatMessage"`；
  `ChatMessage{ 1: common, 2: user, 3: content }`，昵称在 `User.nickname = 3`

**实测输出**
```
DYCHAT 廿舟：质保是什么样的
DYCHAT anyu：双十一抢先购，早买早享受～
methods: WebcastChatMessage 6 / WebcastMemberMessage 8 / WebcastRoomStatsMessage 4 ...
```

实现要点：
- WebView 注入脚本自带**最小 protobuf 解析器**（varint + length-delimited），
  只用 `DecompressionStream('gzip')` 解压，不依赖第三方库
- 抖音采集时**不暂停 video**（暂停会触发部分房间的"主播离开"占位）
- 抖音弹幕页要用 **web_rid**（`live.douyin.com/<web_rid>`）；
  短链解析拿到的常是内部 `room_id`，直接拼 URL 打不开

## 9. 字幕导出（ASS / SRT）

录制停止时自动在录像目录生成 `comments.ass` 和 `comments.srt`，
逻辑移植自原脚本的 `generateAss` / `generateSrt`：

- 画布 1080×1920、字号 42、单条滚动 8 秒、`\move(1080,y,-width,y)` 右→左
- 泳道 `laneHeight = 56`、起点 `top = 140`，同一时刻尽量避免完全重叠
- 时间轴 = `评论时间戳 − 录制开始时间`，和视频天然对齐，可直接挂载播放

实测产物（抖音一场）：
```
part01.flv      47.8 MB
comments.jsonl  555 B
comments.ass    928 B   (3 条 Dialogue)
comments.srt    218 B
```
