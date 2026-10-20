import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'services/link_resolver.dart';
import 'services/local_server.dart';
import 'services/recording_manager.dart';
import 'services/storage_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await _ensurePermissions();

  final storage = StorageService();
  final manager = RecordingManager(
    resolver: LinkResolver(),
    storage: storage,
  );

  final server = LocalStreamServer(manager: manager);
  await server.start();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<RecordingManager>.value(value: manager),
        ChangeNotifierProvider<ThemeController>(create: (_) => ThemeController()),
        Provider<LocalStreamServer>.value(value: server),
        Provider<StorageService>.value(value: storage),
      ],
      child: const LiveRecorderApp(),
    ),
  );
}

/// Android 9 及以下需要写外部存储；10+ 无权限时回退到应用私有目录。
Future<void> _ensurePermissions() async {
  if (!Platform.isAndroid) return;
  try {
    final status = await Permission.storage.status;
    if (!status.isGranted) {
      await Permission.storage.request();
    }
    if (await Permission.manageExternalStorage.isDenied) {
      await Permission.manageExternalStorage.request();
    }
  } catch (_) {
    // 部分模拟器上权限插件会抛异常，忽略即可。
  }
}
