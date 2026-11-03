import 'dart:io';

import 'package:flutter/services.dart';

/// 前台服务通知的汇总状态。
///
/// 为什么不把整张任务表传给原生：通知栏只需要一行汇总文案，
/// 由 Dart 侧算好总量/重连状态，原生只负责显示，避免 MethodChannel 传大对象。
class ForegroundStatus {
  const ForegroundStatus({
    this.reconnectingCount = 0,
    this.reconnectAttempt = 0,
    this.totalBytes = 0,
    this.longFailure = false,
  });

  static const ForegroundStatus empty = ForegroundStatus();

  /// 正在重连的任务数。
  final int reconnectingCount;

  /// 重连任务里最大的连续尝试序号（第 N 次）。
  final int reconnectAttempt;

  /// 所有活跃任务已写入的总字节数。
  final int totalBytes;

  /// 是否已连续失败超过 10 分钟（文案升级为「网络异常」）。
  final bool longFailure;
}

/// 后台保活：只要有录制任务就常驻原生前台服务，息屏/切后台不中断。
///
/// 原生实现见 `android/app/src/main/kotlin/.../RecordingForegroundService.kt`，
/// 通过 MethodChannel `live_recorder/foreground` 通信。
///
/// 通知文案会随任务状态变化（录制中 / 重连中第 N 次 / 网络异常），
/// 所以 [sync] 不能只按 activeCount 去重，还要比较完整文案签名。
class ForegroundKeepAlive {
  static const MethodChannel _channel = MethodChannel(
    'live_recorder/foreground',
  );

  static bool _running = false;
  static String? _lastSignature;
  static ForegroundStatus _status = ForegroundStatus.empty;

  static Future<void> init() async {
    // 原生侧无需初始化；保留方法便于后续扩展。
  }

  /// 由 RecordingManager 在 notifyListeners 前调用，记录最新的汇总状态。
  ///
  /// main.dart 只调用 `sync(activeCount: ...)`，这里保存的状态会被 [sync]
  /// 自动带上，因此不需要改 main.dart / UI 的调用点。
  static void updateStatus(ForegroundStatus status) {
    _status = status;
  }

  /// 通知标题（纯函数，便于单测文案）。
  static String titleFor(int activeCount) {
    if (_status.reconnectingCount > 0) {
      return activeCount == 1 ? '直播录制 · 重连中' : '直播录制 · $activeCount 个任务';
    }
    return activeCount == 1 ? '正在录制 1 个直播间' : '正在录制 $activeCount 个直播间';
  }

  /// 通知正文（纯函数，便于单测文案）：
  /// 重连中显示「重连中（第 N 次）· 已录 X MB」，超 10 分钟升级为「网络异常」。
  static String textFor(int activeCount) {
    if (_status.reconnectingCount > 0) {
      final String prefix = _status.longFailure
          ? '网络异常，已重试 ${_status.reconnectAttempt} 次'
          : activeCount == 1
          ? '重连中（第 ${_status.reconnectAttempt} 次）'
          : '${_status.reconnectingCount} 个任务重连中（第 ${_status.reconnectAttempt} 次）';
      return '$prefix· 已录 ${_formatMb(_status.totalBytes)} MB';
    }
    final String prefix = activeCount == 1
        ? '录制中，息屏也会继续'
        : '$activeCount 个任务并行录制中';
    return '$prefix· 已录 ${_formatMb(_status.totalBytes)} MB';
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
      }
      _lastSignature = null;
      _status = ForegroundStatus.empty;
      return;
    }

    final String title = titleFor(activeCount);
    final String text = textFor(activeCount);

    final String signature = '$title\n$text';
    if (_running && _lastSignature == signature) return;

    try {
      await _channel.invokeMethod<void>(_running ? 'update' : 'start', {
        'title': title,
        'text': text,
      });
      _running = true;
      _lastSignature = signature;
    } catch (_) {}
  }

  /// 已录字节数 → 通知里的 MB 文案（保留 1 位小数，够用且不抖）。
  static String _formatMb(int bytes) {
    if (bytes <= 0) return '0.0';
    final double mb = bytes / (1024 * 1024);
    return mb.toStringAsFixed(mb >= 100 ? 0 : 1);
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    if (!_running) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
    _running = false;
    _lastSignature = null;
    _status = ForegroundStatus.empty;
  }

  /// 跳到系统的通知设置页（部分机型通知被关掉后前台服务不可见）。
  static Future<void> openNotificationSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('openNotificationSettings');
    } catch (_) {}
  }

  /// 是否已获得「忽略电池优化」豁免。
  ///
  /// 没有豁免时，设备进入 Doze 会掐断后台网络 —— 断流后连不上、也不会重试，
  /// 直到用户重新打开 App。这是「后台自动重连」能否成立的前提。
  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (!Platform.isAndroid) return true;
    try {
      final bool? value =
          await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations');
      return value ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 弹系统「忽略电池优化」确认框；返回是否成功拉起系统页面。
  static Future<bool> requestIgnoreBatteryOptimizations() async {
    if (!Platform.isAndroid) return true;
    try {
      final bool? value = await _channel
          .invokeMethod<bool>('requestIgnoreBatteryOptimizations');
      return value ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 打开本应用的系统详情页（小米的「省电策略 / 自启动」在附近）。
  static Future<void> openAppSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('openAppSettings');
    } catch (_) {}
  }
}
