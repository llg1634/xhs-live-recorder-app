import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models/live_room.dart';
import 'ass_export.dart';

/// 一条直播评论。
class LiveComment {
  const LiveComment({
    required this.time,
    required this.user,
    required this.text,
    this.commentId,
  });

  final DateTime time;
  final String user;
  final String text;
  final String? commentId;

  Map<String, dynamic> toJson() => {
        'ts': time.millisecondsSinceEpoch,
        'user': user,
        'text': text,
        if (commentId != null) 'commentId': commentId,
      };
}

/// 单个直播间的弹幕采集器。
///
/// 两个平台的数据通道完全不同，所以**各用一套 hook 脚本**：
/// - 小红书：文本 JSON 帧 → `b.d.b[].d` base64 → `customData.type == "text"`
/// - 抖音：二进制 protobuf 帧 → PushFrame → gzip → Response.messages →
///   `WebcastChatMessage`
///
/// 详见 `docs/comments.md`。
class CommentCapture extends ChangeNotifier {
  CommentCapture({
    required this.taskId,
    required this.platform,
    required this.roomUrl,
    required this.outputDir,
    required this.startEpochMs,
    this.onComment,
  });

  final String taskId;
  final LivePlatform platform;
  final String roomUrl;
  final String outputDir;

  /// 录制开始时间（毫秒时间戳）：把评论时间换算成相对视频的偏移。
  final int startEpochMs;

  /// 收到新评论时的回调（用于更新任务卡片计数）。
  final void Function(LiveComment comment)? onComment;

  static const _desktopUA =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  final List<LiveComment> _recent = [];
  List<LiveComment> get recent => List.unmodifiable(_recent);

  int count = 0;
  int frameCount = 0;
  bool ready = false;
  String? lastError;
  DateTime? lastFrameAt;
  DateTime? lastCommentAt;

  WebViewController? _controller;
  WebViewController? get controller => _controller;

  File? _logFile;
  bool _stopped = false;
  DateTime? _startedAt;

  /// 采集器创建时间（看门狗用它判断"一直没拿到帧"）。
  DateTime? get startedAt => _startedAt;

  String get _tag => taskId.length >= 8 ? taskId.substring(0, 8) : taskId;

  String get statusLabel {
    if (lastError != null) return '弹幕异常';
    if (!ready) return '弹幕连接中';
    return '弹幕 $count 条';
  }

  Future<void> start() async {
    _startedAt = DateTime.now();
    _logFile = File('$outputDir/comments.jsonl');
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_desktopUA)
      ..setBackgroundColor(const Color(0xFF000000))
      ..addJavaScriptChannel('LiveComments', onMessageReceived: _onJsMessage);
    _controller = controller;

    controller.setNavigationDelegate(NavigationDelegate(
      onPageStarted: (_) => _inject(),
      onPageFinished: (_) => _inject(),
      onWebResourceError: (e) {
        if (e.isForMainFrame ?? false) {
          lastError = '${e.errorCode} ${e.description}';
          debugPrint('[comments $_tag] main frame error: $lastError');
          _notify();
        }
      },
    ));

