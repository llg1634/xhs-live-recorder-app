import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/live_room.dart';

/// 把用户粘贴的分享文案 / 直播链接解析成 [LiveRoom]。
///
/// 已验证的小红书行为（2026-10，桌面与安卓匿名环境一致）：
/// - `https://xhslink.com/o/xxxx` 是 **服务器端 302**，直接返回
///   `.../livestream/{dynpath}/{roomId}?xsec_token=...`，不需要浏览器执行 JS。
/// - 直播间页路径有两种：老版 `/livestream/{roomId}`，
///   新版 `/livestream/{dynpath}/{roomId}`。
/// - 拿到 roomId 后即可构造 FLV 直链，无需登录态。
class LinkResolver {
  LinkResolver({this.userAgent = _defaultUa});

  static const _defaultUa =
      'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

  static const _xhsLiveReA = r'^/livestream/([^/?#]+)/(\d+)';
  static const _xhsLiveReB = r'^/livestream/(\d+)';
  static const _douyinLiveReA = r'^/(\d+)';

  final String userAgent;

  /// 解析入口：从任意文本中提取链接并归一化。
  Future<LiveRoom> resolve(
    String rawText, {
    Duration timeout = const Duration(seconds: 20),
    bool enrichTitle = true,
  }) async {
    final url = extractUrl(rawText);
    if (url == null) {
      throw LinkResolveException('没有在输入里找到 http/https 链接');
    }

    final effective = await _resolveRedirectChain(url, timeout: timeout);

    final xhs = _matchXhs(effective);
    if (xhs != null) {
      var room = LiveRoom(
        platform: LivePlatform.xhs,
        roomId: xhs,
        pageUrl: effective.toString(),
        rawInput: rawText,
      );
      if (enrichTitle) {
        room = await _enrich(room, timeout);
      }
      return room;
    }

    final douyin = _matchDouyin(effective);
    if (douyin != null) {
      return LiveRoom(
        platform: LivePlatform.douyin,
        roomId: douyin,
        pageUrl: effective.toString(),
        rawInput: rawText,
        webRid: _extractDouyinWebRid(url.toString()) ??
            _extractDouyinWebRid(effective.toString()),
      );
    }

    throw LinkResolveException('无法识别的直播间链接：${effective.host}${effective.path}');
  }

  /// 从分享文案里抽第一个 http(s) 链接。
  static Uri? extractUrl(String rawText) {
    final text = rawText.trim();
    final match = RegExp(r'https?://[^\s，。、；;）)】\]]+').firstMatch(text);
    if (match == null) return null;
    final cleaned = match.group(0)!
        .replaceAll(RegExp(r'[.,;)\]}]+$'), '')
        .trim();
    return Uri.tryParse(cleaned);
  }

  /// 处理短链：逐跳读取 Location，不下载页面正文。
  Future<Uri> _resolveRedirectChain(
    Uri start, {
    required Duration timeout,
  }) async {
    var current = start;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..userAgent = userAgent;

    try {
      for (var hop = 0; hop < 10; hop++) {
        final request = await client
            .getUrl(current)
            .timeout(timeout);
        request.followRedirects = false;
        request.headers.set(HttpHeaders.acceptHeader, '*/*');
        final response =
            await request.close().timeout(const Duration(seconds: 12));
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>().catchError((_) {});
        if (response.statusCode >= 300 &&
            response.statusCode < 400 &&
            location != null &&
            location.isNotEmpty) {
          current = current.resolve(location);
          continue;
        }
        return current;
      }
      return current;
    } on TimeoutException {
      throw LinkResolveException('短链跳转超时，请检查网络');
    } on SocketException catch (e) {
      throw LinkResolveException('网络不可用：${e.message}');
    } finally {
      client.close(force: true);
    }
  }

  String? _matchXhs(Uri uri) {
    final host = uri.host.toLowerCase();
    if (host != 'www.xiaohongshu.com' &&
        host != 'xiaohongshu.com' &&
        !host.endsWith('.xiaohongshu.com')) {
      return null;
    }
    final path = uri.path;
    final a = RegExp(_xhsLiveReA).firstMatch(path);
    if (a != null) return a.group(2);
    final b = RegExp(_xhsLiveReB).firstMatch(path);
    if (b != null) return b.group(1);
    return null;
  }

  /// 从链接里取抖音 web_rid：
  /// `live.douyin.com/<rid>` 或 `www.douyin.com/follow/live/<rid>`。
  static String? _extractDouyinWebRid(String text) {
    final m = RegExp(r'(?:live\.douyin\.com/|/follow/live/)(\d{5,})')
        .firstMatch(text);
    return m?.group(1);
  }

  String? _matchDouyin(Uri uri) {
    final host = uri.host.toLowerCase();
    if (host == 'live.douyin.com') {
      final m = RegExp(_douyinLiveReA).firstMatch(uri.path);
      return m?.group(1);
    }
    if (host == 'www.douyin.com' || host == 'douyin.com') {
      final m = RegExp(r'^/follow/live/(\d+)').firstMatch(uri.path);
      return m?.group(1);
    }
    // 分享短链 v.douyin.com/xxxx 会 302 到
    // webcast.amemv.com/douyin/webcast/reflow/<room_id>，
    // 该页面内嵌签名 FLV 直链（见 DouyinResolver.resolveFromReflow）。
    if (host == 'webcast.amemv.com' || host.endsWith('.amemv.com')) {
      final m = RegExp(r'^/douyin/webcast/reflow/(\d+)').firstMatch(uri.path);
      return m?.group(1);
    }
    return null;
  }

  /// 尽力补全直播标题 / 主播昵称；失败不影响录制。
  Future<LiveRoom> _enrich(LiveRoom room, Duration timeout) async {
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 8)
        ..userAgent = userAgent;
      try {
        final request = await client
            .getUrl(Uri.parse(room.pageUrl))
            .timeout(const Duration(seconds: 8));
        request.headers.set(HttpHeaders.acceptHeader, 'text/html');
        final response =
            await request.close().timeout(const Duration(seconds: 10));
        if (response.statusCode != 200) return room;
        final body = await const Utf8Decoder(allowMalformed: true)
            .bind(response)
            .join();
        final title = _extractTitle(body);
        if (title == null) return room;
        final anchor = title
            .replaceAll(RegExp(r'的小红书直播间$'), '')
            .replaceAll(RegExp(r' - 小红书$'), '')
            .trim();
        // 页面静态 HTML 的 og:title 常常只是"小红书"这类通用标题，不能当主播名。
        const generic = {'小红书', '小红书直播', '抖音', '抖音直播', ''};
        if (generic.contains(anchor)) return room;
        return room.copyWith(
          title: title,
          anchorName: anchor.isEmpty ? null : anchor,
        );
      } finally {
        client.close(force: true);
      }
    } catch (_) {
      return room;
    }
  }

  String? _extractTitle(String html) {
    final og = RegExp(
      r'''<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)''',
      caseSensitive: false,
    ).firstMatch(html);
    if (og != null) return _unescape(og.group(1)!);
    final t = RegExp(r'<title[^>]*>([^<]{1,120})</title>', caseSensitive: false)
        .firstMatch(html);
    if (t != null) return _unescape(t.group(1)!.trim());
    return null;
  }

  String _unescape(String v) => v
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");
}
