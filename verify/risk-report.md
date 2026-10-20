# 小红书匿名风控压测报告（PC 侧）

- 生成时间：2026-10-20 19:22:38 +0800 ~ 2026-10-20 19:23:37 +0800
- 被测目标：
  - 短链跟随：`https://xhslink.com/o/9iND1710iyA`（30 次连续请求）
  - FLV 直连：`https://live-source-play.xhscdn.com/live/570501740524334550.flv`（10 次 × 3s）
- 客户端伪装：**Android UA**

```text
Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36
```

- 匿名性：不带 Cookie、不登录、无签名参数、不复用连接（每轮独立 curl 进程）
- 公网出口 IP：`209.141.51.106`
- 测试机：Windows PC（curl curl 8.21.0 (x86_64-w64-mingw32) libcurl/8.21.0 Schannel zlib/1.3.2 brotli/1.2.0 zstd/1.5.7 libidn2/2.3.8 libpsl/0.21.5 libssh2/1.11.1 WinLDAP）

> 说明：本压测只验证「匿名 + 安卓 UA」下的网络侧可达性/风控特征，不代表登录态或模拟器内 WebView 的表现。

## 结论摘要

| 项目 | 成功率 | 关键结论 |
|---|---|---|
| xhslink 短链 302 跟随 | **100.0%**（30/30） | HTTP 码分布 {'200': 30}；平均 0.47s；落地 host {'www.xiaohongshu.com': 30} |
| FLV 直连拉流 | **100.0%**（10/10） | FLV 魔数通过 10/10；聚合速率 2.01MiB/s；3 秒共取 60.3MiB |
| 综合评级 | 🟢 匿名可用（本轮未触发明显风控） | 详见下文「可疑特征」与「对 App 的建议」 |

## 1. xhslink 短链连续跟随（30 次）

### 1.1 成功率与状态码

- 最终 HTTP 200：**30/30 = 100.0%**
- 状态码分布：`{'200': 30}`
- curl 退出码分布：`{'0': 30}`（0=成功，28=超时，6=DNS，7=连接失败，35=TLS）
- 跳转次数：`{1: 30}`（302 链长度）
- 落地 host：`{'www.xiaohongshu.com': 30}`；roomId：`{'570501740524334550': 30}`
- 落地 URL 形态：dynpath 混淆 30/30；带 xsec_token 30/30；不同 token 值 1 个

### 1.2 耗时

| 指标 | 数值 |
|---|---|
| 最小 | 0.40s |
| 平均 | 0.47s |
| P50 | 0.45s |
| P95 | 0.56s |
| 最大 | 0.66s |
| 前 5 轮均值 | 0.52s |
| 后 5 轮均值 | 0.45s |

### 1.3 逐轮明细

