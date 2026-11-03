import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 原生 FLV 播放器（Kotlin MediaCodec）。
///
/// 原生端：
/// - viewType: `live_recorder/flv_player`（TextureView）
/// - channel:  `live_recorder/player`（open/play/pause/seekTo/setVolume/setMuted/release）
/// - 状态回调：同一 channel 的 `state` 方法，字段对齐 `player.html` 的 state。
class NativeFlvPlayerController extends ChangeNotifier {
  NativeFlvPlayerController({this.isLive = false});

  static const String channelName = 'live_recorder/player';
  static const MethodChannel _channel = MethodChannel(channelName);

  static final Map<int, NativeFlvPlayerController> _controllers =
      <int, NativeFlvPlayerController>{};
  static bool _handlerInstalled = false;
  static int _nextPlayerId = 0;

  static void _ensureHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method != 'state') return null;
      final Object? args = call.arguments;
      if (args is! Map) return null;
      final Map<Object?, Object?> map = args;
      final Object? rawId = map['playerId'];
      final int? playerId = rawId is num ? rawId.toInt() : null;
      if (playerId == null) return null;
      _controllers[playerId]?._applyState(map);
      return null;
    });
  }

  final bool isLive;

  late final int playerId = _nextPlayerId++;

  bool _attached = false;
  bool _disposed = false;

  String _phase = 'loading';
  double _position = 0;
  double _duration = 0;
  int _width = 0;
  int _height = 0;
  bool _muted = true;
  double _volume = 1;
  int _retry = 0;
  String _message = '';
  String _decoder = '';
  int _frames = 0;
  int _audioFrames = 0;
  bool _audioStarted = false;
  String _codec = 'unknown';
  Map<String, Object?> _diag = <String, Object?>{};

  String? _src;
  bool _lastIsLive = false;
  int _lastStartMs = 0;

  String get phase => _phase;
  double get position => _position;
  double get duration => _duration;
  int get width => _width;
  int get height => _height;
  bool get muted => _muted;
  double get volume => _volume;
  int get retry => _retry;
  String get message => _message;
  String get decoder => _decoder;
  int get frames => _frames;
  int get audioFrames => _audioFrames;
  bool get audioStarted => _audioStarted;
  String get codec => _codec;
  Map<String, Object?> get diag => _diag;
  String? get source => _src;
  bool get attached => _attached;

  double get aspectRatio =>
      (_width > 0 && _height > 0) ? _width / _height : 16 / 9;

  /// AndroidView 创建完成后调用一次（原生侧已注册 playerId）。
  void attach() {
    if (_disposed) return;
    if (_attached) return;
    _attached = true;
    _ensureHandler();
    _controllers[playerId] = this;
    final String? src = _src;
    if (src != null && src.isNotEmpty) {
      _sendOpen(src, _lastIsLive, _lastStartMs);
    }
  }

  Future<void> open({
    required String src,
    required bool isLive,
    int startMs = 0,
    bool? muted,
  }) async {
    if (_disposed) return;
    _src = src;
    _lastIsLive = isLive;
    _lastStartMs = startMs;
    _phase = 'loading';
    _message = '';
    _position = 0;
    _duration = 0;
    _width = 0;
    _height = 0;
    _retry = 0;
    _frames = 0;
    _audioFrames = 0;
    _audioStarted = false;
    _decoder = '';
    if (muted != null) _muted = muted;
    _notify();
    if (_attached) {
      await _sendOpen(src, isLive, startMs);
    }
  }

  Future<void> _sendOpen(String src, bool isLive, int startMs) async {
    await _invoke('open', <String, Object?>{
      'src': src,
      'isLive': isLive,
      'startMs': startMs,
      'muted': _muted,
      'volume': _volume,
    });
  }

  Future<void> play() => _invoke('play');

  Future<void> pause() => _invoke('pause');

  Future<void> seekTo(Duration position) async {
    final int ms = position.inMilliseconds;
    _position = ms / 1000.0;
    _notify();
    await _invoke('seekTo', <String, Object?>{'ms': ms});
  }

  Future<void> setMuted(bool value) async {
    if (_muted == value) return;
    _muted = value;
    _notify();
    await _invoke('setMuted', <String, Object?>{'muted': value});
  }

  Future<void> setVolume(double value) async {
    _volume = value.clamp(0.0, 1.0);
    if (_volume > 0 && _muted) _muted = false;
    _notify();
    await _invoke('setVolume', <String, Object?>{'volume': _volume});
  }

  /// 重新打开当前地址（直播重连 / 回放重播）。
  Future<void> reopen() async {
    final String? src = _src;
    if (src == null || src.isEmpty) return;
    _phase = 'loading';
    _message = '';
    _duration = 0;
    _position = 0;
    _retry = 0;
    _frames = 0;
    _audioFrames = 0;
    _audioStarted = false;
    _notify();
    await _sendOpen(src, _lastIsLive, 0);
  }

  Future<void> _invoke(String method, [Map<String, Object?>? args]) async {
    if (!_attached) return;
    try {
      await _channel.invokeMethod<Object?>(method, <String, Object?>{
        'playerId': playerId,
        ...?args,
      });
    } on PlatformException catch (e) {
      _phase = 'error';
      _message = e.message ?? '原生播放器调用失败（$method）';
      _notify();
    } on MissingPluginException {
      _phase = 'error';
      _message = '原生播放器不可用（缺少平台实现）';
      _notify();
    } catch (e) {
      _phase = 'error';
      _message = '原生播放器调用失败：$e';
      _notify();
    }
  }

  void _applyState(Map<Object?, Object?> map) {
    if (_disposed) return;
    String asString(Object? value, String fallback) =>
        value is String ? value : fallback;
    double asDouble(Object? value, double fallback) {
      if (value is num) return value.toDouble();
      return fallback;
    }

    int asInt(Object? value, int fallback) {
      if (value is num) return value.toInt();
      return fallback;
    }

    _phase = asString(map['phase'], _phase);
    _position = asDouble(map['position'], _position);
    _duration = asDouble(map['duration'], _duration);
    _width = asInt(map['width'], _width);
    _height = asInt(map['height'], _height);
    _muted = map['muted'] == true;
    _volume = asDouble(map['volume'], _volume);
    _retry = asInt(map['retry'], _retry);
    _message = asString(map['message'], '');
    _decoder = asString(map['decoder'], '');
    _frames = asInt(map['frames'], _frames);
    _audioFrames = asInt(map['audioFrames'], _audioFrames);
    _audioStarted = map['audio'] == true;
    _codec = asString(map['codec'], _codec);
    _diag = <String, Object?>{
      'phase': _phase,
      'position': _position,
      'duration': _duration,
      'width': _width,
      'height': _height,
      'muted': _muted,
      'volume': _volume,
      'retry': _retry,
      'message': _message,
      'decoder': _decoder,
      'frames': _frames,
      'audioFrames': _audioFrames,
      'audioStarted': _audioStarted,
      'codec': _codec,
    };
    _notify();
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _controllers.remove(playerId);
    if (_attached) {
      // 平台视图 dispose 时也会兜底 release；这里主动调用一次避免页面提前销毁。
      _channel.invokeMethod<Object?>('release', <String, Object?>{
        'playerId': playerId,
      }).catchError((Object _) => null);
    }
    super.dispose();
  }
}

