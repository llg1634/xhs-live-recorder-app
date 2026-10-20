import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 外部拉起入口：`adb shell am start -n <pkg>/.MainActivity --es autostart "<链接>"`
/// 或从分享面板打开链接时，直接把链接交给录制管理器。
class LaunchIntent {
  static const MethodChannel _channel =
      MethodChannel('live_recorder/foreground');

  static bool _inited = false;

  static void init(void Function(String url, bool withComments) onUrl,
      {void Function(String url)? onProbe,
      void Function(String action)? onAction}) {
    if (_inited || !Platform.isAndroid) return;
    _inited = true;

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'incomingUrl') {
        final url = call.arguments is String ? call.arguments as String : null;
        if (url != null && url.trim().isNotEmpty) onUrl(url.trim(), false);
      } else if (call.method == 'incomingProbe') {
        final url = call.arguments is String ? call.arguments as String : null;
        if (url != null && url.trim().isNotEmpty) onProbe?.call(url.trim());
      } else if (call.method == 'incomingAction') {
        final action = call.arguments is String ? call.arguments as String : null;
        if (action != null && action.isNotEmpty) onAction?.call(action);
      }
      return null;
    });

    _channel.invokeMethod<String>('getLaunchUrl').then((url) async {
      if (url != null && url.trim().isNotEmpty) {
        var withComments = false;
        try {
          withComments =
              await _channel.invokeMethod<bool>('getLaunchComments') ?? false;
        } catch (_) {}
        debugPrint('[launch] autostart: $url comments=$withComments');
        onUrl(url.trim(), withComments);
      }
    }).catchError((Object e) {
      debugPrint('[launch] getLaunchUrl failed: $e');
      return null;
    });

    _channel.invokeMethod<String>('getProbeUrl').then((url) {
      if (url != null && url.trim().isNotEmpty) {
        debugPrint('[launch] probe: $url');
        onProbe?.call(url.trim());
      }
    }).catchError((Object e) {
      debugPrint('[launch] getProbeUrl failed: $e');
      return null;
    });
  }
}
