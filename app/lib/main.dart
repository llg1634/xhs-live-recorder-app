import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'services/android_permissions.dart';
import 'services/comment_capture.dart';
import 'services/douyin_resolver.dart';
import 'services/foreground_service.dart';
import 'services/launch_intent.dart';
import 'services/link_resolver.dart';
import 'services/local_server.dart';
import 'services/recording_manager.dart';
import 'services/storage_service.dart';
import 'ui/debug/comment_probe_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _installFrameLogger();

  await _ensurePermissions();
  await ForegroundKeepAlive.init();

  final storage = StorageService();
  final douyin = DouyinResolver();
  final comments = CommentCaptureManager();
  final manager = RecordingManager(
    resolver: LinkResolver(),
    storage: storage,
    comments: comments,
    douyinUrlResolver: (room) => room.pageUrl.contains('/reflow/')
        ? douyin.resolveFromReflow(room.roomId)
        : douyin.resolveFlvUrl(room.roomId),
  );

  // 有任务在录 → 常驻前台服务，息屏不中断。
  manager.addListener(() {
    ForegroundKeepAlive.sync(activeCount: manager.activeCount);
  });

  final server = LocalStreamServer(manager: manager, port: 17346);
  await server.start();
  debugPrint('[server] local stream server: ${server.baseUrl}');

  // 支持通过 intent 额外参数 / 外部链接直接开录（自动化验收与分享入口）。
  LaunchIntent.init((url, withComments) {
    manager.startTask(url, withComments: withComments).then(
      (task) => debugPrint('[launch] task started: ${task.id}'),
      onError: (Object e) => debugPrint('[launch] startTask failed: $e'),
    );
  }, onProbe: (url) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      LiveRecorderApp.navigatorKey.currentState?.push(MaterialPageRoute<void>(
        builder: (_) => CommentProbePage(url: url),
      ));
    });
  }, onAction: (action) {
    debugPrint('[launch] action: $action');
    if (action == 'stopall') {
      manager.stopAll();
    }
  });

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<RecordingManager>.value(value: manager),
        ChangeNotifierProvider<CommentCaptureManager>.value(value: comments),
        ChangeNotifierProvider<ThemeController>(create: (_) => ThemeController()),
        Provider<LocalStreamServer>.value(value: server),
        Provider<StorageService>.value(value: storage),
      ],
      child: const LiveRecorderApp(),
    ),
  );
}

/// Android 9 及以下需要写外部存储；10+ 无权限时回退到应用私有目录。
Future<void> _ensurePermissions() async {  if (!Platform.isAndroid) return;
  try {
    if (await AndroidPermissions.isStorageReady()) return;
    await AndroidPermissions.requestStorage();
  } catch (_) {
    // 权限失败不阻塞启动：StorageService 会自动回退到可写目录。
  }
}

/// 帧耗时日志（仅调试）：超过 32ms 的帧打印一行，用于对比 UI 卡顿改动。
void _installFrameLogger() {
  if (!kDebugMode && !kProfileMode) return;
  var jank = 0;
  var frames = 0;
  SchedulerBinding.instance.addTimingsCallback((List<FrameTiming> timings) {
    for (final t in timings) {
      frames++;
      final totalMs = t.totalSpan.inMilliseconds;
      if (totalMs >= 32) {
        jank++;
        debugPrint('[frame] jank build=${t.buildDuration.inMilliseconds}ms '
            'raster=${t.rasterDuration.inMilliseconds}ms total=${totalMs}ms');
      }
    }
    if (frames % 120 == 0 && frames > 0) {
      debugPrint('[frame] summary frames=$frames jank=$jank');
    }
  });
}
