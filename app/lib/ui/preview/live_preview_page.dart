import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../services/flv_codec_probe.dart';
import '../widgets/format_utils.dart';
import '../widgets/native_flv_player.dart';

/// 直播/回放播放页。
///
/// 播放内核按编码自动选择：
/// - H.264/AVC → 原有 `assets/web/player.html`（flv.js）；
/// - H.265/HEVC 或探测未知 → 原生 MediaCodec 播放器（TextureView）；
/// - WebView 报 `CodecUnsupported` → 自动切原生。
///
/// Flutter 外壳（加载进度、错误遮罩、全屏/沉浸式、静音、状态胶囊、诊断面板）
/// 在两种内核下保持一致；原生模式额外提供播放/暂停、进度拖动和时间显示。
enum _PlayerKind { probing, web, native }

class LivePreviewPage extends StatefulWidget {
  const LivePreviewPage({
    super.key,
    required this.title,
    required this.url,
    this.subtitle,
    this.startMs = 0,
  });

  /// 标题（直播任务名 / 录像文件名）。
  final String title;

  /// 本地服务上的播放页地址，例：
  /// `http://127.0.0.1:PORT/player.html?src=%2Flive%2FtaskId.flv&title=...`
  final String url;

  /// 可选副标题，例如分段文件名。
  final String? subtitle;

  /// 调试入口：原生回放打开时直接跳转到的起始位置（毫秒）。
  final int startMs;

  @override
  State<LivePreviewPage> createState() => _LivePreviewPageState();
}

