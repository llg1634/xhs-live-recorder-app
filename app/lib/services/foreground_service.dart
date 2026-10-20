import 'dart:io';

import 'package:flutter/services.dart';

/// 后台保活：只要有录制任务就常驻原生前台服务，息屏/切后台不中断。
///
/// 原生实现见 `android/app/src/main/kotlin/.../RecordingForegroundService.kt`，
/// 通过 MethodChannel `live_recorder/foreground` 通信。
class ForegroundKeepAlive {
  static const MethodChannel _channel =
      MethodChannel('live_recorder/foreground');

  static bool _running = false;
  static int _lastCount = 0;

  static Future<void> init() async {
    // 原生侧无需初始化；保留方法便于后续扩展。
  }

  /// 根据当前活跃任务数启动 / 更新 / 停止前台服务。
  static Future<void> sync({required int activeCount}) async {
    if (!Platform.isAndroid) return;

    if (activeCount <= 0) {
      if (_running) {
        try {
          await _channel.invokeMethod<void>('stop');
        } catch (_) {}
        _running = false;
        _lastCount = 0;
      }
      return;
    }

    final title = activeCount == 1 ? '正在录制 1 个直播间' : '正在录制 $activeCount 个直播间';
    final text = activeCount == 1 ? '录制中，息屏也会继续' : '$activeCount 个任务并行录制中';

    if (_running && _lastCount == activeCount) return;

    try {
      await _channel.invokeMethod<void>(_running ? 'update' : 'start', {
        'title': title,
        'text': text,
      });
      _running = true;
      _lastCount = activeCount;
    } catch (_) {}
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    if (!_running) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
    _running = false;
  }

  /// 跳到系统的通知设置页（部分机型通知被关掉后前台服务不可见）。
  static Future<void> openNotificationSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('openNotificationSettings');
    } catch (_) {}
  }
}
