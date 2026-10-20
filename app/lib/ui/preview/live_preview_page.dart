import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// 直播/回放播放页：WebView 承载 `assets/web/player.html`（flv.js），
/// Flutter 侧只负责“壳”——加载进度、错误重试、状态展示、沉浸式全屏。
///
/// 页面（JS）通过 `PlayerBridge` 通道上报：
/// - `{"type":"state", "phase":"loading|playing|paused|reconnect|ended|error", ...}`
/// - `{"type":"fullscreen","on":bool}` 双击 / 页面全屏按钮
/// - `{"type":"tap"}` 单击视频（联动隐藏/显示浮层）
/// - `{"type":"error","message":"..."}` 视频层致命错误
///
/// Flutter 反向调用 `window.PV`：`setImmersive / toggleMute / setMuted /
/// reconnect / toggle / seekTo / destroy`。
///
/// 屏幕常亮：本次不新增 pub 依赖，不叠 Timer 兑底（JS 定时器不能阻止息屏）。
/// Android WebView 在 `<video>` 播放期间由平台维持亮屏；如果真机上仍会息屏，
/// 需要后续引入 wakelock_plus 之类的依赖，或在 MainActivity 加 KEEP_SCREEN_ON。
class LivePreviewPage extends StatefulWidget {
  const LivePreviewPage({
    super.key,
    required this.title,
    required this.url,
    this.subtitle,
  });

  /// 标题（直播任务名 / 录像文件名）。
  final String title;

  /// 本地服务上的播放页地址，例：
  /// `http://127.0.0.1:PORT/player.html?src=%2Flive%2FtaskId.flv&title=...`
  final String url;

  /// 可选副标题，例如分段文件名。
  final String? subtitle;

  @override
  State<LivePreviewPage> createState() => _LivePreviewPageState();
}

class _LivePreviewPageState extends State<LivePreviewPage>
    with WidgetsBindingObserver {
  static const String _channelName = 'PlayerBridge';
  static const Duration _loadTimeout = Duration(seconds: 15);
  static const Duration _overlayHideDelay = Duration(seconds: 4);

  late final WebViewController _controller;

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

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF000000))
      ..addJavaScriptChannel(_channelName, onMessageReceived: _onBridgeMessage)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (int progress) {
            if (!mounted || _loadError != null) return;
            if (progress == _progress) return;
            setState(() => _progress = progress);
          },
          onPageStarted: (String url) {
            if (!mounted) return;
            setState(() {
              _pageReady = false;
              _progress = 0;
            });
            _startLoadWatchdog();
          },
          onPageFinished: (String url) {
            if (!mounted || _loadError != null) return;
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
            final status = error.response?.statusCode ?? 0;
            if (status >= 400) {
              _failPage('播放页返回 HTTP $status');
            }
          },
        ),
      );

    final String target = widget.url.trim();
    if (target.isEmpty) {
      _loadError = '缺少播放地址（url 为空）';
      _phase = 'error';
      _message = _loadError!;
    } else {
      _controller.loadRequest(Uri.parse(target));
      _startLoadWatchdog();
    }
  }

  @override
  void dispose() {
    _loadWatchdog?.cancel();
    _overlayTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    // 让页面销毁 flv.js 播放器、清理定时器（WebView 释放前尽力而为）。
    try {
      _controller
          .runJavaScript(
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
    // 同一个路由换了地址：重新识别模式并重载页面。
    _isReplay = _detectReplay(widget.url);
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
    final String target = widget.url.trim();
    if (target.isEmpty) {
      _failPage('缺少播放地址（url 为空）');
    } else {
      _startLoadWatchdog();
      _controller.loadRequest(Uri.parse(target));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从后台回来时 Android 可能已重置沉浸式标记，重新应用一次。
    if (state == AppLifecycleState.resumed && mounted) {
      _appliedImmersive = null;
      _applySystemUi(_immersiveFor(MediaQuery.orientationOf(context)));
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
    try {
      await _controller.runJavaScript(script);
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
    if (!_pageReady) return;
    if (_sentImmersive == immersive) return;
    _sentImmersive = immersive;
    _runJs(
      'window.PV && window.PV.setImmersive && '
      'window.PV.setImmersive(${immersive ? 'true' : 'false'});',
    );
  }

  // ===================== 页面状态回调 =====================

  void _onBridgeMessage(JavaScriptMessage message) {
    if (!mounted) return;
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

  void _applyState(Map<dynamic, dynamic> data) {
    final String phase = data['phase']?.toString() ?? 'loading';
    final bool muted = data['muted'] == true;
    final int retry = _asInt(data['retry']);
    final int bitrate = _asInt(data['bitrate']);
    final int speed = _asInt(data['speedKBps']);
    final int w = _asInt(data['width']);
    final int h = _asInt(data['height']);
    final String message = data['message']?.toString() ?? '';

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
      if (_loadError != null && phase != 'error') {
        // 页面已能跑起来，撤掉“加载失败”遮罩。
        _loadError = null;
      }
    });
    if (phase == 'error' || phase == 'stopped') {
      _requestDiag();
    }
  }

  /// 出错时取一次页面诊断信息（WebView UA / MSE / 最近错误 / 数据间隔），
  /// 方便你不在现场也能定位“卡在加载中”这类问题。
  void _requestDiag() {
    if (!mounted || !_pageReady || _diagLoading) return;
    _diagLoading = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fetchDiag();
    });
  }

  Future<void> _fetchDiag() async {
    try {
      final Object raw = await _controller.runJavaScriptReturningResult(
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
      await _controller.reload();
    } catch (_) {}
  }

  Future<void> _retryPlayback() async {
    if (_loadError != null) {
      await _reloadPage();
      return;
    }
    _runJs('window.PV && window.PV.reconnect && window.PV.reconnect();');
  }

  void _toggleMute() {
    _runJs('window.PV && window.PV.toggleMute && window.PV.toggleMute();');
  }

  // ===================== 文案 =====================

  String get _modeLabel => _isReplay ? '录像回放' : '直播预览';

  String get _phaseLabel {
    switch (_phase) {
      case 'playing':
        return _isReplay ? '播放中' : '直播中';
      case 'loading':
        return _retry > 0 ? '重连中（第 $_retry 次）' : '连接中';
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
        children: <Widget>[
          WebViewWidget(controller: _controller),
          // 页面加载进度（只在首屏加载时出现，避免遮挡播放）。
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
        ],
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
        if (_diag != null || _loadError != null) ...<Widget>[
          const SizedBox(height: 16),
          _buildDiagCard(context),
        ],
      ],
    );
  }

  Widget _buildDetailCard(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final List<_ListEntry> entries = <_ListEntry>[
      _ListEntry(
        '加载状态',
        _pageReady ? '播放页已加载' : (_loadError != null ? '失败' : '加载中 $_progress%'),
      ),
      _ListEntry('连接状态', _phaseLabel),
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
                ? '· 页面内可拖动进度条、播放/暂停、调音量\n'
                      '· 双击视频进入全屏，单击显示/隐藏控件\n'
                      '· 跳过已缓存区间会给出提示'
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
