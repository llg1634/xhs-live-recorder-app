import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/live_room.dart';
import '../models/record_task.dart';
import 'comment_capture.dart';
import 'flv_recorder.dart';
import 'link_resolver.dart';
import 'session_store.dart';
import 'storage_service.dart';

/// 多直播间录制调度中心。
class RecordingManager extends ChangeNotifier {
  RecordingManager({
    required this.resolver,
    required this.storage,
    this.comments,
    this.douyinUrlResolver,
    this.maxConcurrentTasks = 6,
    this.sessions = const SessionStore(),
  });

  final LinkResolver resolver;
  final StorageService storage;

  /// 弹幕采集（可选）：任务开启时同时采集小红书评论。
  final CommentCaptureManager? comments;

  /// 抖音需要运行时解析带签名的 FLV 地址；为空时抖音任务会提示未支持。
  final Future<String> Function(LiveRoom room)? douyinUrlResolver;

  final int maxConcurrentTasks;

  /// 任务状态落盘，用于进程被杀后恢复。
  final SessionStore sessions;

  final Map<String, RecordTask> _tasks = {};
  final Map<String, FlvRecorder> _recorders = {};
  final Uuid _uuid = const Uuid();

  Timer? _heartbeat;
  bool _restored = false;

  List<RecordTask> get tasks {
    final list = _tasks.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  RecordTask? taskById(String id) => _tasks[id];

  FlvRecorder? recorderFor(String id) => _recorders[id];

  int get activeCount => _tasks.values.where((t) => t.isActive).length;

  /// 启动时恢复上次的任务列表（进程被杀 / 应用被划掉后重新打开）。
  ///
  /// 之前处于录制中的任务会被标记为 [TaskState.interrupted]：文件已经落盘不会丢，
  /// 用户可以点「继续录制」从下一个分段接着录。
  Future<void> restore() async {
    if (_restored) return;
    _restored = true;
    try {
      final List<Directory> dirs = await storage.listSessions();
      final List<RecordTask> restored = await sessions.loadAll(dirs);
      final DateTime cutoff = DateTime.now().subtract(const Duration(hours: 12));
      var changed = false;
      for (final RecordTask task in restored) {
        if (_tasks.containsKey(task.id)) continue;
        if (task.isActive) {
          // 上次进程没来得及收尾：标记中断，文件保留，可继续录制。
          task.state = TaskState.interrupted;
          task.endedAt ??= DateTime.now();
          task.errorMessage ??= '应用被关闭，录制中断（文件已保留）';
        } else if (task.savedAt != null && task.savedAt!.isBefore(cutoff)) {
          // 太旧的正常结束任务不再塞进录制页，录像页里仍能看到文件。
          continue;
        }
        _tasks[task.id] = task;
        changed = true;
      }
      if (changed) {
        debugPrint('[restore] recovered ${restored.length} tasks');
        for (final t in restored) {
          _persistTask(t);
        }
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[restore] failed: $e');
    }
  }

  /// 周期性把进行中的任务写到 `<录像目录>/session.json`。
  void _startHeartbeat() {
    _heartbeat ??= Timer.periodic(const Duration(seconds: 2), (_) {
      for (final RecordTask task in _tasks.values) {
        if (task.isActive && task.outputDir != null) {
          unawaited(sessions.save(task));
        }
      }
    });
  }

  void _persistTask(RecordTask task) {
    if (task.outputDir == null) return;
    unawaited(sessions.save(task));
  }

  /// 继续一个被中断的任务：复用原目录，分段号接着往后排。
  Future<RecordTask> resumeTask(String id) async {
    final RecordTask? task = _tasks[id];
    if (task == null) throw StateError('任务不存在');
    if (task.state != TaskState.interrupted) {
      throw StateError('只有已中断的任务可以继续');
    }
    final String? dirPath = task.outputDir;
    if (dirPath == null) throw StateError('缺少录像目录');
    final Directory dir = Directory(dirPath);
    if (!await dir.exists()) throw StateError('录像目录已不存在');

    task.state = TaskState.resolving;
    task.errorMessage = null;
    task.endedAt = null;
    task.currentSegment = null;

    // 重新扫描已有分段，保证接着 part0N 继续写，不覆盖旧文件。
    task.segments.clear();
    final List<File> files = await storage.listSegments(dir);
    for (final File f in files) {
      final int index =
          int.tryParse(RegExp(r'(\d+)\.flv$').firstMatch(f.path)?.group(1) ?? '') ?? 0;
      task.segments.add(RecordSegment(
        path: f.path,
        index: index,
        startedAt: DateTime.now(),
        bytes: await f.length(),
      ));
    }
    notifyListeners();
    unawaited(_runTask(task, resume: true));
    return task;
  }

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

  Future<void> _runTask(RecordTask task, {bool resume = false}) async {
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

      final Directory dir;
      if (resume) {
        dir = Directory(task.outputDir!);
        debugPrint('[task ${task.id}] resume in ${dir.path} '
            'existing=${task.segments.length}');
      } else {
        dir = await storage.createTaskDir(
          platformKey: room.platform.key,
          roomId: room.roomId,
          startedAt: task.createdAt,
          nickname: room.anchorName ?? room.title,
        );
        task.outputDir = dir.path;
        task.startedAt = DateTime.now();
      }
      debugPrint('[task ${task.id}] outputDir=${dir.path}');
      _startHeartbeat();
      _persistTask(task);

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
          _persistTask(task);
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
          _persistTask(task);
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
      if (resume) {
        // 接着已有分段编号继续；累计字节也带上，UI 不会显示成从 0 开始。
        recorder.segments.addAll(task.segments);
        recorder.totalBytes = task.totalBytes;
      }
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
      task.totalBytes = _recorders[task.id]?.totalBytes ?? task.totalBytes;
      _persistTask(task);
      notifyListeners();
    }
  }

  /// 继续所有已中断的任务（用于一键恢复）。
  Future<void> resumeAllInterrupted() async {
    final List<RecordTask> pending = _tasks.values
        .where((RecordTask t) => t.state == TaskState.interrupted)
        .toList();
    for (final RecordTask t in pending) {
      try {
        await resumeTask(t.id);
      } catch (e) {
        debugPrint('[resume] ${t.id} failed: $e');
      }
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
