import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/live_room.dart';

/// 抖音直播 FLV 直链解析器（**纯 HTTP，无需 WebView**）。
///
/// 2026-10 实测结论（详见 `docs/douyin.md`）：
/// - 抖音网页版直播流地址由私有接口
///   `GET https://live.douyin.com/webcast/room/web/enter/` 下发，
///   响应 `data.data[0].stream_url.flv_pull_url` 是「档位 → 带签名 FLV 直链」的 Map；
/// - 调用该接口只需要一个匿名 `ttwid` Cookie：先 GET 一次直播间页面
///   （`https://live.douyin.com/<webRid>`）即可从 `Set-Cookie` 拿到，页面本身
///   不需要执行 JS，也不要求登录；
/// - 直链的签名（`?k=&t=` 或 `?expire=&sign=`）由服务端签发，客户端无需、也无法自行计算；
/// - 直链本身拉流**不需要 Cookie / Referer / UA**，curl 即可 200 并返回 FLV；
/// - 同一 URL 断流后可直接重连继续拉；但主播重开播会更换 stream id，
///   所以 `FlvRecorder` 每次新建分段前重新调用本解析器最稳（它本来就会调 `urlProvider`）。
///
/// 使用方式（接进 `RecordingManager`）：
/// ```dart
/// final douyinResolver = DouyinResolver();
/// final manager = RecordingManager(
///   resolver: linkResolver,
///   storage: storage,
///   douyinUrlResolver: (room) => douyinResolver.resolveFlvUrl(room.roomId),
/// );
/// ```
///
/// 失败时抛出 [LinkResolveException]（UI 层已有统一展示逻辑）。
class DouyinResolver {
  DouyinResolver({
    this.userAgent = defaultUserAgent,
    this.timeout = const Duration(seconds: 15),
    this.qualityPreference = const ['FULL_HD1', 'HD1', 'SD2', 'SD1'],
    this.preferHttps = true,
    this.ttwidTtl = const Duration(days: 1),
  });

  /// 桌面端浏览器 UA。
  ///
  /// 注意：抖音直播间页面在**非浏览器 UA**（curl / python / Dart 默认 UA）下
  /// 会返回 0 字节且不下发 `ttwid`，所以这一步必须带真实浏览器 UA。
  static const defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36 Edg/152.0.0.0';

  static const _liveOrigin = 'https://live.douyin.com';
  static const _enterPath = '/webcast/room/web/enter/';

  final String userAgent;

  /// 单次 HTTP 请求超时。
  final Duration timeout;

  /// 档位优先级：`FULL_HD1`（蓝光）→ `HD1`（超清）→ `SD2`（高清）→ `SD1`（标清）。
  ///
  /// 注意 `flv_pull_url` 的 key 顺序不是画质顺序（`SD1` 比 `SD2` 低）。
  final List<String> qualityPreference;

  /// 是否把接口返回的 `http://` 直链改写成 `https://`。
  ///
  /// Android 9+ 默认禁止明文 HTTP；实测两个 CDN 域名都支持 HTTPS，默认改写。
  final bool preferHttps;

  /// `ttwid` 的内存缓存时长（抖音侧有效期未知，取保守的一天）。
  final Duration ttwidTtl;

  String? _ttwid;
  DateTime? _ttwidAt;
  Future<String>? _pendingTtwid;

  /// 解析出可录制的 FLV 直链。
  ///
  /// [webRid] 是抖音直播间网页号（`https://live.douyin.com/<webRid>` 里的数字），
  /// 也容忍直接传整条直播间链接。
  ///
  /// 抛 [LinkResolveException]，典型原因：
  /// - 房间号非法；
  /// - 直播间未开播 / 已结束（接口 `status=4` 且 `flv_pull_url` 为空）；
  /// - 被风控（接口 200 但 body 为空；会先自动刷新 `ttwid` 重试一次）；
  /// - 网络超时。
  Future<String> resolveFlvUrl(String webRid) async {
    final rid = _normalizeWebRid(webRid);
    if (rid == null) {
      throw LinkResolveException('抖音房间号无效：$webRid');
    }

    var json = await _requestRoom(rid);
    if (json.isEmpty) {
      // 200 + 空 body 是抖音典型的「ttwid 失效 / 风控」信号，
      // 而不是 4xx；刷新 cookie 后重试一次。
      _clearTtwid();
      json = await _requestRoom(rid);
      if (json.isEmpty) {
        throw LinkResolveException('抖音接口返回空响应（ttwid 失效或被风控）');
      }
    }

    return _pickFlvUrl(json);
  }

  /// 清掉缓存的 `ttwid`（切换网络、被风控或调试时可手动调用）。
  void clearCache() => _clearTtwid();

  void _clearTtwid() {
    _ttwid = null;
    _ttwidAt = null;
    _pendingTtwid = null;
  }

  // ---------------------------------------------------------------------------
  // 接口请求
  // ---------------------------------------------------------------------------

