import 'dart:io';

import 'package:flutter/services.dart';

/// 存储权限（原生实现，避免 permission_handler 的旧 AGP buildscript 依赖）。
class AndroidPermissions {
  static const MethodChannel _channel = MethodChannel('live_recorder/foreground');

  /// 申请写公共 Movies 目录的权限（Android 11+ 跳系统设置页）。
  static Future<void> requestStorage() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('requestStoragePermission');
    } catch (_) {}
  }

  /// 当前是否已具备写公共目录的权限。
  static Future<bool> isStorageReady() async {
    if (!Platform.isAndroid) return true;
    try {
      final result = await _channel.invokeMethod<bool>('isStorageReady');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 跳到系统通知设置页。
  static Future<void> openNotificationSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('openNotificationSettings');
    } catch (_) {}
  }
}