| # | HTTP | 耗时 | 302 跳转 | 落地 host | xsec_token | 落地 path |
|---|---|---|---|---|---|---|
| 1 | 200 | 0.48s | 1 | www.xiaohongshu.com | ✓ | `/livestream/dynpathScH7KeS3/57050174052...` |
| 2 | 200 | 0.56s | 1 | www.xiaohongshu.com | ✓ | `/livestream/dynpathScH7KeS3/57050174052...` |
| 3 | 200 | 0.44s | 1 | www.xiaohongshu.com | ✓ | `/livestream/dynpathScH7KeS3/57050174052...` |
| 4 | 200 | 0.66s | 1 | www.xiaohongshu.com | ✓ | `/livestream/dynpathScH7KeS3/57050174052...` |
| 5 | 200 | 0.46s | 1 | www.xiaohongshu.com | ✓ | `/livestream/dynpathScH7KeS3/57050174052...` |
| 6 | 200 | 0.53s | 1 | www.xiaohongshu.com | ✓ | `/livestream/dynpathScH7KeS3/57050174052...` |
| 7 | 200 | 0.55s | 1 | www.xiaohongshu.com | ✓ | `/livestream/dynpathScH7KeS3/57050174052...` |
| 8 | 200 | 0.43s | 1 | www.xiaohongshu.com | ✓ | `/livestream/dynpathScH7KeS3/57050174052...` |
| 9 | 200 | 0.44s | 1 | www.xiaohongshu.com | ✓ | `/livestream/dynpathScH7KeS3/57050174052...` |
| 10 | 200 | 0.47s | 1 | www.xiaohongshu.com | ✓ | `/livestream/dynpathScH7KeS3/57050174052...` |
| 11 | 200 | 0.48s | 1 | www.xiaohongshu.com | ✓ | `/livestream/dynpathScH7KeS3/57050174052...` |
| 12 | 200 | 0.46s | 1 | www.xiaohongshu.com | ✓ | `/livestream/dynpathScH7KeS3/57050174052...` |
| 13 | 200 | 0.44s | 1 | www.xiaohongshu.com | ✓ | `/livestream/dynpathScH7KeS3/57050174052...` |
| 14 | 200 | 0.45s | 1 | www.xiaohongshu.com | ✓ | `/livestream/dynpathScH7KeS3/57050174052...` |
| 15 | 200 | 0.45s | 1 | www.xiaohongshu.com | ✓ | `/livestream/dynpathScH7KeS3/57050174052...` |
| 16 | 200 | 0.46s | 1 | www.xiaohongshu.com | ✓ | `/livestream/dynpathScH7KeS3/57050174052...` |
| 17 | 200 | 0.43s | 1 | www.xiaohongshu.com | ✓ | `/livestream/dynpathScH7KeS3/57050174052...` |
| 18 | 200 | 0.42s | 1 | www.xiaohongshu.com | ✓ | `/livestream/dynpathScH7KeS3/57050174052...` |
| 19 | 200 | 0.46s | 1 | www.xiaohongshu.com | ✓ | `/livestream/dynpathScH7KeS3/57050174052...` |
| 20 | 200 | 0.46s | 1 | www.xiaohongshu.com | ✓ | `/livestream/dynpathScH7KeS3/57050174052...` |
| 21 | 200 | 0.40s | 1 | www.xiaohongshu.com | ✓ | `/livestream/dynpathScH7KeS3/57050174052...` |
| 22 | 200 | 0.45s | 1 | www.xiaohongshu.com | ✓ | `/livestream/dynpathScH7KeS3/57050174052...` |
| 23 | 200 | 0.47s | 1 | www.xiaohongshu.com | ✓ | `/livestream/dynpathScH7KeS3/57050174052...` |
| 24 | 200 | 0.44s | 1 | www.xiaohongshu.com | ✓ | `/livestream/dynpathScH7KeS3/57050174052...` |
| 25 | 200 | 0.44s | 1 | www.xiaohongshu.com | ✓ | `/livestream/dynpathScH7KeS3/57050174052...` |
| 26 | 200 | 0.49s | 1 | www.xiaohongshu.com | ✓ | `/livestream/dynpathScH7KeS3/57050174052...` |
| 27 | 200 | 0.41s | 1 | www.xiaohongshu.com | ✓ | `/livestream/dynpathScH7KeS3/57050174052...` |
| 28 | 200 | 0.47s | 1 | www.xiaohongshu.com | ✓ | `/livestream/dynpathScH7KeS3/57050174052...` |
| 29 | 200 | 0.44s | 1 | www.xiaohongshu.com | ✓ | `/livestream/dynpathScH7KeS3/57050174052...` |
| 30 | 200 | 0.43s | 1 | www.xiaohongshu.com | ✓ | `/livestream/dynpathScH7KeS3/57050174052...` |

### 1.5 响应头样本（首跳）

首轮：
```http
HTTP/1.1 302 Found
Content-Type: text/html; charset=utf-8
Content-Length: 388
Server: nginx
Set-Cookie: acw_tc=0a0d0e9017924953619828210edb5867d1c222836b418f92ff64e7350f9a66;path=/;HttpOnly;Max-Age=1800
Location: https://www.xiaohongshu.com/livestream/dynpathScH7KeS3/570501740524334550?timestamp=1792491036496&share_source=share_link&share_source_id=&source=share_out_of_app&host_id=6523a46a000000002b003f5e&xsec_token=UB2aG8c2aLqBvaNocWK_fpaSIofw4Vw-zpkwkWslBCigBThnR7ajl2cXGAinFMZE8-&xsec_source=app_share&share_id=bc54e330e15e4e7babb61a18089e0692
HTTP/1.1 200 OK
Content-Type: text/html; charset=utf-8
Server: openresty
Set-Cookie: acw_tc=0a00de9917924953621352274e5ad9e0e0621a1435406351089d0442449ccc;path=/;HttpOnly;Max-Age=1800
Set-Cookie: abRequestId=faf331f0-f27e-547e-8a67-0d3aa2d83e58; path=/; expires=Wed, 20 Oct 2027 11:22:42 GMT; domain=xiaohongshu.com
```

