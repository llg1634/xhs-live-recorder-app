import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/live_room.dart';
import '../models/record_task.dart';
import 'flv_recorder.dart';
import 'link_resolver.dart';
import 'storage_service.dart';

/// 多直播间录制调度中心。
class RecordingManager extends ChangeNotifier {
  RecordingManager({
    required this.resolver,
    required this.storage,
    this.douyinUrlResolver,
    this.maxConcurrentTasks = 6,
  });

  final LinkResolver resolver;
  final StorageService storage;

  /// 抖音需要运行时解析带签名的 FLV 地址；为空时抖音任务会提示未支持。
  final Future<String> Function(LiveRoom room)? douyinUrlResolver;

  final int maxConcurrentTasks;

  final Map<String, RecordTask> _tasks = {};
  final Map<String, FlvRecorder> _recorders = {};
  final Uuid _uuid = const Uuid();

  List<RecordTask> get tasks {
    final list = _tasks.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  RecordTask? taskById(String id) => _tasks[id];

  FlvRecorder? recorderFor(String id) => _recorders[id];

  int get activeCount => _tasks.values.where((t) => t.isActive).length;

  /// 新建录制任务（不会阻塞 UI，立即返回任务对象）。
  Future<RecordTask> startTask(String rawInput) async {
    if (activeCount >= maxConcurrentTasks) {
      throw StateError('同时录制数已达上限（$maxConcurrentTasks）');
    }
    final task = RecordTask(id: _uuid.v4(), rawInput: rawInput);
    _tasks[task.id] = task;
    notifyListeners();
    unawaited(_runTask(task));
    return task;
  }

  Future<void> _runTask(RecordTask task) async {
    try {
      task.state = TaskState.resolving;
      notifyListeners();

      final room = await resolver.resolve(task.rawInput);
      task.room = room;

      if (room.platform == LivePlatform.douyin && douyinUrlResolver == null) {
        throw LinkResolveException('抖音录制将在下一版本支持');
      }

      final dir = await storage.createTaskDir(
        platformKey: room.platform.key,
        roomId: room.roomId,
        startedAt: task.createdAt,
        nickname: room.anchorName ?? room.title,
      );
      task.outputDir = dir.path;
      task.startedAt = DateTime.now();

      Future<String> urlProvider() async {
        if (room.platform == LivePlatform.xhs) return room.flvUrl;
        return await douyinUrlResolver!(room);
      }

      late final FlvRecorder recorder;
      recorder = FlvRecorder(
        room: room,
        outputDir: dir,
        urlProvider: urlProvider,
        onState: (state) {
          if (!task.isActive && state == TaskState.recording) return;
          task.state = state;
          notifyListeners();
        },
        onSegment: (segment, finished) {
          if (finished) {
            task.currentSegment = null;
          } else {
            task.currentSegment = segment;
            task.segments.add(segment);
          }
          task.totalBytes = recorder.totalBytes;
          notifyListeners();
        },
        onProgress: (bytes, bps) {
          task.totalBytes = bytes;
          task.bytesPerSecond = bps;
          task.retryCount = recorder.retryCount;
          notifyListeners();
        },
      );
      _recorders[task.id] = recorder;
      notifyListeners();

      await recorder.run();
    } catch (e) {
      task.state = TaskState.error;
      task.errorMessage = e.toString().replaceFirst('LinkResolveException: ', '');
      task.endedAt = DateTime.now();
    } finally {
      _recorders.remove(task.id);
      if (task.state == TaskState.completed) {
        task.endedAt ??= DateTime.now();
      }
      notifyListeners();
    }
  }

  Future<void> stopTask(String id) async {
    final task = _tasks[id];
    if (task == null || !task.isActive) return;
    task.state = TaskState.stopped;
    task.endedAt = DateTime.now();
    notifyListeners();
    final recorder = _recorders[id];
    if (recorder != null) {
      await recorder.stop();
    }
  }

  Future<void> stopAll() async {
    for (final t in _tasks.values.where((t) => t.isActive).toList()) {
      await stopTask(t.id);
    }
  }

  void removeTask(String id) {
    final task = _tasks[id];
    if (task == null || task.isActive) return;
    _tasks.remove(id);
    notifyListeners();
  }

  @override
  void dispose() {
    for (final r in _recorders.values) {
      unawaited(r.stop());
    }
    _recorders.clear();
    super.dispose();
  }
}
