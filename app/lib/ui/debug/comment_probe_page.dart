import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// 弹幕采集探针（**仅用于技术验证，不进正式流程**）。
///
/// 用隐藏 WebView + 桌面 UA 打开小红书直播间，在文档早期注入 hook：
/// 1. 包装 `WebSocket` 构造函数，监听页面自身长连接收到的帧；
/// 2. 帧里 `b.d.b[].d` 是 base64 的 JSON（原脚本同款解码规则），解出来后上报；
/// 3. 同时也包装 `Worker` 构造函数，记录页面是否把长连接放进 Worker。
///
/// 触发：
/// `adb shell am start -n com.liquidlab.live_recorder/.MainActivity --es probe "<直播间链接>"`
class CommentProbePage extends StatefulWidget {
  const CommentProbePage({super.key, required this.url, this.seconds = 600});

  final String url;
  final int seconds;

  @override
  State<CommentProbePage> createState() => _CommentProbePageState();
}

class _CommentProbePageState extends State<CommentProbePage> {
  static const _desktopUA =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  late final WebViewController _controller;
  Timer? _timer;
  int _wsCount = 0;
  int _frameCount = 0;
  int _commentCount = 0;
  final List<String> _recent = [];
  String _status = '初始化…';

  File? _logFile;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_desktopUA)
      ..setBackgroundColor(const Color(0xFFFF00FF))
      ..addJavaScriptChannel('ProbeBridge', onMessageReceived: _onJsMessage);

    _controller.loadRequest(Uri.parse(widget.url));
    // WebView 没有 document-start 注入 API：onPageStarted 最早，之后页面脚本
    // 仍会再加载一批 chunk，所以这里在 started 后再补一次幂等注入。
    _controller.setNavigationDelegate(
      NavigationDelegate(
        onPageStarted: (_) => _inject(),
        onPageFinished: (_) => _inject(),
        onWebResourceError: (e) =>
            _log('page-error ${e.errorCode}: ${e.description}'),
      ),
    );

    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _dumpStats());
    Timer(Duration(seconds: widget.seconds), _finish);

    _openLog();
  }

  Future<void> _openLog() async {
    try {
      final dir = Directory('/storage/emulated/0/Movies/直播录制/_probe');
      if (!await dir.exists()) await dir.create(recursive: true);
      _logFile = File(
        '${dir.path}/probe_${DateTime.now().millisecondsSinceEpoch}.log',
      );
      await _logFile!.writeAsString(
        'probe start url=${widget.url} ua=$_desktopUA\n',
      );
    } catch (e) {
      debugPrint('[probe] log file failed: $e');
      _logFile = null;
    }
  }

  void _log(String line) {
    debugPrint('[probe] $line');
    final f = _logFile;
    if (f == null) return;
    f.writeAsString('$line\n', mode: FileMode.append, flush: false).ignore();
  }

  Future<void> _inject() async {
    try {
      await _controller.runJavaScript(_hookScript);
    } catch (e) {
      _log('inject failed: $e');
    }
  }

  void _onJsMessage(JavaScriptMessage message) {
    final raw = message.message;
    try {
      final obj = jsonDecode(raw) as Map<String, dynamic>;
      switch (obj['t']) {
        case 'ws':
          _wsCount++;
          _log('WS url=${obj['url']}');
          break;
        case 'worker':
          _log('WORKER src=${obj['src']}');
          break;
        case 'frame':
          _frameCount += (obj['n'] as num?)?.toInt() ?? 1;
          break;
        case 'comment':
          _commentCount++;
          final text = obj['text']?.toString() ?? '';
          if (_recent.length >= 20) _recent.removeAt(0);
          _recent.add(text);
          _log('COMMENT $text');
          break;
        case 'dychat':
          _commentCount++;
          final user = obj['u']?.toString() ?? '';
          final text = obj['x']?.toString() ?? '';
          final line = user.isEmpty ? text : '$user：$text';
          if (_recent.length >= 20) _recent.removeAt(0);
          _recent.add(line);
          _log('DYCHAT $line');
          break;
        case 'notice':
          _log('NOTICE ${obj['text']}');
          break;
        case 'stats':
          _log('STATS $raw');
          break;
        case 'error':
          _log('JSERR ${obj['text']}');
          break;
        default:
          _log('MSG $raw');
      }
      if (mounted) setState(() {});
    } catch (_) {
      _log('RAW $raw');
    }
  }

  void _dumpStats() {
    final s = 'ws=$_wsCount frame=$_frameCount comment=$_commentCount';
    _status = s;
    _log('TICK $s');
    _controller
        .runJavaScript(
          "ProbeBridge.postMessage(JSON.stringify({t:'stats',ws:(window.__probe&&window.__probe.ws.length)||0,"
          "hooked:!!window.__hookInstalled,types:window.__cdTypes||null,"
          "video:(function(){var v=document.querySelector('video');"
          "return v?{rs:v.readyState,w:v.videoWidth}:null})()}))",
        )
        .catchError((_) {});
  }

  void _finish() {
    _timer?.cancel();
    _log('FINISH ws=$_wsCount frame=$_frameCount comment=$_commentCount');
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('弹幕探针 · $_status')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              'WS:$_wsCount  帧:$_frameCount  评论:$_commentCount',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          Expanded(
            // 变体 D：小视口 420x900 + 不透明遮盖（省内存，正式实现首选形态）
            child: ClipRect(
              child: Stack(
                children: [
                  Positioned(
                    left: 0,
                    top: 0,
                    width: 420,
                    height: 900,
                    child: WebViewWidget(controller: _controller),
                  ),
                  const Positioned.fill(
                    child: ColoredBox(color: Color(0xFF101014)),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(
            height: 120,
            child: ListView(
              children: _recent
                  .map(
                    (t) => Text(
                      t,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }
}

const String _hookScript = r'''
(function(){
  if (window.__hookInstalled) { return; }
  window.__hookInstalled = true;
  window.__probe = {ws: [], frames: 0, comments: 0, bin: 0, methods: {}, chats: 0};

  function post(o) {
    try { ProbeBridge.postMessage(JSON.stringify(o)); } catch (e) {}
  }
  function str(u8) {
    try { return new TextDecoder('utf-8').decode(u8); } catch (e) { return ''; }
  }
  function b64utf8(b64) {
    try {
      var bin = atob(b64), n = bin.length, out = new Uint8Array(n);
      for (var i = 0; i < n; i++) out[i] = bin.charCodeAt(i);
      return new TextDecoder('utf-8').decode(out);
    } catch (e) { return null; }
  }

  // ---- 最小 protobuf 解析（只够解抖音推流） ----
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
      if (w === 0) { var v = varint(u8, pos); out.push({f: f, w: 0, n: v[0]}); pos = v[1]; }
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
        var ds = new DecompressionStream('gzip');
        var stream = new Blob([bytes]).stream().pipeThrough(ds);
        new Response(stream).arrayBuffer().then(
          function (ab) { resolve(new Uint8Array(ab)); },
          function () { resolve(null); });
      } catch (e) { resolve(null); }
    });
  }

  function compType(pf) {
    for (var i = 0; i < pf.length; i++) {
      if (pf[i].f !== 5 || pf[i].w !== 2) continue;
      var hf = fields(pf[i].b);
      var k = getB(hf, 1) ? str(getB(hf, 1)) : '';
      var v = getB(hf, 2) ? str(getB(hf, 2)) : '';
      if (k === 'compress_type') return v;
    }
    return '';
  }

  function handleDouyin(buf) {
    var u8 = new Uint8Array(buf);
    window.__probe.bin++;
    var pf = fields(u8);
    var payload = getB(pf, 8);
    // 抖音的压缩标记在 headers 里（compress_type=gzip），不是 payloadEncoding
    var encoding = compType(pf) || (getB(pf, 6) ? str(getB(pf, 6)) : '');
    var ptype = getB(pf, 7) ? str(getB(pf, 7)) : '';
    if (window.__probe.bin <= 3 && ptype === 'msg') {
      var summary = pf.map(function (x) {
        return x.f + ':' + (x.w === 0 ? 'v' : (x.b ? 'b' + x.b.length : 'w' + x.w));
      }).join(',');
      var hex = '';
      for (var k = 0; k < Math.min(48, u8.length); k++) {
        hex += ('0' + u8[k].toString(16)).slice(-2);
      }
      post({t: 'notice', text: 'PF[' + summary + '] hex=' + hex});
    }
    if (!payload) return;
    var parse = function (bytes) {
      var resp = fields(bytes);
      var msgs = getAllB(resp, 1);
      for (var i = 0; i < msgs.length; i++) {
        var mf = fields(msgs[i]);
        var method = getB(mf, 1) ? str(getB(mf, 1)) : '';
        var body = getB(mf, 2);
        if (!method) continue;
        window.__probe.methods[method] = (window.__probe.methods[method] || 0) + 1;
        if (method === 'WebcastChatMessage' && body) {
          var cf = fields(body);
          var content = getB(cf, 3) ? str(getB(cf, 3)) : '';
          var nick = '';
          var userBuf = getB(cf, 2);
          if (userBuf) {
            var uf = fields(userBuf);
            nick = getB(uf, 3) ? str(getB(uf, 3)) : '';
          }
          if (content) {
            window.__probe.chats++;
            post({t: 'dychat', u: nick, x: content.slice(0, 200)});
          }
        }
      }
    };
    if (encoding === 'gzip') {
      gunzip(payload).then(function (out) { if (out) parse(out); });
    } else {
      parse(payload);
    }
  }

  // ---- 小红书：文本 JSON 帧 ----
  function handleXhs(data) {
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
      post({t: 'comment', text: user ? user + '：' + text : String(text)});
    }
  }

  function handleFrame(data) {
    window.__probe.frames++;
    post({t: 'frame', n: 1});
    if (typeof data === 'string') { handleXhs(data); return; }
    if (data instanceof ArrayBuffer) { handleDouyin(data); }
  }

  var OWS = window.WebSocket;
  function WS(u, p) {
    try { window.__probe.ws.push(String(u)); post({t: 'ws', url: String(u)}); } catch (e) {}
    var sock = new OWS(u, p);
    try {
      sock.binaryType = 'arraybuffer';
      sock.addEventListener('message', function (ev) { handleFrame(ev.data); });
    } catch (e) {}
    return sock;
  }
  WS.prototype = OWS.prototype;
  WS.CONNECTING = 0; WS.OPEN = 1; WS.CLOSING = 2; WS.CLOSED = 3;
  window.WebSocket = WS;

  var OW = window.Worker;
  if (OW) {
    function W(src, opt) { try { post({t: 'worker', src: String(src).slice(0, 160)}); } catch (e) {} return new OW(src, opt); }
    W.prototype = OW.prototype;
    window.Worker = W;
  }

  setInterval(function () {
    post({t: 'stats', bin: window.__probe.bin, chats: window.__probe.chats,
          methods: window.__probe.methods});
  }, 15000);

  post({t: 'notice', text: 'hook installed ua=' + navigator.userAgent});
})();
''';