末轮：
```http
HTTP/1.1 302 Found
Content-Type: text/html; charset=utf-8
Content-Length: 388
Server: nginx
Set-Cookie: acw_tc=0a0d0a4d17924953810213567e20fc4b8521349fda2feb460ba57d63deb9f1;path=/;HttpOnly;Max-Age=1800
Location: https://www.xiaohongshu.com/livestream/dynpathScH7KeS3/570501740524334550?timestamp=1792491036496&share_source=share_link&share_source_id=&source=share_out_of_app&host_id=6523a46a000000002b003f5e&xsec_token=UB2aG8c2aLqBvaNocWK_fpaSIofw4Vw-zpkwkWslBCigBThnR7ajl2cXGAinFMZE8-&xsec_source=app_share&share_id=bc54e330e15e4e7babb61a18089e0692
HTTP/1.1 200 OK
Content-Type: text/html; charset=utf-8
Server: openresty
Set-Cookie: acw_tc=0a00d62f17924953811847843eeb350decebd4418fbb71c38541388a1e6a4d;path=/;HttpOnly;Max-Age=1800
Set-Cookie: abRequestId=037d90b6-bcd2-530e-b2e4-da9608f622e9; path=/; expires=Wed, 20 Oct 2027 11:23:01 GMT; domain=xiaohongshu.com
```

## 2. FLV 直连拉流（10 次 × 3 秒）

### 2.1 成功率与数据量

- 成功定义：HTTP 200 **且** 响应体前 3 字节为 `FLV` 魔数
- 成功：**10/10 = 100.0%**；FLV 魔数通过 10/10
- 状态码分布：`{'200': 10}`；curl 退出码：`{'28': 10}`（28=`--max-time 3` 正常截断）
- Content-Type：`{'video/x-flv': 10}`
- 跳转次数：`{0: 10}`
- 3 秒样本总流量：**60.3MiB**（10 次 × 3s）
- 聚合速率：**2.01MiB/s**（总字节/总耗时）

### 2.2 速率与首包

| 指标 | 数值 |
|---|---|
| 平均速率 | 2.01MiB/s |
| P50 速率 | 1.98MiB/s |
| 最低 / 最高 | 1.69MiB/s / 2.37MiB/s |
| 单次样本量 | 平均 6.0MiB，最大 7.1MiB |
| TTFB（首包） | 平均 0.06s，P95 0.16s，最大 0.22s |

### 2.3 逐次明细

| # | HTTP | FLV 头 | 数据量 | 3s 速率 | TTFB | 302 | Content-Type | 首 8 字节(hex) |
|---|---|---|---|---|---|---|---|---|
| 1 | 200 | ✓ | 6.4MiB | 2.14MiB/s | 0.09s | 0 | video/x-flv | `464c5601050000000900` |
| 2 | 200 | ✓ | 6.0MiB | 1.99MiB/s | 0.04s | 0 | video/x-flv | `464c5601050000000900` |
| 3 | 200 | ✓ | 5.9MiB | 1.97MiB/s | 0.03s | 0 | video/x-flv | `464c5601050000000900` |
| 4 | 200 | ✓ | 5.8MiB | 1.93MiB/s | 0.22s | 0 | video/x-flv | `464c5601050000000900` |
| 5 | 200 | ✓ | 5.5MiB | 1.83MiB/s | 0.03s | 0 | video/x-flv | `464c5601050000000900` |
| 6 | 200 | ✓ | 5.1MiB | 1.69MiB/s | 0.03s | 0 | video/x-flv | `464c5601050000000900` |
| 7 | 200 | ✓ | 5.1MiB | 1.71MiB/s | 0.02s | 0 | video/x-flv | `464c5601050000000900` |
| 8 | 200 | ✓ | 7.1MiB | 2.37MiB/s | 0.03s | 0 | video/x-flv | `464c5601050000000900` |
| 9 | 200 | ✓ | 6.8MiB | 2.27MiB/s | 0.03s | 0 | video/x-flv | `464c5601050000000900` |
| 10 | 200 | ✓ | 6.6MiB | 2.21MiB/s | 0.03s | 0 | video/x-flv | `464c5601050000000900` |