    debugPrint('[comments $_tag] opening (${platform.key}) $roomUrl');
    await controller.loadRequest(Uri.parse(roomUrl));
  }

  Future<void> _inject() async {
    final c = _controller;
    if (c == null || _stopped) return;
    try {
      await c.runJavaScript(
          platform == LivePlatform.xhs ? _xhsHookScript : _douyinHookScript);
    } catch (e) {
      debugPrint('[comments $_tag] inject failed: $e');
    }
  }

  /// 安全通知：停止/销毁之后不再 notify（ChangeNotifier 销毁后再用会抛异常）。
  void _notify() {
    if (_stopped) return;
    notifyListeners();
  }

  /// 重新加载采集页；返回 false 表示 WebView 本身已经不可用（需要整个重建）。
  Future<bool> reload() async {
    if (_stopped) return true;
    debugPrint('[comments $_tag] reload page');
    ready = false;
    lastError = null;
    final controller = _controller;
    if (controller == null) return false;
    try {
      await controller.reload();
      _notify();
      return true;
    } catch (e) {
      debugPrint('[comments $_tag] reload failed: $e');
      lastError = 'WebView 已失效：$e';
      _notify();
      return false;
    }
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _controller = null;
    try {
      final count = await AssExporter.export(
        outputDir: outputDir,
        startEpochMs: startEpochMs,
      );
      debugPrint('[comments $_tag] ass/srt exported: $count');
    } catch (e) {
      debugPrint('[comments $_tag] ass export failed: $e');
    }
    super.dispose();
  }

  void _onJsMessage(JavaScriptMessage message) {
    if (_stopped) return;
    Map<String, dynamic>? obj;
    try {
      obj = jsonDecode(message.message) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (obj['t']) {
      case 'ready':
        ready = true;
        lastError = null;
        debugPrint('[comments $_tag] hook ready (${platform.key})');
        _notify();
        break;
      case 'frame':
        frameCount++;
        lastFrameAt = DateTime.now();
        break;
      case 'c':
        _accept(
          user: (obj['u'] ?? '').toString(),
          text: (obj['x'] ?? '').toString(),
          ts: (obj['ts'] as num?)?.toInt(),
          id: obj['id']?.toString(),
        );
        break;
      case 'err':
        lastError = obj['text']?.toString();
        debugPrint('[comments $_tag] js error: $lastError');
        _notify();
        break;
      case 'stat':
        debugPrint('[comments $_tag] stat $obj');
        break;
    }
  }

  void _accept({
    required String user,
    required String text,
    int? ts,
    String? id,
  }) {
    final content = text.trim();
    if (content.isEmpty) return;
    final comment = LiveComment(
      time: DateTime.fromMillisecondsSinceEpoch(
        ts ?? DateTime.now().millisecondsSinceEpoch,
      ),
      user: user.trim(),
      text: content,
      commentId: id,
    );
    count++;
    lastCommentAt = DateTime.now();
    if (_recent.length >= 30) _recent.removeAt(0);
    _recent.add(comment);
    _appendLog(comment);
    onComment?.call(comment);
    _notify();
  }

  void _appendLog(LiveComment comment) {
    final file = _logFile;
    if (file == null) return;
    final line = jsonEncode(comment.toJson());
    file
        .writeAsString('$line\n', mode: FileMode.append, flush: false)
        .catchError((Object e) {
      debugPrint('[comments] write failed: $e');
      return file;
    });
  }
}

/// 多房间弹幕采集调度。
class CommentCaptureManager extends ChangeNotifier {
  final Map<String, CommentCapture> _captures = {};
  Timer? _watchdog;

  List<CommentCapture> get captures => _captures.values.toList();

  CommentCapture? captureFor(String taskId) => _captures[taskId];

  bool isCapturing(String taskId) => _captures.containsKey(taskId);

  Future<void> startForTask({
    required String taskId,
    required LivePlatform platform,
    required String roomUrl,
    required String outputDir,
    required int startEpochMs,
    void Function(LiveComment comment)? onComment,
  }) async {
    if (_captures.containsKey(taskId)) return;
    final capture = CommentCapture(
      taskId: taskId,
      platform: platform,
      roomUrl: roomUrl,
      outputDir: outputDir,
      startEpochMs: startEpochMs,
      onComment: onComment,
    );
    capture.addListener(notifyListeners);
    _captures[taskId] = capture;
    notifyListeners();

    try {
      await capture.start();
    } catch (e) {
      // WebView 起不来（Activity/引擎刚重建、没有可用的 PlatformView 宿主等）时
      // 只影响弹幕，绝不能把整个录制任务带崩；把半成品从列表里摘掉，避免 UI
      // 一直挂着无法渲染的 WebViewWidget。
      debugPrint('[comments] startForTask $taskId failed: $e');
      _captures.remove(taskId);
      capture.removeListener(notifyListeners);
      unawaited(capture.stop());
      notifyListeners();
      rethrow;
    }
    _ensureWatchdog();
  }

  Future<void> stopForTask(String taskId) async {
    final capture = _captures.remove(taskId);
    if (capture == null) return;
    capture.removeListener(notifyListeners);
    await capture.stop();
    notifyListeners();
  }

  Future<void> stopAll() async {
    for (final id in _captures.keys.toList()) {
      await stopForTask(id);
    }
  }

  /// App 回到前台时调用：后台待久了 WebView 可能被系统冻结/回收，
  /// 这里对"没有新帧"的采集器做一次温和的重新加载（不影响录制）。
  Future<void> onAppResumed() async {
    final DateTime now = DateTime.now();
    for (final CommentCapture capture in _captures.values.toList()) {
      final DateTime? last = capture.lastFrameAt ?? capture.startedAt;
      if (last == null) continue;
      if (now.difference(last) < const Duration(minutes: 2)) continue;
      debugPrint('[comments] resume: reload ${capture.taskId}');
      final bool ok = await capture.reload();
      if (!ok) {
        // WebView 已经彻底失效（Activity 重建后底层 view 被销毁）：
        // 重建一个采集器，弹幕继续采，录制任务本身完全不受影响。
        await _rebuild(capture);
      }
    }
  }

