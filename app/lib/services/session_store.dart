import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/record_task.dart';

/// 把任务状态落盘到录像目录下的 `session.json`。
///
/// 目的：**应用被划掉 / 进程被系统杀掉**时，已录制的文件不会丢（本来就在写盘），
/// 同时还能知道"这一场原本录到哪、是什么状态"，下次启动可以恢复任务列表并继续录制。
class SessionStore {
  const SessionStore();

  static const String fileName = 'session.json';

  /// 原子写入：先写 `.tmp` 再 rename，避免掉电/被杀时留下半个 JSON。
  Future<void> save(RecordTask task) async {
    final dir = task.outputDir;
    if (dir == null) return;
    try {
      final file = File(p.join(dir, fileName));
      final tmp = File('${file.path}.tmp');
      final payload = <String, dynamic>{
        ...task.toJson(),
        'savedAt': DateTime.now().toIso8601String(),
        'app': 'live_recorder',
        'version': 1,
      };
      await tmp.writeAsString(jsonEncode(payload), flush: true);
      await tmp.rename(file.path);
    } catch (e) {
      debugPrint('[session] save failed: $e');
    }
  }

  /// 读取某个目录里的会话状态；没有或损坏时返回 null。
  Future<RecordTask?> load(Directory dir) async {
    try {
      final file = File(p.join(dir.path, fileName));
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return null;
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return null;
      final task = RecordTask.fromJson(json);
      task.outputDir ??= dir.path;
      return task;
    } catch (e) {
      debugPrint('[session] load failed ${dir.path}: $e');
      return null;
    }
  }

  /// 扫描所有录像目录，返回能恢复的任务。
  Future<List<RecordTask>> loadAll(List<Directory> dirs) async {
    final tasks = <RecordTask>[];
    for (final dir in dirs) {
      final task = await load(dir);
      if (task != null) tasks.add(task);
    }
    return tasks;
  }
}
