import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/live_room.dart';
import '../models/record_task.dart';
import 'comment_capture.dart';
import 'flv_recorder.dart';
import 'link_resolver.dart';
import 'storage_service.dart';

/// 多直播间录制调度中心。
class RecordingManager extends ChangeNotifier {
  RecordingManager({
    required this.resolver,
    required this.storage,
    this.comments,
    this.douyinUrlResolver,
    this.maxConcurrentTasks = 6,
  });

  final LinkResolver resolver;
  final StorageService storage;

  /// 弹幕采集（可选）：任务开启时同时采集小红书评论。
  final CommentCaptureManager? comments;

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
  ///
  /// [withComments] 为 true 时同时采集弹幕（仅小红书支持）。
  Future<RecordTask> startTask(String rawInput, {bool withComments = false}) async {
    if (activeCount >= maxConcurrentTasks) {
      throw StateError('同时录制数已达上限（$maxConcurrentTasks）');
    }
    final task = RecordTask(id: _uuid.v4(), rawInput: rawInput);
    task.commentsEnabled = withComments;
    _tasks[task.id] = task;
    notifyListeners();
    unawaited(_runTask(task));
    return task;
  }

  Future<void> _runTask(RecordTask task) async {
    try {
      task.state = TaskState.resolving;
      notifyListeners();
      debugPrint('[task ${task.id}] resolving: ${task.rawInput}');

      final room = await resolver.resolve(task.rawInput);
      task.room = room;
      debugPrint('[task ${task.id}] resolved: ${room.platform.key}/${room.roomId} '
          'title=${room.title} anchor=${room.anchorName}');

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
      debugPrint('[task ${task.id}] outputDir=${dir.path}');

      // 弹幕采集：小红书走文本帧，抖音走 protobuf 二进制帧（见 docs/comments.md）。
      final capture = comments;
      if (task.commentsEnabled && capture != null) {
        // 抖音：有 web_rid 就直接用直播间页；短链只有内部 room_id 时用
        // reflow 页（页面自己会跳到 live.douyin.com/<web_rid>，弹幕照常）。
        final commentUrl = room.platform == LivePlatform.douyin
            ? (room.webRid != null
                ? 'https://live.douyin.com/${room.webRid}'
                : room.pageUrl)
            : room.pageUrl;
        debugPrint('[task ${task.id}] comment capture on: $commentUrl');
        unawaited(capture
            .startForTask(
              taskId: task.id,
              platform: room.platform,
              roomUrl: commentUrl,
              outputDir: dir.path,
              startEpochMs:
                  (task.startedAt ?? DateTime.now()).millisecondsSinceEpoch,
              onComment: (comment) {
                task.commentCount++;
                task.lastCommentAt = comment.time;
                notifyListeners();
              },
            )
            .catchError((Object e) {
          debugPrint('[task ${task.id}] comment capture failed: $e');
          task.commentCount = -1; // 负值表示采集失败，UI 显示异常
          notifyListeners();
        }));
      }

      Future<String> urlProvider() async {
        if (room.platform == LivePlatform.xhs) return room.flvUrl;
        return await douyinUrlResolver!(room);
      }

      late final FlvRecorder recorder;
      recorder = FlvRecorder(
        room: room,
        outputDir: dir,
        urlProvider: urlProvider,
        referer: room.platform == LivePlatform.xhs
            ? 'https://www.xiaohongshu.com/'
            : 'https://live.douyin.com/',
        onState: (state) {
          if (!task.isActive && state == TaskState.recording) return;
          task.state = state;
          debugPrint('[task ${task.id}] state=${state.name}');
          notifyListeners();
        },
        onSegment: (segment, finished) {
          if (finished) {
            task.currentSegment = null;
            debugPrint('[task ${task.id}] segment done: ${segment.path} '
                '${segment.bytes}B');
          } else {
            task.currentSegment = segment;
            task.segments.add(segment);
            debugPrint('[task ${task.id}] segment start: ${segment.path}');
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
      debugPrint('[task ${task.id}] ERROR: ${task.errorMessage}');
    } finally {
      _recorders.remove(task.id);
      unawaited(comments?.stopForTask(task.id));
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
