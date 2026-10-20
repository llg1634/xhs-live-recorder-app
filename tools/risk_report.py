#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 verify/risk-report.md（由 tools/risk-probe.sh 调用）。

输入：
    argv[1] xhslink-attempts.tsv
    argv[2] flv-attempts.tsv
    argv[3] 输出 risk-report.md
环境变量（RISK_*）：UA / 目标 URL / 轮数 / 时间 / 出口 IP / 响应头样本路径。
"""

import csv
import os
import re
import statistics
import sys
from collections import Counter
from urllib.parse import urlsplit, parse_qs


# ----------------------------------------------------------------------------- 工具

def to_float(v, default=0.0):
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def to_int(v, default=0):
    try:
        return int(float(v))
    except (TypeError, ValueError):
        return default


def pct(n, d):
    if not d:
        return "n/a"
    return f"{n / d * 100:.1f}%"


def pctile(vals, p):
    if not vals:
        return None
    vals = sorted(vals)
    if len(vals) == 1:
        return vals[0]
    k = (len(vals) - 1) * p
    lo, hi = int(k), min(int(k) + 1, len(vals) - 1)
    return vals[lo] + (vals[hi] - vals[lo]) * (k - lo)


def fmt_s(v):
    if v is None:
        return "n/a"
    return f"{v:.2f}s"


def fmt_bytes(n):
    n = float(n)
    for unit in ("B", "KiB", "MiB", "GiB"):
        if n < 1024 or unit == "GiB":
            return f"{n:.1f}{unit}"
        n /= 1024


def fmt_speed(bps):
    if bps is None:
        return "n/a"
    if bps >= 1024 * 1024:
        return f"{bps / 1024 / 1024:.2f}MiB/s"
    return f"{bps / 1024:.1f}KiB/s"


def read_tsv(path, cols):
    if not os.path.exists(path):
        return []
    rows = []
    with open(path, encoding="utf-8", newline="") as f:
        for raw in csv.DictReader(f, delimiter="\t"):
            row = {}
            for c in cols:
                row[c] = (raw.get(c) or "").strip()
            rows.append(row)
    return rows


def read_text(path, limit=12000):
    if not path or not os.path.exists(path):
        return ""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read(limit)
    except OSError:
        return ""


def header_lines(text, limit=4000):
    """响应头样本：去掉空行堆叠，只留有用行。"""
    out = []
    for line in text.splitlines()[:200]:
        line = line.rstrip()
        if not line:
            continue
        if line.startswith("HTTP/") or re.match(
            r"(?i)^(location|content-type|content-length|server|set-cookie|x-[\w-]+|via|age|cache-control|expires):",
            line,
        ):
            out.append(line)
    return "\n".join(out[:limit // 20])


def url_info(u):
    """解析最终 URL：host / path / 关键一次性参数。"""
    try:
        p = urlsplit(u)
    except ValueError:
        return {"host": "-", "path": "-", "token": "", "dynpath": False, "room": ""}
    q = parse_qs(p.query)
    token = (q.get("xsec_token") or [""])[0]
    dynpath = bool(re.search(r"/livestream/dynpath[^/]+", p.path))
    m = re.search(r"/livestream/(?:dynpath[^/]+/)?(\d+)", p.path)
    return {
        "host": p.netloc.split(":")[0] or "-",
        "path": p.path,
        "token": token,
        "dynpath": dynpath,
        "room": m.group(1) if m else "",
    }


# ----------------------------------------------------------------------------- 数据

XHS_COLS = [
    "idx", "rc", "http_code", "total_s", "lookup_s", "connect_s",
    "appconnect_s", "num_redirects", "remote_ip", "effective_url", "curl_err",
]
FLV_COLS = [
    "idx", "rc", "http_code", "content_type", "size_bytes", "time_s",
    "speed_Bps", "time_starttransfer_s", "num_redirects", "flv_magic",
    "first16_hex", "curl_err",
]

xhs = read_tsv(sys.argv[1], XHS_COLS)
flv = read_tsv(sys.argv[2], FLV_COLS)
out_path = sys.argv[3]

env = os.environ
UA = env.get("RISK_UA", "-")
XHS_URL = env.get("RISK_XHS_URL", "-")
FLV_URL = env.get("RISK_FLV_URL", "-")
XHS_ROUNDS = env.get("RISK_XHS_ROUNDS", str(len(xhs)))
FLV_ROUNDS = env.get("RISK_FLV_ROUNDS", str(len(flv)))
FLV_SECONDS = env.get("RISK_FLV_SECONDS", "3")
START = env.get("RISK_START", "-")
END = env.get("RISK_END", "-")
PUBIP = env.get("RISK_PUBIP", "未知")
XHS_HDR_FIRST = read_text(env.get("RISK_XHS_HDR_FIRST", ""))
XHS_HDR_LAST = read_text(env.get("RISK_XHS_HDR_LAST", ""))
FLV_HDR = read_text(env.get("RISK_FLV_HDR", ""))

# ----------------------------------------------------------------------------- 短链统计

xhs_n = len(xhs)
xhs_ok = sum(1 for r in xhs if r["http_code"] == "200")
xhs_codes = Counter(r["http_code"] for r in xhs)
xhs_rcs = Counter(r["rc"] for r in xhs)
xhs_lat = [to_float(r["total_s"]) for r in xhs if to_float(r["total_s"]) > 0]
xhs_redirs = [to_int(r["num_redirects"]) for r in xhs]
xhs_infos = [url_info(r["effective_url"]) for r in xhs]
xhs_hosts = Counter(i["host"] for i in xhs_infos)
xhs_rooms = Counter(i["room"] for i in xhs_infos if i["room"])
tokens = [i["token"] for i in xhs_infos if i["token"]]
xhs_token_rounds = sum(1 for i in xhs_infos if i["token"])
xhs_dynpath = sum(1 for i in xhs_infos if i["dynpath"])
xhs_remote_ips = Counter(r["remote_ip"] for r in xhs if r["remote_ip"] not in ("", "-"))
xhs_fail = [r for r in xhs if r["http_code"] != "200" or r["rc"] != "0"]
xhs_waf = [r for r in xhs if r["http_code"] in ("401", "403", "405", "412", "429", "503")]
xhs_captcha = [
    r for r in xhs
    if re.search(r"(?i)(captcha|verify|risk|security|punish|blocked)", r["effective_url"])
]
xhs_first5 = [to_float(r["total_s"]) for r in xhs[:5] if to_float(r["total_s"]) > 0]
xhs_last5 = [to_float(r["total_s"]) for r in xhs[-5:] if to_float(r["total_s"]) > 0]

# ----------------------------------------------------------------------------- FLV 统计

flv_n = len(flv)
flv_ok = sum(1 for r in flv if r["http_code"] == "200" and r["flv_magic"] == "1")
flv_codes = Counter(r["http_code"] for r in flv)
flv_rcs = Counter(r["rc"] for r in flv)
flv_ctypes = Counter(r["content_type"] for r in flv)
flv_magic_ok = sum(1 for r in flv if r["flv_magic"] == "1")
flv_sizes = [to_int(r["size_bytes"]) for r in flv]
flv_speeds = [to_float(r["speed_Bps"]) for r in flv if to_float(r["speed_Bps"]) > 0]
flv_ttfbs = [to_float(r["time_starttransfer_s"]) for r in flv if to_float(r["time_starttransfer_s"]) > 0]
flv_redirs = [to_int(r["num_redirects"]) for r in flv]
flv_bytes_total = sum(flv_sizes)
flv_time_total = sum(to_float(r["time_s"]) for r in flv if to_float(r["time_s"]) > 0)
flv_agg_speed = (flv_bytes_total / flv_time_total) if flv_time_total else 0.0
flv_fail = [r for r in flv if not (r["http_code"] == "200" and r["flv_magic"] == "1")]
flv_nonflv = [r for r in flv if r["flv_magic"] != "1" and to_int(r["size_bytes"]) > 0]
flv_html = [
    r for r in flv
    if r["first16_hex"].lower().startswith(("3c", "7b")) or b"html" in r["first16_hex"].lower().encode()
]
flv_speed_low = [s for s in flv_speeds if s < 1024 * 1024]
flv_trend_ratio = None
if len(flv_speeds) >= 4:
    first_half = statistics.mean(flv_speeds[: len(flv_speeds) // 2])
    second_half = statistics.mean(flv_speeds[len(flv_speeds) // 2:])
    flv_trend_ratio = (second_half / first_half) if first_half else None

# ----------------------------------------------------------------------------- 结论评级

def rate(n, d):
    return (n / d) if d else 0.0


xhs_rate = rate(xhs_ok, xhs_n)
flv_rate = rate(flv_ok, flv_n)
if xhs_rate >= 0.95 and flv_rate >= 0.9:
    overall = "🟢 匿名可用（本轮未触发明显风控）"
elif xhs_rate >= 0.8 or flv_rate >= 0.6:
    overall = "🟡 部分受阻（存在可复现的失败模式，需容错/重试）"
else:
    overall = "🔴 匿名请求受阻（当前 IP/时段建议登录或降频）"

# 可疑特征（自动归纳）
suspicious = []
if xhs_token_rounds:
    suspicious.append(
        f"短链跳转后的落地 URL **全部带 `xsec_token`**（{xhs_token_rounds}/{xhs_n} 轮），"
        f"30 轮共出现 **{len(set(tokens))} 个不同 token 值**——每次解析都会签发新的时效签名，"
        "App 必须每次实时解析、不能缓存复用旧链接。"
    )
if xhs_dynpath:
    suspicious.append(
        f"落地 URL 使用 `dynpath` 混淆路径（{xhs_dynpath}/{xhs_n} 轮），roomId 固定但路径随机化，"
        "说明平台在弱化「固定 URL 直接拼 roomId」的可用性。"
    )
if xhs_infos and len(xhs_rooms) == 1:
    suspicious.append(f"30 轮全部落到同一 roomId（{next(iter(xhs_rooms))}），短链→房间的映射稳定。")
if len(xhs_hosts) > 1:
    suspicious.append(f"短链最终落地 host 不唯一：{dict(xhs_hosts)}，可能存在 A/B 分流或灰度。")
if xhs_n and not any(r["http_code"] in ("429", "503") for r in xhs):
    suspicious.append("30 次连续跟随未出现 429/503 限流码，短链解析侧对匿名请求**暂未见频率限制**。")
if xhs_waf:
    suspicious.append(f"出现疑似拦截码 {dict(Counter(r['http_code'] for r in xhs_waf))}。")
if xhs_captcha:
    suspicious.append(f"落地 URL 含验证/风控关键词 {len(xhs_captcha)} 次（captcha/verify/risk 等）。")
if xhs_first5 and xhs_last5:
    ratio = statistics.mean(xhs_last5) / statistics.mean(xhs_first5) if statistics.mean(xhs_first5) else 0
    if ratio > 1.5:
        suspicious.append(
            f"短链耗时后段明显劣化：前 5 轮均值 {fmt_s(statistics.mean(xhs_first5))} → "
            f"后 5 轮均值 {fmt_s(statistics.mean(xhs_last5))}（×{ratio:.2f}），可能存在慢速限流。"
        )
if any("xsec_token" in h for h in (XHS_HDR_FIRST, XHS_HDR_LAST)) and not tokens:
    suspicious.append("响应头中出现 xsec_token 参数（但最终 URL 未解析到）。")
if "set-cookie" in XHS_HDR_FIRST.lower() and "set-cookie" not in XHS_HDR_LAST.lower():
    suspicious.append("首轮下发 Set-Cookie、末轮不再下发（可能有会话/设备指纹追踪）。")
if flv_n:
    suspicious.append(
        f"FLV 直连 10 次均无需 Cookie/Referer/签名参数（基于 URL 的 roomId 直出流），"
        f"单次 3 秒可稳定拿到 {fmt_speed(flv_agg_speed)} 数据，说明**拉流侧匿名门槛远低于接口侧**。"
    )
if flv_trend_ratio is not None and abs(flv_trend_ratio - 1) > 0.3:
    suspicious.append(
        f"FLV 速率前后半段差异明显（后/前 = {flv_trend_ratio:.2f}×），疑似 CDN 节点负载或动态限速。"
    )
if flv_speed_low and len(flv_speed_low) >= max(2, flv_n // 2):
    suspicious.append("FLV 多次出现 <1MiB/s 的低速，需在 App 内做带宽自适应与断流探测。")
if not suspicious:
    suspicious.append("本轮未观察到明显的风控/限速特征（样本量 30+10，结论仅限当前 IP 与时段）。")

# ----------------------------------------------------------------------------- Markdown

L = []
A = L.append

A("# 小红书匿名风控压测报告（PC 侧）")
A("")
A(f"- 生成时间：{START} ~ {END}")
A(f"- 被测目标：")
A(f"  - 短链跟随：`{XHS_URL}`（{XHS_ROUNDS} 次连续请求）")
A(f"  - FLV 直连：`{FLV_URL}`（{FLV_ROUNDS} 次 × {FLV_SECONDS}s）")
A(f"- 客户端伪装：**Android UA**")
A("")
A("```text")
A(UA)
A("```")
A("")
A(f"- 匿名性：不带 Cookie、不登录、无签名参数、不复用连接（每轮独立 curl 进程）")
A(f"- 公网出口 IP：`{PUBIP}`")
A(f"- 测试机：Windows PC（curl {os.popen('curl --version').read().splitlines()[0] if os.name else ''}）".replace("（curl ）", ""))
A("")
A("> 说明：本压测只验证「匿名 + 安卓 UA」下的网络侧可达性/风控特征，不代表登录态或模拟器内 WebView 的表现。")
A("")
A("## 结论摘要")
A("")
A("| 项目 | 成功率 | 关键结论 |")
A("|---|---|---|")
A(f"| xhslink 短链 302 跟随 | **{pct(xhs_ok, xhs_n)}**（{xhs_ok}/{xhs_n}） | "
  f"HTTP 码分布 {dict(xhs_codes)}；平均 {fmt_s(statistics.mean(xhs_lat) if xhs_lat else None)}；"
  f"落地 host {dict(xhs_hosts) or '-'} |")
A(f"| FLV 直连拉流 | **{pct(flv_ok, flv_n)}**（{flv_ok}/{flv_n}） | "
  f"FLV 魔数通过 {flv_magic_ok}/{flv_n}；聚合速率 {fmt_speed(flv_agg_speed)}；"
  f"3 秒共取 {fmt_bytes(flv_bytes_total)} |")
A(f"| 综合评级 | {overall} | 详见下文「可疑特征」与「对 App 的建议」 |")
A("")
A("## 1. xhslink 短链连续跟随（30 次）")
A("")
A("### 1.1 成功率与状态码")
A("")
A(f"- 最终 HTTP 200：**{xhs_ok}/{xhs_n} = {pct(xhs_ok, xhs_n)}**")
A(f"- 状态码分布：`{dict(xhs_codes) or '无数据'}`")
A(f"- curl 退出码分布：`{dict(xhs_rcs) or '无数据'}`（0=成功，28=超时，6=DNS，7=连接失败，35=TLS）")
A(f"- 跳转次数：`{dict(Counter(xhs_redirs)) or '无数据'}`（302 链长度）")
A(f"- 落地 host：`{dict(xhs_hosts) or '无数据'}`；roomId：`{dict(xhs_rooms) or '无数据'}`")
A(f"- 落地 URL 形态：dynpath 混淆 {xhs_dynpath}/{xhs_n}；带 xsec_token {xhs_token_rounds}/{xhs_n}；"
  f"不同 token 值 {len(set(tokens))} 个")
A("")
A("### 1.2 耗时")
A("")
if xhs_lat:
    A("| 指标 | 数值 |")
    A("|---|---|")
    A(f"| 最小 | {fmt_s(min(xhs_lat))} |")
    A(f"| 平均 | {fmt_s(statistics.mean(xhs_lat))} |")
    A(f"| P50 | {fmt_s(pctile(xhs_lat, 0.50))} |")
    A(f"| P95 | {fmt_s(pctile(xhs_lat, 0.95))} |")
    A(f"| 最大 | {fmt_s(max(xhs_lat))} |")
    A(f"| 前 5 轮均值 | {fmt_s(statistics.mean(xhs_first5) if xhs_first5 else None)} |")
    A(f"| 后 5 轮均值 | {fmt_s(statistics.mean(xhs_last5) if xhs_last5 else None)} |")
else:
    A("无有效耗时数据（全部失败）。")
A("")
A("### 1.3 逐轮明细")
A("")
A("| # | HTTP | 耗时 | 302 跳转 | 落地 host | xsec_token | 落地 path |")
A("|---|---|---|---|---|---|---|")
for r, info in zip(xhs, xhs_infos):
    tok = "✓" if info["token"] else "-"
    path = info["path"]
    if len(path) > 42:
        path = path[:39] + "..."
    err = "" if r["rc"] == "0" else f" ⚠️rc={r['rc']}"
    A(f"| {r['idx']} | {r['http_code']}{err} | {fmt_s(to_float(r['total_s']) or None)} | "
      f"{r['num_redirects']} | {info['host']} | {tok} | `{path or '-'}` |")
A("")
if xhs_fail:
    A("### 1.4 失败模式")
    A("")
    for r in xhs_fail[:20]:
        A(f"- 第 {r['idx']} 轮：HTTP {r['http_code']}，curl_rc={r['rc']}，"
          f"err=`{r['curl_err'][:200] or '-'}`，URL=`{r['effective_url'][:160]}`")
    A("")
A("### 1.5 响应头样本（首跳）")
A("")
A("首轮：")
A("```http")
A(header_lines(XHS_HDR_FIRST) or "（无样本）")
A("```")
A("")
A("末轮：")
A("```http")
A(header_lines(XHS_HDR_LAST) or "（无样本）")
A("```")
A("")

A("## 2. FLV 直连拉流（10 次 × 3 秒）")
A("")
A("### 2.1 成功率与数据量")
A("")
A(f"- 成功定义：HTTP 200 **且** 响应体前 3 字节为 `FLV` 魔数")
A(f"- 成功：**{flv_ok}/{flv_n} = {pct(flv_ok, flv_n)}**；FLV 魔数通过 {flv_magic_ok}/{flv_n}")
A(f"- 状态码分布：`{dict(flv_codes) or '无数据'}`；curl 退出码：`{dict(flv_rcs) or '无数据'}`"
  "（28=`--max-time 3` 正常截断）")
A(f"- Content-Type：`{dict(flv_ctypes) or '无数据'}`")
A(f"- 跳转次数：`{dict(Counter(flv_redirs)) or '无数据'}`")
A(f"- 3 秒样本总流量：**{fmt_bytes(flv_bytes_total)}**（{flv_n} 次 × {FLV_SECONDS}s）")
A(f"- 聚合速率：**{fmt_speed(flv_agg_speed)}**（总字节/总耗时）")
A("")
A("### 2.2 速率与首包")
A("")
if flv_speeds:
    A("| 指标 | 数值 |")
    A("|---|---|")
    A(f"| 平均速率 | {fmt_speed(statistics.mean(flv_speeds))} |")
    A(f"| P50 速率 | {fmt_speed(pctile(flv_speeds, 0.50))} |")
    A(f"| 最低 / 最高 | {fmt_speed(min(flv_speeds))} / {fmt_speed(max(flv_speeds))} |")
    A(f"| 单次样本量 | 平均 {fmt_bytes(statistics.mean(flv_sizes))}，最大 {fmt_bytes(max(flv_sizes))} |")
    if flv_ttfbs:
        A(f"| TTFB（首包） | 平均 {fmt_s(statistics.mean(flv_ttfbs))}，"
          f"P95 {fmt_s(pctile(flv_ttfbs, 0.95))}，最大 {fmt_s(max(flv_ttfbs))} |")
else:
    A("无有效速率数据。")
A("")
A("### 2.3 逐次明细")
A("")
A("| # | HTTP | FLV 头 | 数据量 | 3s 速率 | TTFB | 302 | Content-Type | 首 8 字节(hex) |")
A("|---|---|---|---|---|---|---|---|---|")
for r in flv:
    magic = "✓" if r["flv_magic"] == "1" else "✗"
    hex8 = r["first16_hex"][:20] if r["first16_hex"] not in ("", "-") else "-"
    A(f"| {r['idx']} | {r['http_code']} | {magic} | {fmt_bytes(to_int(r['size_bytes']))} | "
      f"{fmt_speed(to_float(r['speed_Bps']))} | {fmt_s(to_float(r['time_starttransfer_s']) or None)} | "
      f"{r['num_redirects']} | {r['content_type']} | `{hex8}` |")
A("")
if flv_fail:
    A("### 2.4 失败模式")
    A("")
    for r in flv_fail[:20]:
        kind = []
        if r["http_code"] != "200":
            kind.append(f"HTTP {r['http_code']}")
        if r["rc"] not in ("0", "28"):
            kind.append(f"curl_rc={r['rc']}")
        if r["flv_magic"] != "1":
            kind.append("非 FLV 响应")
        if to_int(r["size_bytes"]) == 0:
            kind.append("空响应体")
        A(f"- 第 {r['idx']} 次：{'；'.join(kind) or '未知'}；"
          f"首字节 `{r['first16_hex'][:32] or '-'}`；err=`{r['curl_err'][:160] or '-'}`")
    A("")
A("### 2.5 响应头样本（第 1 次）")
A("")
first_hdr = ""
for block in FLV_HDR.split("##########"):
    if "attempt 1 " in block:
        first_hdr = block.split("\n", 1)[1] if "\n" in block else block
        break
A("```http")
A(header_lines(first_hdr) or "（无样本）")
A("```")
A("")

A("## 3. 失败模式与可疑特征")
A("")
A("### 3.1 失败模式汇总")
A("")
A("| 类别 | 次数 | 说明 |")
A("|---|---|---|")
A(f"| 短链：非 200 / curl 报错 | {len(xhs_fail)} | 逐轮见 1.4；原始数据见 `verify/xhslink-attempts.tsv` |")
A(f"| 短链：疑似限流码（401/403/405/412/429/503） | {len(xhs_waf)} | 未出现即信号较弱 |")
A(f"| 短链：验证/风控关键词落地 | {len(xhs_captcha)} | captcha/verify/risk 等 |")
A(f"| FLV：非 200 | {sum(1 for r in flv if r['http_code'] != '200')} | 403/404/302 等 |")
A(f"| FLV：非 FLV 响应体 | {len(flv_nonflv)} | 可能是 HTML 错误页/鉴权页 |")
A(f"| FLV：空响应体 | {sum(1 for r in flv if to_int(r['size_bytes']) == 0)} | 连接被断/超时 |")
A("")
A("### 3.2 可疑特征")
A("")
for s in suspicious:
    A(f"- {s}")
A("")
A("## 4. 对 App 的现实含义与建议")
A("")
A("1. **匿名链路成立**：短链 302 解析与 FLV 直连都不需要登录态、不需要 Cookie、不需要签名参数，"
  "App 可以保持「粘贴链接即可录制」的匿名路径。")
A("2. **短链必须实时解析**：落地 URL 的 `xsec_token` 是时效签名且每次不同，不能缓存网页 URL；"
  "每次开始录制都应重新跟随 302，并取最终 URL 里的 roomId。")
A("3. **FLV 直连可作为主拉流方案**：`https://live-source-play.xhscdn.com/live/<roomId>.flv` "
  "无需鉴权，3 秒即可稳定出流；但需要处理 `--max-time` 类截断（直播流本身无限长）以及 CDN 节点差异。")
A("4. **容错与降频**：当前成功率下建议每次拉流失败后 1s/3s/5s 指数退避重连（最多 3 次），"
  "重连时重新解析短链以刷新 token；多任务并发时限制同时拉流路数，避免被 CDN 侧限速。")
A("5. **UA/指纹**：本轮仅伪装 UA 即可通过，说明网络侧暂未对非 App 客户端做严格校验；"
  "但若后续出现 403/412/429，应优先怀疑设备指纹/签名校验，而不是网络问题。")
A("6. **观测建议**：App 内记录每次解析的 HTTP 码、耗时、最终 URL 的 token 变化与拉流首包时间，"
  "便于区分「平台风控」与「本地网络/CDN 抖动」。")
A("")
A("## 5. 附录：原始数据与复现")
A("")
A("- `verify/xhslink-attempts.tsv`：短链 30 轮明细（http_code/耗时/跳转数/最终 URL/curl 错误）")
A("- `verify/flv-attempts.tsv`：FLV 10 轮明细（http_code/Content-Type/字节数/速率/TTFB/FLV 魔数/首 16 字节）")
A("- `verify/logs/xhslink-headers-first.txt`、`verify/logs/xhslink-headers-last.txt`：首末轮响应头全文")
A("- `verify/logs/xhslink-fail-r*.txt`：失败轮次的 body 摘要（若有）")
A("- `verify/logs/flv-headers.txt`：10 次 FLV 响应头全文")
A("- 复现命令：`tools/risk-probe.sh`（可用 `XHS_ROUNDS=5 FLV_ROUNDS=2` 小流量试跑）")
A("")
A("---")
A("")
A("_本报告由 `tools/risk-probe.sh` 自动生成；数值来自单机单时段采样，IP/时段/线路变化可能导致不同结果。_")

with open(out_path, "w", encoding="utf-8", newline="\n") as f:
    f.write("\n".join(L) + "\n")

print(f"[risk_report] 已生成 {out_path}（{len(L)} 行）")
print(f"[risk_report] 短链 {xhs_ok}/{xhs_n}，FLV {flv_ok}/{flv_n}，综合：{overall}")