  /// 用同样的参数重建一个采集器（只用于 WebView 自愈）。
  Future<void> _rebuild(CommentCapture old) async {
    _captures.remove(old.taskId);
    old.removeListener(notifyListeners);
    await old.stop();
    notifyListeners();
    try {
      await startForTask(
        taskId: old.taskId,
        platform: old.platform,
        roomUrl: old.roomUrl,
        outputDir: old.outputDir,
        startEpochMs: old.startEpochMs,
        onComment: old.onComment,
      );
    } catch (e) {
      debugPrint('[comments] rebuild ${old.taskId} failed: $e');
    }
  }

  /// 长时间没有任何帧说明页面可能被节流/掉线，自动重载恢复。
  void _ensureWatchdog() {
    _watchdog ??= Timer.periodic(const Duration(minutes: 1), (_) {
      final DateTime now = DateTime.now();
      for (final CommentCapture capture in _captures.values) {
        final DateTime? last = capture.lastFrameAt ?? capture.startedAt;
        if (last == null) continue;
        if (now.difference(last) > const Duration(minutes: 8)) {
          debugPrint('[comments] stale >8min, reload page');
          unawaited(capture.reload());
        }
      }
    });
  }

  @override
  void dispose() {
    _watchdog?.cancel();
    _watchdog = null;
    for (final c in _captures.values) {
      c.removeListener(notifyListeners);
      unawaited(c.stop());
    }
    _captures.clear();
    super.dispose();
  }
}

/// 小红书：文本 JSON 帧。
const String _xhsHookScript = r'''
(function(){
  if (window.__lcHooked) { return; }
  window.__lcHooked = true;

  function post(o) { try { LiveComments.postMessage(JSON.stringify(o)); } catch (e) {} }
  function b64utf8(b64) {
    try {
      var bin = atob(b64), n = bin.length, out = new Uint8Array(n);
      for (var i = 0; i < n; i++) out[i] = bin.charCodeAt(i);
      return new TextDecoder('utf-8').decode(out);
    } catch (e) { return null; }
  }

  function handle(data) {
    post({t: 'frame'});
    if (typeof data !== 'string') return;
    var outer;
    try { outer = JSON.parse(data); } catch (e) { return; }
    if (!outer || !outer.b || !outer.b.d || !Array.isArray(outer.b.d.b)) return;
    var list = outer.b.d.b;
    for (var i = 0; i < list.length; i++) {
      var item = list[i];
      if (!item || !item.d) continue;
      var txt = b64utf8(item.d);
      if (!txt) continue;
      var payload;
      try { payload = JSON.parse(txt); } catch (e) { continue; }
      var cd = payload.customData;
      if (typeof cd === 'string') { try { cd = JSON.parse(cd); } catch (e) { continue; } }
      if (!cd || cd.type !== 'text') continue;
      var text = cd.desc || cd.content || cd.text || '';
      if (!text) continue;
      var user = (cd.profile && cd.profile.nickname) ||
                 (cd.userInfo && cd.userInfo.nickname) || '';
      post({t: 'c', u: String(user), x: String(text).slice(0, 500),
            ts: payload.ts || cd.current_time || Date.now(),
            id: cd.commentId ? String(cd.commentId) : ''});
    }
  }

  var OWS = window.WebSocket;
  function WS(u, p) {
    var sock = new OWS(u, p);
    try { sock.addEventListener('message', function (ev) { handle(ev.data); }); } catch (e) {}
    return sock;
  }
  WS.prototype = OWS.prototype;
  WS.CONNECTING = 0; WS.OPEN = 1; WS.CLOSING = 2; WS.CLOSED = 3;
  window.WebSocket = WS;

  // 采集时暂停页面视频，省 CPU 与流量；评论区与长连接不受影响。
  var tries = 0;
  var timer = setInterval(function () {
    tries++;
    try {
      var v = document.querySelector('video');
      if (v) { v.muted = true; v.pause(); clearInterval(timer); }
    } catch (e) {}
    if (tries > 20) clearInterval(timer);
  }, 1500);

  post({t: 'ready'});
})();
''';