/// AndroidView 包装：自动按解码后的宽高保持视频比例。
class NativeFlvPlayer extends StatefulWidget {
  const NativeFlvPlayer({
    super.key,
    required this.controller,
    required this.src,
    required this.isLive,
    this.startMs = 0,
  });

  final NativeFlvPlayerController controller;
  final String src;
  final bool isLive;
  final int startMs;

  @override
  State<NativeFlvPlayer> createState() => _NativeFlvPlayerState();
}

class _NativeFlvPlayerState extends State<NativeFlvPlayer> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.android || kIsWeb) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(
          child: Text(
            '原生播放器仅支持 Android',
            style: TextStyle(color: Colors.white70),
          ),
        ),
      );
    }
    final NativeFlvPlayerController controller = widget.controller;
    final double ratio = controller.aspectRatio;
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: AspectRatio(
          aspectRatio: ratio.isFinite && ratio > 0 ? ratio : 16 / 9,
          child: AndroidView(
            viewType: 'live_recorder/flv_player',
            creationParams: <String, Object?>{
              'playerId': controller.playerId,
              'src': widget.src,
              'isLive': widget.isLive,
              'startMs': widget.startMs,
            },
            creationParamsCodec: const StandardMessageCodec(),
            onPlatformViewCreated: (int id) async {
              controller.attach();
              await controller.open(
                src: widget.src,
                isLive: widget.isLive,
                startMs: widget.startMs,
              );
            },
          ),
        ),
      ),
    );
  }
}