class _LivePreviewPageState extends State<LivePreviewPage>
    with WidgetsBindingObserver {
  static const String _channelName = 'PlayerBridge';
  static const Duration _loadTimeout = Duration(seconds: 15);
  static const Duration _overlayHideDelay = Duration(seconds: 4);

  WebViewController? _controller;
  NativeFlvPlayerController? _native;
  String? _nativeSrc;
  FlvCodecInfo? _codecInfo;
  _PlayerKind _kind = _PlayerKind.probing;

  // ---------- 页面加载 ----------
  bool _pageReady = false;
  int _progress = 0;
  String? _loadError;
  Timer? _loadWatchdog;

  // ---------- 页面上报的状态 ----------
  String _phase = 'loading';
  bool _muted = true;
  int _retry = 0;
  int _bitrateKbps = 0;
  int _speedKbps = 0;
  int _videoWidth = 0;
  int _videoHeight = 0;
  String _message = '';
  double _position = 0;
  double _duration = 0;

  // ---------- 原生进度条拖动 ----------
  bool _dragging = false;
  double _dragValue = 0;

  // ---------- 远端诊断 ----------
  String? _diag;
  bool _diagLoading = false;

  // ---------- 全屏 / 浮层 ----------
  bool _manualImmersive = false;
  bool _landscapeBlocked = false;
  bool _overlayHidden = false;
  bool _wasImmersive = false;
  Timer? _overlayTimer;

  // ---------- 系统 UI 去重 ----------
  bool? _appliedImmersive;
  bool? _sentImmersive;

  bool _isReplay = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _isReplay = _detectReplay(widget.url);
    _bootstrap();
  }

  @override
  void dispose() {
    _loadWatchdog?.cancel();
    _overlayTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _native?.dispose();
    // 让页面销毁 flv.js 播放器、清理定时器（WebView 释放前尽力而为）。
    try {
      _controller
          ?.runJavaScript(
            'window.PV && window.PV.destroy && window.PV.destroy();',
          )
          .catchError((Object _) {});
    } catch (_) {}
    // 离开页面务必恢复系统 UI，避免别处仍是全屏。
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant LivePreviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url == widget.url) return;
    _loadWatchdog?.cancel();
    _native?.dispose();
    _native = null;
    _nativeSrc = null;
    _codecInfo = null;
    _kind = _PlayerKind.probing;
    _isReplay = _detectReplay(widget.url);
    setState(() {
      _loadError = null;
      _pageReady = false;
      _progress = 0;
      _phase = 'loading';
      _retry = 0;
      _bitrateKbps = 0;
      _message = '';
      _position = 0;
      _duration = 0;
      _sentImmersive = null;
    });
    _bootstrap();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从后台回来时 Android 可能已重置沉浸式标记，重新应用一次。
    if (state == AppLifecycleState.resumed && mounted) {
      _appliedImmersive = null;
      _applySystemUi(_immersiveFor(MediaQuery.orientationOf(context)));
    }
  }

  // ===================== 探测 / 启动 =====================

  static String _srcOf(String url) {
    try {
      return Uri.parse(url).queryParameters['src'] ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<void> _bootstrap() async {
    final FlvCodecInfo? info = await _probeCodec();
    if (!mounted) return;
    _codecInfo = info;
    debugPrint(
      '[preview] probe codec=${info?.videoCodecName ?? "unknown"} '
      'codecId=${info?.videoCodecId ?? 0} seq=${info?.hasSequenceHeader ?? false} '
      'size=${info?.width ?? 0}x${info?.height ?? 0}',
    );
    // AVC 继续走原 WebView；HEVC / 未知走原生（原生同样支持 AVC）。
    if (info != null && info.isAvc) {
      _startWeb();
    } else {
      _startNative();
    }
  }

  Future<FlvCodecInfo?> _probeCodec() async {
    try {
      final String src = _srcOf(widget.url);
      if (src.startsWith('/file')) {
        final Uri inner = Uri.parse(src);
        final String? path = inner.queryParameters['path'];
        if (path != null && path.isNotEmpty) {
          return await FlvCodecProbe.probeFile(path)
              .timeout(const Duration(seconds: 5));
        }
      } else if (src.startsWith('/live/') && src.endsWith('.flv')) {
        final Uri outer = Uri.parse(widget.url);
        final String taskId = src.substring(6, src.length - 4);
        final String base = '${outer.scheme}://${outer.authority}';
        return await FlvCodecProbe.probeTask(base, taskId)
            .timeout(const Duration(seconds: 5));
      }
    } catch (e) {
      debugPrint('[preview] codec probe failed: $e');
    }
    return null;
  }

  void _startWeb() {
    final WebViewController controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF000000))
      ..addJavaScriptChannel(_channelName, onMessageReceived: _onBridgeMessage)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (int progress) {
            if (!mounted || _loadError != null || _kind != _PlayerKind.web) {
              return;
            }
            if (progress == _progress) return;
            setState(() => _progress = progress);
          },
          onPageStarted: (String url) {
            if (!mounted || _kind != _PlayerKind.web) return;
            setState(() {
              _pageReady = false;
              _progress = 0;
            });
            _startLoadWatchdog();
          },
          onPageFinished: (String url) {
            if (!mounted ||
                _loadError != null ||
                _kind != _PlayerKind.web) {
              return;
            }
            _loadWatchdog?.cancel();
            setState(() {
              _pageReady = true;
              _progress = 100;
            });
            // 新页面上下文：重新同步一次沉浸式状态。
            _sentImmersive = null;
            _sendImmersive(_immersiveFor(MediaQuery.orientationOf(context)));
          },
          onWebResourceError: (WebResourceError error) {
            // 主文档失败才当作播放页加载失败，资源错误交给页面自己重试。
            if (error.isForMainFrame ?? false) {
              _failPage(error.description);
            }
          },
          onHttpError: (HttpResponseError error) {
            if (_pageReady) return;
            final int status = error.response?.statusCode ?? 0;
            if (status >= 400) {
              _failPage('播放页返回 HTTP $status');
            }
          },
        ),
      );
    _controller = controller;
    debugPrint('[preview] web player start (flv.js): ${widget.url}');
    setState(() {
      _kind = _PlayerKind.web;
      _pageReady = false;
      _progress = 0;
      _phase = 'loading';
      _message = '';
    });

    final String target = widget.url.trim();
    if (target.isEmpty) {
      _failPage('缺少播放地址（url 为空）');
    } else {
      controller.loadRequest(Uri.parse(target));
      _startLoadWatchdog();
    }
  }

  String? _nativeSource() {
    final String src = _srcOf(widget.url);
    if (src.startsWith('http://') || src.startsWith('https://')) return src;
    if (src.startsWith('/file')) {
      try {
        final String? path = Uri.parse(src).queryParameters['path'];
        if (path != null && path.isNotEmpty) return path;
      } catch (_) {}
      return null;
    }
    if (src.startsWith('/live/')) {
      try {
        final Uri outer = Uri.parse(widget.url);
        return '${outer.scheme}://${outer.authority}$src';
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  void _startNative() {
    _native?.dispose();
    _native = null;
    _nativeSrc = _nativeSource();
    setState(() {
      _kind = _PlayerKind.native;
      _pageReady = false;
      _phase = 'loading';
      _retry = 0;
      _position = 0;
      _duration = 0;
      _videoWidth = 0;
      _videoHeight = 0;
      _message = '';
      _loadError = null;
    });
    if (_nativeSrc == null) {
      setState(() {
        _phase = 'error';
        _message = '无法解析视频地址';
      });
      return;
    }
    final NativeFlvPlayerController controller =
        NativeFlvPlayerController(isLive: !_isReplay);
    controller.addListener(_onNativeState);
    _native = controller;
    debugPrint(
      '[preview] native player start: src=$_nativeSrc live=${!_isReplay} '
      'codec=${_codecInfo?.videoCodecName ?? "unknown"}',
    );
  }

  void _onNativeState() {
    final NativeFlvPlayerController? controller = _native;
    if (controller == null || !mounted) return;
    setState(() {
      _phase = controller.phase;
      _position = controller.position;
      _duration = controller.duration;
      _videoWidth = controller.width;
      _videoHeight = controller.height;
      _muted = controller.muted;
      _retry = controller.retry;
      _message = controller.message;
      if (controller.phase == 'error' && _diag == null) {
        _diag = const JsonEncoder.withIndent('  ').convert(controller.diag);
      }
    });
  }

  /// WebView 报编码不支持时无缝切换到原生播放器。
  void _switchToNative({String? reason}) {
    if (_kind == _PlayerKind.native) return;
    debugPrint('[preview] switch to native: ${reason ?? "codec unsupported"}');
    _loadWatchdog?.cancel();
    _loadError = null;
    _pageReady = false;
    _startNative();
    if (reason != null && reason.isNotEmpty) {
      setState(() => _message = reason);
    }
  }

  // ===================== 基础工具 =====================

  static bool _detectReplay(String url) {
    try {
      final Uri uri = Uri.parse(url);
      final String src = uri.queryParameters['src'] ?? '';
      return src.contains('/file');
    } catch (_) {
      return false;
    }
  }

  bool _immersiveFor(Orientation orientation) =>
      _manualImmersive ||
      (orientation == Orientation.landscape && !_landscapeBlocked);

  void _startLoadWatchdog() {
    _loadWatchdog?.cancel();
    _loadWatchdog = Timer(_loadTimeout, () {
      if (!mounted || _pageReady || _loadError != null) return;
      _failPage('播放页加载超时');
    });
  }

  void _failPage(String message) {
    _loadWatchdog?.cancel();
    if (!mounted) return;
    setState(() {
      _loadError = message;
      _pageReady = false;
      _phase = 'error';
      _message = message;
    });
  }

  Future<void> _runJs(String script) async {
    if (!_pageReady) return;
    final WebViewController? controller = _controller;
    if (controller == null) return;
    try {
      await controller.runJavaScript(script);
    } catch (_) {
      // WebView 已销毁 / 页面已跳走，忽略。
    }
  }

  void _applySystemUi(bool immersive) {
    if (_appliedImmersive == immersive) return;
    _appliedImmersive = immersive;
    if (immersive) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    _sendImmersive(immersive);
  }

  void _sendImmersive(bool immersive) {
    if (_kind != _PlayerKind.web || !_pageReady) return;
    if (_sentImmersive == immersive) return;
    _sentImmersive = immersive;
    _runJs(
      'window.PV && window.PV.setImmersive && '
      'window.PV.setImmersive(${immersive ? 'true' : 'false'});',
    );
  }

  // ===================== 页面状态回调 =====================

  void _onBridgeMessage(JavaScriptMessage message) {
    if (!mounted || _kind != _PlayerKind.web) return;
    dynamic decoded;
    try {
      decoded = jsonDecode(message.message);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    final Map<dynamic, dynamic> data = decoded;

    switch (data['type']) {
      case 'state':
        _applyState(data);
      case 'fullscreen':
        _setImmersive(data['on'] == true);
      case 'tap':
        _toggleOverlay();
      case 'error':
        final String msg = data['message']?.toString() ?? '播放出错';
        setState(() {
          _phase = 'error';
          _message = msg;
        });
      case 'stopped':
        setState(() {
          _phase = 'stopped';
          _message = data['message']?.toString() ?? '录制已停止';
        });
        _requestDiag();
      case 'js-error':
        // 页内 JS 异常：只在调试面板里露出，不打断播放。
        debugPrint('[player.html] ${data['message']}');
    }
  }

  bool _looksLikeCodecUnsupported(String message) {
    final String lower = message.toLowerCase();
    return lower.contains('codecunsupported') ||
        lower.contains('编码不支持') ||
        lower.contains('h.265') ||
        lower.contains('hevc');
  }

  void _applyState(Map<dynamic, dynamic> data) {
    final String phase = data['phase']?.toString() ?? 'loading';
    final bool muted = data['muted'] == true;
    final int retry = _asInt(data['retry']);
    final int bitrate = _asInt(data['bitrate']);
    final int speed = _asInt(data['speedKBps']);
    final int w = _asInt(data['width']);
    final int h = _asInt(data['height']);
    final String message = data['message']?.toString() ?? '';

    // 调试构建下打印播放进度：真机/模拟器截屏不可用时，靠日志确认
    // 「是否真的在往前走」以及停在哪一帧。
    assert(() {
      debugPrint(
        '[preview] phase=$phase pos=${data['position']} '
        'dur=${data['duration']} buf=${data['buffered']} msg=$message',
      );
      return true;
    }());

    if (phase == 'error' && _looksLikeCodecUnsupported(message)) {
      _switchToNative(reason: message);
      return;
    }

    if (phase == _phase &&
        muted == _muted &&
        retry == _retry &&
        bitrate == _bitrateKbps &&
        speed == _speedKbps &&
        w == _videoWidth &&
        h == _videoHeight &&
        message == _message) {
      return;
    }
    setState(() {
      _phase = phase;
      _muted = muted;
      _retry = retry;
      _bitrateKbps = bitrate;
      _speedKbps = speed;
      _videoWidth = w;
      _videoHeight = h;
      _message = message;
      _position = _asDouble(data['position'], _position);
      _duration = _asDouble(data['duration'], _duration);
      if (_loadError != null && phase != 'error') {
        // 页面已能跑起来，撤掉“加载失败”遮罩。
        _loadError = null;
      }
    });
    if (phase == 'error' || phase == 'stopped') {
      _requestDiag();
    }
  }

  /// 出错时取一次诊断信息（WebView UA / MSE / 最近错误 / 数据间隔，或原生解码器状态）。
  void _requestDiag() {
    if (!mounted || _diagLoading) return;
    if (_kind == _PlayerKind.native) {
      final NativeFlvPlayerController? controller = _native;
      if (controller == null) return;
      setState(() {
        _diag = const JsonEncoder.withIndent('  ').convert(controller.diag);
      });
      return;
    }
    if (!_pageReady) return;
    _diagLoading = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fetchDiag();
    });
  }

  Future<void> _fetchDiag() async {
    final WebViewController? controller = _controller;
    if (controller == null) {
      _diagLoading = false;
      return;
    }
    try {
      final Object raw = await controller.runJavaScriptReturningResult(
        'window.PV && window.PV.diag ? window.PV.diag() : ""',
      );
      String text = raw.toString();
      // Android 上返回的是“JSON 字符串字面量”（带引号），先解一层。
      if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
        try {
          final Object? inner = jsonDecode(text);
          if (inner is String) text = inner;
        } catch (_) {}
      }
      String pretty = text;
      try {
        pretty = const JsonEncoder.withIndent('  ').convert(jsonDecode(text));
      } catch (_) {}
      if (!mounted) return;
      setState(() => _diag = pretty.isEmpty ? null : pretty);
    } catch (e) {
      if (mounted) setState(() => _diag = '诊断信息获取失败：$e');
    } finally {
      _diagLoading = false;
    }
  }

  static int _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return 0;
  }

  static double _asDouble(Object? value, double fallback) {
    if (value is num) return value.toDouble();
    return fallback;
  }

  // ===================== 全屏 / 浮层 =====================

  void _setImmersive(bool on) {
    if (!mounted) return;
    setState(() {
      _manualImmersive = on;
      _landscapeBlocked = false;
      _overlayHidden = false;
    });
    _scheduleOverlayHide();
  }

  void _scheduleOverlayHide() {
    _overlayTimer?.cancel();
    _overlayTimer = Timer(_overlayHideDelay, () {
      if (!mounted) return;
      final Orientation o = MediaQuery.orientationOf(context);
      if (!_immersiveFor(o)) return;
      setState(() => _overlayHidden = true);
    });
  }

  void _toggleOverlay() {
    final Orientation o = MediaQuery.orientationOf(context);
    if (!_immersiveFor(o)) return; // 非沉浸式时浮层是常驻的，不需要切换
    _overlayTimer?.cancel();
    setState(() => _overlayHidden = !_overlayHidden);
    if (!_overlayHidden) _scheduleOverlayHide();
  }

  void _handleBack() {
    final Orientation o = MediaQuery.orientationOf(context);
    if (!_immersiveFor(o)) {
      Navigator.of(context).maybePop();
      return;
    }
    _overlayTimer?.cancel();
    setState(() {
      _manualImmersive = false;
      if (o == Orientation.landscape) _landscapeBlocked = true;
      _overlayHidden = false;
    });
  }

  // ===================== 操作 =====================

  Future<void> _reloadPage() async {
    if (_kind == _PlayerKind.native) {
      setState(() {
        _loadError = null;
        _pageReady = false;
        _phase = 'loading';
        _retry = 0;
        _message = '';
        _diag = null;
      });
      await _native?.reopen();
      return;
    }
    if (_kind == _PlayerKind.probing) {
      await _bootstrap();
      return;
    }
    setState(() {
      _loadError = null;
      _pageReady = false;
      _progress = 0;
      _phase = 'loading';
      _retry = 0;
      _bitrateKbps = 0;
      _message = '';
      _sentImmersive = null;
    });
    _startLoadWatchdog();
    try {
      await _controller?.reload();
    } catch (_) {}
  }

  Future<void> _retryPlayback() async {
    if (_kind == _PlayerKind.native) {
      setState(() {
        _phase = 'loading';
        _retry = 0;
        _message = '';
        _diag = null;
      });
      await _native?.reopen();
      return;
    }
    if (_loadError != null) {
      await _reloadPage();
      return;
    }
    _runJs('window.PV && window.PV.reconnect && window.PV.reconnect();');
  }

  void _toggleMute() {
    if (_kind == _PlayerKind.native) {
      _native?.setMuted(!_muted);
      return;
    }
    _runJs('window.PV && window.PV.toggleMute && window.PV.toggleMute();');
  }

  void _togglePlayPause() {
    final NativeFlvPlayerController? controller = _native;
    if (controller == null) return;
    if (_phase == 'playing') {
      controller.pause();
    } else {
      controller.play();
    }
  }

  // ===================== 文案 =====================

  String get _modeLabel => _isReplay ? '录像回放' : '直播预览';

  String get _engineLabel =>
      _kind == _PlayerKind.native ? '原生 MediaCodec' : 'WebView flv.js';

  String get _phaseLabel {
    switch (_phase) {
      case 'playing':
        return _isReplay ? '播放中' : '直播中';
      case 'loading':
        return _retry > 0 ? '重连中（第 $_retry 次）' : '连接中';
      case 'buffering':
        return '缓冲中';
      case 'reconnect':
        return '重连中（第 $_retry 次）';
      case 'paused':
        return '已暂停';
      case 'ended':
        return '播放结束';
      case 'stopped':
        return '录制已停止';
      case 'error':
        return '播放出错';
      default:
        return '准备中';
    }
  }

  Color _phaseColor(ColorScheme scheme) {
    switch (_phase) {
      case 'playing':
        return const Color(0xFF31D07A);
      case 'buffering':
      case 'reconnect':
        return const Color(0xFFFFB020);
      case 'error':
        return const Color(0xFFFF5B52);
      case 'stopped':
        return const Color(0xFFFF5B52);
      case 'ended':
      case 'paused':
        return scheme.onSurfaceVariant;
      default:
        return scheme.primary;
    }
  }

  String? get _bitrateLabel {
    if (_bitrateKbps <= 0 || _isReplay) return null;
    return '${(_bitrateKbps / 1000).toStringAsFixed(2)} Mbps';
  }

  String? get _resolutionLabel {
    if (_videoWidth <= 0 || _videoHeight <= 0) return null;
    return '$_videoWidth × $_videoHeight';
  }

  String? get _codecLabel {
    final FlvCodecInfo? info = _codecInfo;
    if (info == null) return null;
    if (info.isHevc) return 'H.265 / HEVC';
    if (info.isAvc) return 'H.264 / AVC';
    return null;
  }

  String get _loadStatusLabel {
    if (_kind == _PlayerKind.native) {
      if (_phase == 'error') return '失败';
      if ((_native?.decoder ?? '').isNotEmpty) return '原生解码器已启动';
      return '原生播放器启动中';
    }
    if (_kind == _PlayerKind.probing) return '正在探测编码';
    return _pageReady
        ? '播放页已加载'
        : (_loadError != null ? '失败' : '加载中 $_progress%');
  }

  // ===================== build =====================

  @override
  Widget build(BuildContext context) {
    final Orientation orientation = MediaQuery.orientationOf(context);
    final bool immersive = _immersiveFor(orientation);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _applySystemUi(immersive);
      if (immersive && !_wasImmersive) {
        _wasImmersive = true;
        if (_overlayHidden) {
          setState(() => _overlayHidden = false);
        }
        _scheduleOverlayHide();
      } else if (!immersive) {
        _wasImmersive = false;
      }
      if (orientation == Orientation.portrait && _landscapeBlocked) {
        setState(() => _landscapeBlocked = false);
      }
    });

    final Widget player = _buildPlayerArea();

    if (immersive) {
      return PopScope<Object?>(
        canPop: false,
        onPopInvokedWithResult: (bool didPop, Object? result) {
          if (!didPop) _handleBack();
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              player,
              if (!_overlayHidden) _buildImmersiveTopBar(context),
              if (!_overlayHidden) _buildImmersiveBottomBar(context),
            ],
          ),
        ),
      );
    }

    final ThemeData theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: <Widget>[
          IconButton(
            tooltip: _muted ? '开启声音' : '静音',
            onPressed: _toggleMute,
            icon: Icon(
              _muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
            ),
          ),
          IconButton(
            tooltip: '全屏',
            onPressed: () => _setImmersive(true),
            icon: const Icon(Icons.fullscreen_rounded),
          ),
          IconButton(
            tooltip: '重新加载',
            onPressed: _reloadPage,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final double ideal = constraints.maxWidth * 9 / 16;
            final double cap =
                constraints.maxHeight *
                (orientation == Orientation.landscape ? 0.68 : 0.6);
            final double videoHeight = math.max(120.0, math.min(ideal, cap));
            return Column(
              children: <Widget>[
                SizedBox(
                  width: double.infinity,
                  height: videoHeight,
                  child: player,
                ),
                Expanded(child: _buildInfoPanel(context)),
              ],
            );
          },
        ),
      ),
    );
  }

  // ---------- 视频区 ----------

  Widget _buildPlayerArea() {
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: _buildPlayerLayers(),
      ),
    );
  }

  List<Widget> _buildPlayerLayers() {
    switch (_kind) {
      case _PlayerKind.probing:
        return <Widget>[
          const Center(
            child: SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                color: Colors.white70,
              ),
            ),
          ),
          const Positioned(
            left: 0,
            right: 0,
            bottom: 14,
            child: Text(
              '正在检测视频编码…',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white60, fontSize: 12),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(
              minHeight: 2,
              backgroundColor: Colors.white12,
            ),
          ),
        ];
      case _PlayerKind.web:
        return <Widget>[
          if (_controller != null) WebViewWidget(controller: _controller!),
          if (!_pageReady && _loadError == null)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(
                minHeight: 2,
                value: _progress > 0 && _progress < 100
                    ? _progress / 100
                    : null,
                backgroundColor: Colors.white12,
              ),
            ),
          if (_loadError != null) _buildLoadErrorOverlay(),
        ];
      case _PlayerKind.native:
        return _buildNativeLayers();
    }
  }

  List<Widget> _buildNativeLayers() {
    final NativeFlvPlayerController? controller = _native;
    final String? src = _nativeSrc;
    if (controller == null || src == null) {
      return <Widget>[
        Center(
          child: Text(
            _message.isEmpty ? '原生播放器不可用' : _message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ),
      ];
    }
    return <Widget>[
      NativeFlvPlayer(
        controller: controller,
        src: src,
        isLive: !_isReplay,
        startMs: widget.startMs,
      ),
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: _toggleOverlay,
          onDoubleTap: () {
            final Orientation o = MediaQuery.orientationOf(context);
            _setImmersive(!_immersiveFor(o));
          },
        ),
      ),
      if (!_overlayHidden) _buildNativeStatusPill(),
      if (_phase == 'loading' || _phase == 'buffering')
        _buildNativeBufferingOverlay(),
      if (!_overlayHidden) _buildNativeControls(context),
      if (_phase == 'error') _buildNativeErrorOverlay(),
    ];
  }

  Widget _buildNativeStatusPill() {
    final Color color = _phaseColor(Theme.of(context).colorScheme);
    return Positioned(
      left: 10,
      top: 8,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.52),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(
              _phaseLabel,
              style: const TextStyle(color: Colors.white70, fontSize: 11),
            ),
            if (_resolutionLabel != null) ...<Widget>[
              const SizedBox(width: 6),
              Text(
                _resolutionLabel!,
                style: const TextStyle(color: Colors.white38, fontSize: 10),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildNativeBufferingOverlay() {
    final String text = _message.isNotEmpty
        ? _message
        : (_phase == 'loading' ? '正在启动解码器…' : '正在缓冲…');
    return Positioned.fill(
      child: IgnorePointer(
        child: ColoredBox(
          color: Colors.black.withValues(alpha: 0.30),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: Colors.white70,
                  ),
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    text,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNativeErrorOverlay() {
    final String text = _message.isEmpty ? '原生播放器出错' : _message;
    final bool unsupported =
        text.contains('H.265') || text.contains('H.264') || text.contains('硬解');
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.86),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(
                  Icons.error_outline_rounded,
                  color: Color(0xFFFF5B52),
                  size: 36,
                ),
                const SizedBox(height: 10),
                Text(
                  unsupported ? '当前设备无法硬解该视频' : '播放失败',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  text,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
                if (unsupported)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      '可尝试切换到 H.264 档位录制，或使用支持 H.265 硬解的设备。',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Color(0xFFFFB020),
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                  ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 10,
                  children: <Widget>[
                    FilledButton.icon(
                      onPressed: _retryPlayback,
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('重试'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.close_rounded, size: 18),
                      label: const Text('返回'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNativeControls(BuildContext context) {
    final bool showSlider = _isReplay && _duration > 0.05;
    final double sliderMax = showSlider ? _duration : 1;
    final double sliderValue = (_dragging ? _dragValue : _position)
        .clamp(0.0, sliderMax)
        .toDouble();
    final Orientation orientation = MediaQuery.orientationOf(context);
    final bool immersive = _immersiveFor(orientation);
    final String positionText =
        formatDuration(Duration(milliseconds: (_position * 1000).round()));
    final String durationText =
        formatDuration(Duration(milliseconds: (_duration * 1000).round()));
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: <Color>[Color(0xE6000000), Color(0x00000000)],
          ),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 22, 8, 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (showSlider)
                  Row(
                    children: <Widget>[
                      Text(
                        positionText,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                          fontFeatures: <FontFeature>[
                            FontFeature.tabularFigures(),
                          ],
                        ),
                      ),
                      Expanded(
                        child: SliderTheme(
                          data: SliderThemeData(
                            trackHeight: 2,
                            activeTrackColor: Colors.white,
                            inactiveTrackColor: Colors.white24,
                            thumbColor: Colors.white,
                            overlayColor: Colors.white24,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 6,
                            ),
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 14,
                            ),
                          ),
                          child: Slider(
                            value: sliderValue,
                            max: sliderMax,
                            onChangeStart: (double value) {
                              setState(() {
                                _dragging = true;
                                _dragValue = value;
                              });
                              _overlayTimer?.cancel();
                            },
                            onChanged: (double value) {
                              setState(() => _dragValue = value);
                            },
                            onChangeEnd: (double value) {
                              setState(() => _dragging = false);
                              _native?.seekTo(
                                Duration(
                                  milliseconds: (value * 1000).round(),
                                ),
                              );
                              if (_immersiveFor(
                                MediaQuery.orientationOf(context),
                              )) {
                                _scheduleOverlayHide();
                              }
                            },
                          ),
                        ),
                      ),
                      Text(
                        durationText,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                          fontFeatures: <FontFeature>[
                            FontFeature.tabularFigures(),
                          ],
                        ),
                      ),
                    ],
                  ),
                Row(
                  children: <Widget>[
                    _NativeIconButton(
                      tooltip: _phase == 'playing' ? '暂停' : '播放',
                      icon: _phase == 'playing'
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      onPressed: _togglePlayPause,
                    ),
                    _NativeIconButton(
                      tooltip: _muted ? '开启声音' : '静音',
                      icon: _muted
                          ? Icons.volume_off_rounded
                          : Icons.volume_up_rounded,
                      onPressed: _toggleMute,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        _isReplay
                            ? '$positionText / ${_duration > 0 ? durationText : "--:--"}'
                            : '直播 · $positionText',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                        ),
                      ),
                    ),
                    if (!_isReplay)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF2B52).withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: const Text(
                          'LIVE',
                          style: TextStyle(
                            color: Color(0xFFFF6B84),
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ),
                    _NativeIconButton(
                      tooltip: immersive ? '退出全屏' : '全屏',
                      icon: immersive
                          ? Icons.fullscreen_exit_rounded
                          : Icons.fullscreen_rounded,
                      onPressed: () => _setImmersive(!immersive),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLoadErrorOverlay() {
    final String error = _loadError ?? '';
    final bool cleartext = error.toUpperCase().contains('CLEARTEXT');
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.92),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(
                  Icons.error_outline_rounded,
                  color: Color(0xFFFF5B52),
                  size: 38,
                ),
                const SizedBox(height: 10),
                const Text(
                  '播放页加载失败',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  error.isEmpty ? '无法打开本地播放页' : error,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
                if (cleartext) ...<Widget>[
                  const SizedBox(height: 8),
                  const Text(
                    '本地服务是明文 HTTP，Android 9+ 需要在应用里允许 cleartext（127.0.0.1）',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFFFFB020),
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  children: <Widget>[
                    FilledButton.icon(
                      onPressed: _reloadPage,
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('重试'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.close_rounded, size: 18),
                      label: const Text('返回'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------- 沉浸式浮层 ----------

  Widget _buildImmersiveTopBar(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[Color(0xCC000000), Color(0x00000000)],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 2, 8, 12),
            child: Row(
              children: <Widget>[
                IconButton(
                  tooltip: '退出全屏',
                  onPressed: _handleBack,
                  icon: const Icon(
                    Icons.arrow_back_rounded,
                    color: Colors.white,
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        _phaseLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _phaseColor(Theme.of(context).colorScheme),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '退出全屏',
                  onPressed: () {
                    _overlayTimer?.cancel();
                    setState(() {
                      _manualImmersive = false;
                      _landscapeBlocked = true;
                    });
                  },
                  icon: const Icon(
                    Icons.fullscreen_exit_rounded,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildImmersiveBottomBar(BuildContext context) {
    final List<String> chips = <String>[
      _phaseLabel,
      _muted ? '静音' : '有声',
      if (_retry > 0) '重连 $_retry 次',
      ?_resolutionLabel,
      ?_bitrateLabel,
      ?_codecLabel,
    ];
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: <Color>[Color(0xCC000000), Color(0x00000000)],
          ),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (_message.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(
                            _message,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: _phaseColor(
                                Theme.of(context).colorScheme,
                              ),
                              fontSize: 11,
                              height: 1.4,
                            ),
                          ),
                        ),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: <Widget>[
                          for (final String text in chips)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 9,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                text,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: _muted ? '开启声音' : '静音',
                  onPressed: _toggleMute,
                  icon: Icon(
                    _muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                    color: Colors.white,
                  ),
                ),
                IconButton(
                  tooltip: '重新连接',
                  onPressed: _retryPlayback,
                  icon: const Icon(Icons.refresh_rounded, color: Colors.white),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------- 竖屏信息面板 ----------

  bool get _showAlert =>
      _loadError != null ||
      _phase == 'error' ||
      _phase == 'stopped' ||
      (_message.isNotEmpty && _phase != 'playing' && _phase != 'loading');

  Widget _buildAlertBanner(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool stopped = _phase == 'stopped';
    final bool failed = _phase == 'error' || _loadError != null;
    final Color color = failed || stopped
        ? const Color(0xFFFF5B52)
        : const Color(0xFFFFB020);
    final String headline = stopped
        ? '录制已停止'
        : (failed ? '播放失败' : '连接不稳定');
    final String detail = _loadError ??
        (_message.isNotEmpty
            ? _message
            : (stopped ? '/live 返回 404，任务可能已结束' : '正在自动重试'));
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            stopped
                ? Icons.stop_circle_outlined
                : (failed
                      ? Icons.error_outline_rounded
                      : Icons.sync_problem_rounded),
            color: color,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  headline,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.45,
                  ),
                ),
                if (_retry > 0 && _phase == 'reconnect')
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '已自动重连 $_retry 次（每 2 秒一次，不会停）',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          TextButton(
            onPressed: _retryPlayback,
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }

  Widget _buildDiagCard(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 10, right: 8),
          title: Text(
            '诊断信息（远端定位用）',
            style: theme.textTheme.labelLarge?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              IconButton(
                tooltip: '刷新',
                onPressed: _requestDiag,
                icon: const Icon(Icons.refresh_rounded, size: 18),
              ),
              IconButton(
                tooltip: '复制',
                onPressed: () {
                  final String text = <String>[
                    'title=${widget.title}',
                    'url=${widget.url}',
                    'engine=$_engineLabel',
                    'codec=${_codecLabel ?? "unknown"}',
                    'error=${_loadError ?? ''}',
                    _diag ?? '',
                  ].join('\n');
                  Clipboard.setData(ClipboardData(text: text));
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    const SnackBar(content: Text('诊断信息已复制')),
                  );
                },
                icon: const Icon(Icons.copy_rounded, size: 18),
              ),
            ],
          ),
          children: <Widget>[
            if (_loadError != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8, right: 8),
                  child: Text(
                    '页面加载错误：$_loadError',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ),
            if (_diag != null)
              Align(
                alignment: Alignment.centerLeft,
                child: SelectableText(
                  _diag!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    height: 1.35,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoPanel(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final List<Widget> chips = <Widget>[
      _StatusChip(
        label: _phaseLabel,
        color: _phaseColor(scheme),
        icon: Icons.circle,
      ),
      _StatusChip(
        label: _muted ? '静音' : '有声',
        color: scheme.onSurfaceVariant,
        icon: _muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
      ),
      if (_codecLabel != null)
        _StatusChip(
          label: _codecLabel!,
          color: scheme.onSurfaceVariant,
          icon: Icons.movie_filter_rounded,
        ),
      if (_retry > 0)
        _StatusChip(
          label: '重连 $_retry 次',
          color: const Color(0xFFFFB020),
          icon: Icons.sync_problem_rounded,
        ),
      if (_resolutionLabel != null)
        _StatusChip(
          label: _resolutionLabel!,
          color: scheme.onSurfaceVariant,
          icon: Icons.aspect_ratio_rounded,
        ),
      if (_bitrateLabel != null)
        _StatusChip(
          label: _bitrateLabel!,
          color: scheme.onSurfaceVariant,
          icon: Icons.speed_rounded,
        ),
    ];

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
      children: <Widget>[
        if (_showAlert) _buildAlertBanner(context),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    widget.title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    widget.subtitle ?? _modeLabel,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            _StatusChip(
              label: _modeLabel,
              color: _isReplay ? scheme.tertiary : scheme.primary,
              icon: _isReplay ? Icons.history_rounded : Icons.sensors_rounded,
            ),
          ],
        ),
        const SizedBox(height: 14),
        Wrap(spacing: 8, runSpacing: 8, children: chips),
        const SizedBox(height: 16),
        _buildDetailCard(context),
        const SizedBox(height: 16),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: <Widget>[
            FilledButton.tonalIcon(
              onPressed: () => _setImmersive(true),
              icon: const Icon(Icons.fullscreen_rounded, size: 18),
              label: const Text('全屏'),
            ),
            OutlinedButton.icon(
              onPressed: _retryPlayback,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: Text(_isReplay ? '重新播放' : '重新连接'),
            ),
            OutlinedButton.icon(
              onPressed: _reloadPage,
              icon: const Icon(Icons.restart_alt_rounded, size: 18),
              label: const Text('重载页面'),
            ),
            OutlinedButton.icon(
              onPressed: _toggleMute,
              icon: Icon(
                _muted ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                size: 18,
              ),
              label: Text(_muted ? '开启声音' : '静音'),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _buildHintCard(context),
        if (_diag != null || _loadError != null || _kind == _PlayerKind.native)
          ...<Widget>[
            const SizedBox(height: 16),
            _buildDiagCard(context),
          ],
      ],
    );
  }

  Widget _buildDetailCard(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final NativeFlvPlayerController? controller = _native;
    final List<_ListEntry> entries = <_ListEntry>[
      _ListEntry('加载状态', _loadStatusLabel),
      _ListEntry('连接状态', _phaseLabel),
      _ListEntry('播放内核', _engineLabel),
      if (_codecLabel != null)
        _ListEntry(
          '视频编码',
          '$_codecLabel${_codecInfo?.hasSequenceHeader == true ? " · 含序列头" : ""}',
        ),
      if (controller != null && controller.decoder.isNotEmpty)
        _ListEntry('解码器', controller.decoder),
      if (controller != null && controller.frames > 0)
        _ListEntry('解码帧数', '${controller.frames} 帧'),
      if (controller != null && controller.audioStarted)
        _ListEntry('音轨', 'AudioTrack 已启动（${controller.audioFrames} 帧）'),
      if (_kind == _PlayerKind.native && _isReplay)
        _ListEntry(
          '播放进度',
          '${formatDuration(Duration(milliseconds: (_position * 1000).round()))}'
              ' / ${formatDuration(Duration(milliseconds: (_duration * 1000).round()))}',
        ),
      if (_resolutionLabel != null) _ListEntry('分辨率', _resolutionLabel!),
      if (_bitrateLabel != null) _ListEntry('实时码率', _bitrateLabel!),
      if (_speedKbps > 0) _ListEntry('上游速率', '$_speedKbps KB/s'),
      if (_retry > 0) _ListEntry('自动重连', '第 $_retry 次（每 2 秒重试，直至成功）'),
      if (_message.isNotEmpty) _ListEntry('提示', _message),
    ];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
      ),
      child: Column(
        children: <Widget>[
          for (int i = 0; i < entries.length; i++) ...<Widget>[
            if (i > 0)
              Divider(
                height: 1,
                color: scheme.outlineVariant.withValues(alpha: 0.4),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(
                    width: 76,
                    child: Text(
                      entries[i].label,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      entries[i].value,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHintCard(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.25),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                Icons.lightbulb_outline_rounded,
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                '操作提示',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _isReplay
                ? (_kind == _PlayerKind.native
                      ? '· 底部可拖动进度条、播放/暂停、调音量\n'
                            '· 原生解码：H.265 走 MediaCodec 硬解，拖动按关键帧跳转\n'
                            '· 双击视频进入全屏，单击显示/隐藏控件'
                      : '· 页面内可拖动进度条、播放/暂停、调音量\n'
                            '· 双击视频进入全屏，单击显示/隐藏控件\n'
                            '· 跳过已缓存区间会给出提示')
                : '· 直播流断开会自动重连（每 2 秒一次，无限重试）\n'
                      '· 双击视频进入全屏，单击显示/隐藏控件\n'
                      '· 默认静音起播，点喇叭开启声音',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.7,
            ),
          ),
        ],
      ),
    );
  }
}

class _NativeIconButton extends StatelessWidget {
  const _NativeIconButton({
    required this.icon,
    required this.onPressed,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final Widget button = InkResponse(
      onTap: onPressed,
      radius: 22,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(icon, color: Colors.white, size: 22),
      ),
    );
    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}

/// 详情行数据。
class _ListEntry {
  const _ListEntry(this.label, this.value);

  final String label;
  final String value;
}

/// 小状态胶囊。
class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.label,
    required this.color,
    required this.icon,
  });

  final String label;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