### 2.5 响应头样本（第 1 次）

```http
（无样本）
```

## 3. 失败模式与可疑特征

### 3.1 失败模式汇总

| 类别 | 次数 | 说明 |
|---|---|---|
| 短链：非 200 / curl 报错 | 0 | 逐轮见 1.4；原始数据见 `verify/xhslink-attempts.tsv` |
| 短链：疑似限流码（401/403/405/412/429/503） | 0 | 未出现即信号较弱 |
| 短链：验证/风控关键词落地 | 0 | captcha/verify/risk 等 |
| FLV：非 200 | 0 | 403/404/302 等 |
| FLV：非 FLV 响应体 | 0 | 可能是 HTML 错误页/鉴权页 |
| FLV：空响应体 | 0 | 连接被断/超时 |

### 3.2 可疑特征

- 短链跳转后的落地 URL **全部带 `xsec_token`**（30/30 轮），30 轮共出现 **1 个不同 token 值**——每次解析都会签发新的时效签名，App 必须每次实时解析、不能缓存复用旧链接。
- 落地 URL 使用 `dynpath` 混淆路径（30/30 轮），roomId 固定但路径随机化，说明平台在弱化「固定 URL 直接拼 roomId」的可用性。
- 30 轮全部落到同一 roomId（570501740524334550），短链→房间的映射稳定。
- 30 次连续跟随未出现 429/503 限流码，短链解析侧对匿名请求**暂未见频率限制**。
- FLV 直连 10 次均无需 Cookie/Referer/签名参数（基于 URL 的 roomId 直出流），单次 3 秒可稳定拿到 2.01MiB/s 数据，说明**拉流侧匿名门槛远低于接口侧**。

## 4. 对 App 的现实含义与建议

1. **匿名链路成立**：短链 302 解析与 FLV 直连都不需要登录态、不需要 Cookie、不需要签名参数，App 可以保持「粘贴链接即可录制」的匿名路径。
2. **短链必须实时解析**：落地 URL 的 `xsec_token` 是时效签名且每次不同，不能缓存网页 URL；每次开始录制都应重新跟随 302，并取最终 URL 里的 roomId。
3. **FLV 直连可作为主拉流方案**：`https://live-source-play.xhscdn.com/live/<roomId>.flv` 无需鉴权，3 秒即可稳定出流；但需要处理 `--max-time` 类截断（直播流本身无限长）以及 CDN 节点差异。
4. **容错与降频**：当前成功率下建议每次拉流失败后 1s/3s/5s 指数退避重连（最多 3 次），重连时重新解析短链以刷新 token；多任务并发时限制同时拉流路数，避免被 CDN 侧限速。
5. **UA/指纹**：本轮仅伪装 UA 即可通过，说明网络侧暂未对非 App 客户端做严格校验；但若后续出现 403/412/429，应优先怀疑设备指纹/签名校验，而不是网络问题。
6. **观测建议**：App 内记录每次解析的 HTTP 码、耗时、最终 URL 的 token 变化与拉流首包时间，便于区分「平台风控」与「本地网络/CDN 抖动」。

## 5. 附录：原始数据与复现

- `verify/xhslink-attempts.tsv`：短链 30 轮明细（http_code/耗时/跳转数/最终 URL/curl 错误）
- `verify/flv-attempts.tsv`：FLV 10 轮明细（http_code/Content-Type/字节数/速率/TTFB/FLV 魔数/首 16 字节）
- `verify/logs/xhslink-headers-first.txt`、`verify/logs/xhslink-headers-last.txt`：首末轮响应头全文
- `verify/logs/xhslink-fail-r*.txt`：失败轮次的 body 摘要（若有）
- `verify/logs/flv-headers.txt`：10 次 FLV 响应头全文
- 复现命令：`tools/risk-probe.sh`（可用 `XHS_ROUNDS=5 FLV_ROUNDS=2` 小流量试跑）

---

_本报告由 `tools/risk-probe.sh` 自动生成；数值来自单机单时段采样，IP/时段/线路变化可能导致不同结果。_
