import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app.dart';
import 'live_preview_page.dart';

/// 自动化验收入口：
///
/// ```bash
/// adb shell am start -n com.liquidlab.live_recorder/.MainActivity \
///   --es play_file /sdcard/Movies/直播录制/xxx/part01.flv
/// ```
///
/// MainActivity 把路径暂存在 `live_recorder/debug` 通道；Dart 侧启动/热启动后
/// 消费一次并清空，避免 Activity 重建时重复打开。
class DebugPlayEntry {
  DebugPlayEntry._();

  static const MethodChannel _channel = MethodChannel('live_recorder/debug');

  static bool _installed = false;
  static String? _pendingPath;
  static int _pendingSeekMs = 0;
  static String? _lastPath;
  static int _lastSeekMs = 0;
  static DateTime? _lastAt;
  static String Function(String path)? _urlBuilder;
  static Timer? _retryTimer;

  static void install({required String Function(String path) urlBuilder}) {
    if (_installed || !Platform.isAndroid) return;
    _installed = true;
    _urlBuilder = urlBuilder;
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'incomingPlayFile') {
        final Object? args = call.arguments;
        if (args is String && args.trim().isNotEmpty) {
          _open(args.trim(), startMs: _pendingSeekMs);
          _pendingSeekMs = 0;
        }
      } else if (call.method == 'incomingPlaySeek') {
        final Object? args = call.arguments;
        if (args is num) {
          _pendingSeekMs = args.toInt();
        }
      }
      return null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_poll());
    });
    // 通道在 configureFlutterEngine 时已注册，这里立刻取一次；postFrame 再兜底一次。
    unawaited(_poll());
    Timer(const Duration(seconds: 1), () => unawaited(_poll()));
    debugPrint('[debug] play_file entry installed');
  }

  static Future<void> _poll() async {
    debugPrint('[debug] getPlayFile poll');
    try {
      final String? path = await _channel.invokeMethod<String>('getPlayFile');
      int seekMs = 0;
      try {
        seekMs =
            await _channel.invokeMethod<int>('getPlaySeekMs') ?? 0;
      } catch (_) {}
      debugPrint('[debug] getPlayFile result=$path seek=$seekMs');
      if (path != null && path.trim().isNotEmpty) {
        _open(path.trim(), startMs: seekMs);
      }
    } catch (e) {
      debugPrint('[debug] getPlayFile failed: $e');
    }
  }

  static void _open(String path, {int startMs = 0}) {
    final DateTime now = DateTime.now();
    if (_lastPath == path &&
        _lastSeekMs == startMs &&
        _lastAt != null &&
        now.difference(_lastAt!) < const Duration(seconds: 3)) {
      return;
    }
    _lastPath = path;
    _lastSeekMs = startMs;
    _lastAt = now;

    final NavigatorState? navigator = LiveRecorderApp.navigatorKey.currentState;
    final String Function(String)? builder = _urlBuilder;
    if (navigator == null || builder == null) {
      _pendingPath = path;
      _pendingSeekMs = startMs;
      _retryTimer?.cancel();
      _retryTimer = Timer(const Duration(milliseconds: 300), _flushPending);
      return;
    }
    _pendingPath = null;
    final String title = path.split(RegExp(r'[\\/]')).last;
    navigator.push(MaterialPageRoute<void>(
      builder: (_) => LivePreviewPage(
        title: title.isEmpty ? '调试回放' : title,
        url: builder(path),
        subtitle: path,
        startMs: startMs,
      ),
    ));
    debugPrint('[debug] opening playback: $path startMs=$startMs');
  }

  static void _flushPending() {
    final String? path = _pendingPath;
    if (path == null) return;
    final int startMs = _pendingSeekMs;
    _pendingPath = null;
    _pendingSeekMs = 0;
    _open(path, startMs: startMs);
  }
}