/// 抖音：二进制 protobuf 帧。
///
/// 帧结构：PushFrame{ seqid=1, logid=2, service=3, method=4, headers=5,
/// payloadEncoding=6, payloadType=7, payload=8 }；
/// `payloadEncoding == "gzip"` 时 payload 需要 gzip 解压；
/// 解压后 Response{ messages=1 }，Message{ method=1, payload=2 }；
/// `WebcastChatMessage` 的 payload 是 ChatMessage{ common=1, user=2, content=3 }，
/// user 的 nickname 在 User.nickname=3。
const String _douyinHookScript = r'''
(function(){
  if (window.__lcHooked) { return; }
  window.__lcHooked = true;

  function post(o) { try { LiveComments.postMessage(JSON.stringify(o)); } catch (e) {} }
  function str(u8) { try { return new TextDecoder('utf-8').decode(u8); } catch (e) { return ''; } }

  function varint(u8, pos) {
    var r = 0, shift = 0, b;
    do { b = u8[pos++]; r += (b & 0x7f) * Math.pow(2, shift); shift += 7; } while (b & 0x80);
    return [r, pos];
  }
  function fields(u8) {
    var out = [], pos = 0;
    while (pos < u8.length) {
      var t = varint(u8, pos); pos = t[1];
      var tag = t[0], f = Math.floor(tag / 8), w = tag & 7;
      if (w === 0) { var v = varint(u8, pos); out.push({f: f, w: 0}); pos = v[1]; }
      else if (w === 2) {
        var l = varint(u8, pos); pos = l[1];
        out.push({f: f, w: 2, b: u8.subarray(pos, pos + l[0])});
        pos += l[0];
      } else if (w === 5) { out.push({f: f, w: 5}); pos += 4; }
      else if (w === 1) { out.push({f: f, w: 1}); pos += 8; }
      else break;
    }
    return out;
  }
  function getB(list, f) { for (var i = 0; i < list.length; i++) if (list[i].f === f && list[i].w === 2) return list[i].b; return null; }
  function getAllB(list, f) { var o = []; for (var i = 0; i < list.length; i++) if (list[i].f === f && list[i].w === 2) o.push(list[i].b); return o; }

  function gunzip(bytes) {
    return new Promise(function (resolve) {
      try {
        if (typeof DecompressionStream === 'undefined') { resolve(null); return; }
        var stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('gzip'));
        new Response(stream).arrayBuffer().then(
          function (ab) { resolve(new Uint8Array(ab)); },
          function () { resolve(null); });
      } catch (e) { resolve(null); }
    });
  }

  function parseResponse(bytes) {
    var msgs = getAllB(fields(bytes), 1);
    for (var i = 0; i < msgs.length; i++) {
      var mf = fields(msgs[i]);
      var method = getB(mf, 1) ? str(getB(mf, 1)) : '';
      var body = getB(mf, 2);
      if (!method || !body) continue;
      if (method !== 'WebcastChatMessage') continue;
      var cf = fields(body);
      var content = getB(cf, 3) ? str(getB(cf, 3)) : '';
      if (!content) continue;
      var nick = '';
      var userBuf = getB(cf, 2);
      if (userBuf) {
        var uf = fields(userBuf);
        nick = getB(uf, 3) ? str(getB(uf, 3)) : '';
      }
      post({t: 'c', u: nick, x: content.slice(0, 500), ts: Date.now(), id: ''});
    }
  }

  function compType(pf) {
    // 抖音把压缩标记放在 headers 里：compress_type=gzip
    for (var i = 0; i < pf.length; i++) {
      if (pf[i].f !== 5 || pf[i].w !== 2) continue;
      var hf = fields(pf[i].b);
      var k = getB(hf, 1) ? str(getB(hf, 1)) : '';
      var v = getB(hf, 2) ? str(getB(hf, 2)) : '';
      if (k === 'compress_type') return v;
    }
    return '';
  }

  function handle(buf) {
    post({t: 'frame'});
    var u8 = new Uint8Array(buf);
    var pf = fields(u8);
    var payload = getB(pf, 8);
    if (!payload) return;
    var encoding = compType(pf) || (getB(pf, 6) ? str(getB(pf, 6)) : '');
    if (encoding === 'gzip') {
      gunzip(payload).then(function (out) { if (out) parseResponse(out); });
    } else {
      parseResponse(payload);
    }
  }

  var OWS = window.WebSocket;
  function WS(u, p) {
    var sock = new OWS(u, p);
    try {
      sock.binaryType = 'arraybuffer';
      sock.addEventListener('message', function (ev) {
        if (ev.data instanceof ArrayBuffer) handle(ev.data);
      });
    } catch (e) {}
    return sock;
  }
  WS.prototype = OWS.prototype;
  WS.CONNECTING = 0; WS.OPEN = 1; WS.CLOSING = 2; WS.CLOSED = 3;
  window.WebSocket = WS;

  // 抖音先不暂停视频：部分房间暂停会触发"主播离开"占位，先保守处理。
  post({t: 'ready'});
})();
''';
