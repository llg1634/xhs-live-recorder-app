import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 外部拉起入口：`adb shell am start -n <pkg>/.MainActivity --es autostart "<链接>"`
/// 或从分享面板打开链接时，直接把链接交给录制管理器。
///
/// 注意：`main()` 在进程里只会跑一次（FlutterEngine 是进程级缓存的），
/// 所以 Activity 重建后原生侧补投的 intent 参数要靠 [checkPending] 在 resume 时再取一次。
class LaunchIntent {
  static const MethodChannel _channel =
      MethodChannel('live_recorder/foreground');

  static bool _inited = false;

  static void Function(String url, bool withComments)? _onUrl;
  static void Function(String url)? _onProbe;

  /// 原生侧先发的 `incomingComments`，等 `incomingUrl` 到了再一起用。
  static bool _pendingComments = false;

  static void init(void Function(String url, bool withComments) onUrl,
      {void Function(String url)? onProbe,
      void Function(String action)? onAction}) {
    _onUrl = onUrl;
    _onProbe = onProbe;
    if (_inited || !Platform.isAndroid) return;
    _inited = true;

    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'incomingUrl':
          final url = call.arguments is String ? call.arguments as String : null;
          if (url != null && url.trim().isNotEmpty) {
            _onUrl?.call(url.trim(), _pendingComments);
            _pendingComments = false;
          }
          break;
        case 'incomingComments':
          _pendingComments = call.arguments == true;
          break;
        case 'incomingProbe':
          final url = call.arguments is String ? call.arguments as String : null;
          if (url != null && url.trim().isNotEmpty) _onProbe?.call(url.trim());
          break;
        case 'incomingAction':
          final action =
              call.arguments is String ? call.arguments as String : null;
          if (action != null && action.isNotEmpty) onAction?.call(action);
          break;
      }
      return null;
    });

    _queryPendingLaunch();
    _channel.invokeMethod<String>('getProbeUrl').then((url) {
      if (url != null && url.trim().isNotEmpty) {
        debugPrint('[launch] probe: $url');
        _onProbe?.call(url.trim());
      }
    }).catchError((Object e) {
      debugPrint('[launch] getProbeUrl failed: $e');
      return null;
    });
  }

  /// App 回到前台时兜底取一次待处理链接（Activity 被重建时原生侧会把参数留着）。
  static void checkPending() {
    if (!Platform.isAndroid) return;
    _queryPendingLaunch();
  }

  static Future<void> _queryPendingLaunch() async {
    try {
      final String? url = await _channel.invokeMethod<String>('getLaunchUrl');
      if (url != null && url.trim().isNotEmpty) {
        var withComments = _pendingComments;
        _pendingComments = false;
        if (!withComments) {
          try {
            withComments =
                await _channel.invokeMethod<bool>('getLaunchComments') ?? false;
          } catch (_) {}
        }
        debugPrint('[launch] autostart: $url comments=$withComments');
        _onUrl?.call(url.trim(), withComments);
      }
    } catch (e) {
      debugPrint('[launch] getLaunchUrl failed: $e');
    }
  }
}