  /// 调 `webcast/room/web/enter/`，返回解析后的 JSON；空 body 返回空 Map。
  Future<Map<String, dynamic>> _requestRoom(String rid) async {
    final ttwid = await _ensureTtwid(rid);
    final uri = Uri.parse('$_liveOrigin$_enterPath').replace(
      queryParameters: <String, String>{
        'aid': '6383',
        'device_platform': 'web',
        'browser_language': 'zh-CN',
        'browser_platform': 'Win32',
        'browser_name': 'Edge',
        'browser_version': '152.0.0.0',
        'web_rid': rid,
      },
    );

    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.userAgentHeader, userAgent);
      request.headers.set(HttpHeaders.cookieHeader, 'ttwid=$ttwid');
      request.headers.set(HttpHeaders.refererHeader, '$_liveOrigin/$rid');
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/json, text/plain, */*',
      );

      final response = await request.close().timeout(timeout);
      final body = await utf8.decoder.bind(response).join().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw LinkResolveException('抖音接口 HTTP ${response.statusCode}');
      }
      if (body.trim().isEmpty) return const <String, dynamic>{};

      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw LinkResolveException('抖音接口返回格式异常');
      }
      return decoded;
    } on LinkResolveException {
      rethrow;
    } on TimeoutException {
      throw LinkResolveException('抖音接口超时');
    } on SocketException catch (e) {
      throw LinkResolveException('抖音接口网络错误：${e.message}');
    } on HandshakeException {
      throw LinkResolveException('抖音接口 TLS 握手失败');
    } on FormatException {
      throw LinkResolveException('抖音接口返回的不是合法 JSON');
    } finally {
      client.close(force: true);
    }
  }

  /// 取 `ttwid`：优先内存缓存，其次 GET 直播间页面从 `Set-Cookie` 读取。
  ///
  /// 并发调用会共享同一个 Future，避免同一时刻重复请求页面。
  Future<String> _ensureTtwid(String rid) {
    final cached = _ttwid;
    final at = _ttwidAt;
    if (cached != null &&
        at != null &&
        DateTime.now().difference(at) < ttwidTtl) {
      return Future<String>.value(cached);
    }
    return _pendingTtwid ??= _fetchTtwid(rid).whenComplete(() {
      _pendingTtwid = null;
    });
  }

  Future<String> _fetchTtwid(String rid) async {
    final uri = Uri.parse('$_liveOrigin/$rid');
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.userAgentHeader, userAgent);
      request.headers.set(
        HttpHeaders.acceptHeader,
        'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      );
      request.headers.set(HttpHeaders.acceptLanguageHeader, 'zh-CN,zh;q=0.9');

      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw LinkResolveException('抖音直播间页面 HTTP ${response.statusCode}');
      }

      String? ttwid;
      // 不要用 `response.cookies`：抖音的 Set-Cookie 里带有非标准 `Secure` 属性值，
      // Dart 的 Cookie 解析器会直接抛 `HttpException: Value given for 'Secure'`。
      // 这里按原始 header 手工提取 ttwid。
      for (final raw
          in response.headers[HttpHeaders.setCookieHeader] ??
              const <String>[]) {
        final match = RegExp(r'(?:^|;\s*)ttwid=([^;]+)').firstMatch(raw);
        if (match != null && match.group(1)!.isNotEmpty) {
          ttwid = match.group(1);
          break;
        }
      }

      // Set-Cookie 已在响应头里，页面正文（约 1 MB）不再需要，提前取消下载。
      try {
        final subscription = response.listen(null);
        await subscription.cancel();
      } catch (_) {
        // 取消下载失败不影响结果。
      }

      if (ttwid == null || ttwid.isEmpty) {
        throw LinkResolveException('抖音未下发 ttwid（可能被风控；请检查 UA/网络）');
      }
      _ttwid = ttwid;
      _ttwidAt = DateTime.now();
      return ttwid;
    } on LinkResolveException {
      rethrow;
    } on TimeoutException {
      throw LinkResolveException('抖音直播间页面请求超时');
    } on SocketException catch (e) {
      throw LinkResolveException('抖音直播间页面网络错误：${e.message}');
    } finally {
      client.close(force: true);
    }
  }

  // ---------------------------------------------------------------------------
  // 响应解析
  // ---------------------------------------------------------------------------

  /// 从 `room/web/enter` 的 JSON 里选一个档位的 FLV 直链。
  String _pickFlvUrl(Map<String, dynamic> json) {
    final statusCode = json['status_code'];
    if (statusCode is num && statusCode != 0) {
      if (statusCode == 4001038) {
        throw LinkResolveException('抖音直播间不存在');
      }
      throw LinkResolveException('抖音接口错误 status_code=$statusCode');
    }

    final data = json['data'];
    final rooms = data is Map<String, dynamic> ? data['data'] : null;
    if (rooms is! List || rooms.isEmpty) {
      throw LinkResolveException('抖音直播间不存在或已下播');
    }

    final room = rooms.first;
    if (room is! Map<String, dynamic>) {
      throw LinkResolveException('抖音直播间数据格式异常');
    }

    final streamUrl = room['stream_url'];
    final flvMap = streamUrl is Map<String, dynamic>
        ? streamUrl['flv_pull_url']
        : null;
    if (flvMap is! Map || flvMap.isEmpty) {
      final roomStatus = room['status'];
      if (roomStatus == 4) {
        throw LinkResolveException('抖音直播已结束');
      }
      throw LinkResolveException('抖音直播间未开播或已结束');
    }

    String? picked;
    for (final key in qualityPreference) {
      final value = flvMap[key];
      if (value is String && value.isNotEmpty) {
        picked = value;
        break;
      }
    }
    picked ??= flvMap.values.whereType<String>().firstWhere(
      (v) => v.isNotEmpty,
      orElse: () => '',
    );
    if (picked.isEmpty) {
      throw LinkResolveException('抖音直播间没有可用的 FLV 档位');
    }

    return preferHttps ? _toHttps(picked) : picked;
  }

  /// 分享短链（`v.douyin.com/xxxx/`）会 302 到
  /// `https://webcast.amemv.com/douyin/webcast/reflow/<room_id>?...`，
  /// 该页面 HTML 里**直接内嵌了带签名的 FLV 直链**，不需要调 API。
  ///
  /// 每次调用都重新抓页面，因此断流重连会拿到新的签名地址。
  Future<String> resolveFromReflow(String roomIdOrUrl) async {
    final id = RegExp(r'\d{5,}').firstMatch(roomIdOrUrl)?.group(0);
    if (id == null) throw LinkResolveException('抖音房间号无效：$roomIdOrUrl');

    final uri = Uri.parse('https://webcast.amemv.com/douyin/webcast/reflow/$id');
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.userAgentHeader, _mobileUserAgent);
      request.headers.set(HttpHeaders.acceptHeader, 'text/html');
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) {
        await response.drain<void>().catchError((_) {});
        throw LinkResolveException('抖音分享页打开失败：HTTP ${response.statusCode}');
      }
      final html = await const Utf8Decoder(allowMalformed: true)
          .bind(response)
          .join();
      // 页面里同一批地址有两种转义形式：HTML 的 `&amp;` 和 JSON 的 `\u0026`，
      // 末尾还可能带反斜杠，都要还原成真正可请求的 URL。
      // 注意：正则不能排除反斜杠，否则会从第一个 `\u0026` 处把 query 截断。
      final urls = RegExp(r'''https?://pull-flv-[^"'\s<>]+\.flv\?[^"'\s<>]+''')
          .allMatches(html)
          .map((m) => m
              .group(0)!
              .replaceAll(r'\u0026', '&')
              .replaceAll('&amp;', '&')
              .replaceAll(RegExp(r'[\\"<>]+$'), '')
              .trim())
          .where((u) => u.contains('sign=') || u.contains('k='))
          .toList();
      if (urls.isEmpty) {
        throw LinkResolveException('抖音分享页里没有直播流（可能已下播）');
      }
      final picked = _pickBestReflow(urls);
      // 注意：reflow 的 CDN 走 https 会 403，必须保留接口给的 http 地址。
      return picked;
    } on TimeoutException {
      throw LinkResolveException('抖音分享页请求超时');
    } finally {
      client.close(force: true);
    }
  }

  String _pickBestReflow(List<String> urls) {
    const order = ['_uhd', '_or4', '_hd', '_sd', '_ld'];
    for (final key in order) {
      for (final url in urls) {
        if (url.contains('$key.flv')) return url;
      }
    }
    return urls.first;
  }

  /// 分享页（amemv reflow）是移动端页面，用移动端 UA 才能拿到内嵌流地址。
  static const _mobileUserAgent =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 '
      'Mobile/15E148 Safari/604.1';

  /// 接口返回的直链是 `http://`；Android 9+ 默认禁止明文流量，
  /// 实测两个 CDN 都支持 HTTPS，因此默认改写。
  ///
  /// TODO(webview-fallback): 若抖音后续升级风控（例如开始校验 JS 生成的
  /// a_bogus/msToken，纯 HTTP 返回空包），保留本类签名不动，改为由
  /// WebView 打开直播间页面：读取 `live_debug_info` Cookie 的 `src`，
  /// 或 hook `fetch`/`XHR` 捕获 `.flv` 请求 / 在页面上下文里 fetch 本接口，
  /// 再通过 `JavaScriptChannel` 把 URL 回传给 Dart。具体要点见 docs/douyin.md §4.4。
  static String _toHttps(String url) => url.startsWith('http://')
      ? 'https://${url.substring('http://'.length)}'
      : url;

  /// `webRid` 归一化：接受纯数字，也接受 `https://live.douyin.com/675247105586?...`。
  static String? _normalizeWebRid(String input) {
    final text = input.trim();
    if (text.isEmpty) return null;
    if (RegExp(r'^\d+$').hasMatch(text)) return text;

    // 从链接里取 path 最后一段数字，例如 /675247105586。
    final uri = Uri.tryParse(text);
    if (uri != null) {
      for (final segment in uri.pathSegments.reversed) {
        if (RegExp(r'^\d+$').hasMatch(segment)) return segment;
      }
    }
    final match = RegExp(r'(\d{5,})').firstMatch(text);
    return match?.group(1);
  }
}
