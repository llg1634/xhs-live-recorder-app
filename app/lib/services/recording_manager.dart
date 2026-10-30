import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/live_room.dart';
import '../models/quality.dart';
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
  final Future<String> Function(LiveRoom room, RecordQuality quality)?
      douyinUrlResolver;

  /// 当前画质偏好（由设置页同步）。
  RecordQuality recordQuality = RecordQuality.highest;

  final int maxConcurrentTasks;

  /// 任务状态落盘，用于进程被杀后恢复。
  final SessionStore sessions;

  final Map<String, RecordTask> _tasks = {};
  final Map<String, FlvRecorder> _recorders = {};
  final Uuid _uuid = const Uuid();

  /// 本进程 pid：用来区分「session.json 是不是本进程里另一个实例写的」。
  static final int _pid = pid;

  Timer? _heartbeat;
  bool _restored = false;
  bool _disposed = false;

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
  /// 规则：
  /// 1. **磁盘是唯一事实来源**：分段列表按目录里真实的 `partNN.flv` 重建，
  ///    不依赖 session.json 里可能落后的 `segments`/`totalBytes`；
  /// 2. 之前处于录制中的任务标记为 [TaskState.interrupted]：文件已经落盘不会丢，
  ///    用户可以点「继续录制」从下一个分段接着录；
  /// 3. 如果 session.json 显示这条任务**正被本进程的另一个实例写**（老版本 Activity
  ///    重建后会出现两个 Dart isolate），不要抢状态、也不要用 interrupted 覆盖它。
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
        final String? dirPath = task.outputDir;
        if (dirPath != null && dirPath.isNotEmpty) {
          await _syncSegmentsWithDisk(task, Directory(dirPath));
        }
        if (task.isActive) {
          if (_hasLiveOwner(task)) {
            // 另一个 isolate 仍在写这场录制：跟随它的心跳，不覆盖 session.json。
            task.externalOwner = true;
            task.state = TaskState.recording;
            task.errorMessage = null;
            debugPrint('[restore] ${task.id} owned by live instance, attach as external');
          } else {
            // 超过 24 小时的中断任务不再放回录制页（文件仍在录像页里）。
            final DateTime? saved = task.savedAt;
            if (saved != null &&
                saved.isBefore(DateTime.now().subtract(const Duration(hours: 24)))) {
              continue;
            }
            // 上次进程没来得及收尾：标记中断，文件保留，可继续录制。
            task.state = TaskState.interrupted;
            task.currentSegment = null;
            task.endedAt ??= DateTime.now();
            task.errorMessage ??= '录制已停止（应用界面重建），已录内容已保留，可继续录制';
          }
        } else if (task.savedAt != null && task.savedAt!.isBefore(cutoff)) {
          // 太旧的正常结束任务不再塞进录制页，录像页里仍能看到文件。
          continue;
        }
        _tasks[task.id] = task;
        changed = true;
        // 只有被我们"改判"为中断的任务才回写 session.json；已完成/已停止的任务
        // 保持原 savedAt，避免每次启动都把它们的保活时间刷新一遍。
        if (task.state == TaskState.interrupted) _persistTask(task);
      }
      _startHeartbeat();
      if (changed) {
        debugPrint('[restore] recovered ${restored.length} tasks');
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[restore] failed: $e');
    }
  }

  /// session.json 显示「同进程的另一个实例刚刚还在写」→ 这场录制仍然活着。
  bool _hasLiveOwner(RecordTask task) {
    final DateTime? savedAt = task.savedAt;
    if (savedAt == null) return false;
    if (task.ownerPid != _pid) return false;
    return DateTime.now().difference(savedAt) < const Duration(seconds: 8);
  }

  /// 用磁盘上的真实分段校正任务：session.json 可能落后 2 秒，甚至整段丢失。
  Future<void> _syncSegmentsWithDisk(RecordTask task, Directory dir) async {
    try {
      if (!await dir.exists()) return;
      final List<File> files = await storage.listSegments(dir);
      if (files.isEmpty) return;
      final Map<String, RecordSegment> known = <String, RecordSegment>{
        for (final RecordSegment s in task.segments) s.path: s,
      };
      final List<RecordSegment> merged = <RecordSegment>[];
      var total = 0;
      for (final File file in files) {
        final int bytes = await file.length();
        total += bytes;
        final RecordSegment? existing = known.remove(file.path);
        if (existing != null) {
          existing.bytes = bytes;
          merged.add(existing);
        } else {
          merged.add(RecordSegment(
            path: file.path,
            index: FlvRecorder.segmentIndexFromPath(file.path) ??
                merged.length + 1,
            startedAt: await file.lastModified(),
            bytes: bytes,
          ));
        }
      }
      task.segments
        ..clear()
        ..addAll(merged);
      task.totalBytes = total;
      if (task.isActive) {
        task.currentSegment = merged.isEmpty ? null : merged.last;
      }
    } catch (e) {
      debugPrint('[restore] scan ${dir.path} failed: $e');
    }
  }

  /// 周期性把进行中的任务写到 `<录像目录>/session.json`，同时兜底检查"僵尸任务"。
  void _startHeartbeat() {
    _heartbeat ??= Timer.periodic(const Duration(seconds: 2), (_) {
      _heartbeatTick();
    });
  }

  void _heartbeatTick() {
    if (_disposed) return;
    final DateTime now = DateTime.now();
    for (final RecordTask task in _tasks.values.toList()) {
      if (task.outputDir == null) continue;
      if (task.externalOwner) {
        unawaited(_checkExternalOwner(task, now));
        continue;
      }
      if (!task.isActive) continue;

      final FlvRecorder? recorder = _recorders[task.id];
      if (recorder == null) {
        // 已经过了启动阶段却仍然没有 recorder：录制链路实际已经断了，
        // 不能继续显示"录制中"骗人。
        final DateTime? startedAt = task.startedAt;
        if (startedAt != null &&
            now.difference(startedAt) > const Duration(seconds: 20)) {
          _markInterrupted(task, '录制器已退出，已录内容已保留，可继续录制');
        }
        continue;
      }
      unawaited(sessions.save(task));
    }
  }

  /// 外部实例（同进程另一个 isolate）是否还活着：看它写 session.json 的间隔。
  Future<void> _checkExternalOwner(RecordTask task, DateTime now) async {
    final String? dir = task.outputDir;
    if (dir == null) return;
    try {
      final File file = File(p.join(dir, SessionStore.fileName));
      if (!await file.exists()) return;
      final DateTime modified = (await file.stat()).modified;
      if (now.difference(modified) < const Duration(seconds: 20)) return;
    } catch (_) {
      return;
    }
    task.externalOwner = false;
    _markInterrupted(task, '后台录制实例已退出，已录内容已保留，可继续录制');
  }

  void _markInterrupted(RecordTask task, String message) {
    if (!task.isActive && !task.externalOwner) return;
    task.externalOwner = false;
    task.state = TaskState.interrupted;
    task.endedAt ??= DateTime.now();
    task.errorMessage = message;
    task.currentSegment = null;
    _persistTask(task);
    if (!_disposed) notifyListeners();
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
    task.externalOwner = false;
    task.retryCount = 0;
    task.probeFailCount = 0;

    // 重新扫描已有分段，保证接着 part0N 继续写，不覆盖旧文件。
    task.segments.clear();
    final List<File> files = await storage.listSegments(dir);
    var total = 0;
    for (final File f in files) {
      final int bytes = await f.length();
      total += bytes;
      task.segments.add(RecordSegment(
        path: f.path,
        index: FlvRecorder.segmentIndexFromPath(f.path) ?? task.segments.length + 1,
        startedAt: await f.lastModified(),
        bytes: bytes,
      ));
    }
    // 以磁盘为准重算总字节：session.json 里的值可能落后于实际写入。
    task.totalBytes = total;
    task.startedAt ??= task.createdAt;
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
                if (!_disposed) notifyListeners();
              },
            )
            .catchError((Object e) {
          debugPrint('[task ${task.id}] comment capture failed: $e');
          task.commentCount = -1; // 负值表示采集失败，UI 显示异常
          if (!_disposed) notifyListeners();
        }));
      }

      Future<String> urlProvider() async {
        final RecordQuality quality = recordQuality;
        if (room.platform == LivePlatform.xhs) {
          return _xhsUrl(room, quality);
        }
        return await douyinUrlResolver!(room, quality);
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
          if (!_disposed) notifyListeners();
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
          if (!_disposed) notifyListeners();
        },
        onProgress: (bytes, bps) {
          task.totalBytes = bytes;
          task.bytesPerSecond = bps;
          task.retryCount = recorder.retryCount;
          if (!_disposed) notifyListeners();
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
      final FlvRecorder? finished = _recorders.remove(task.id);
      unawaited(comments?.stopForTask(task.id));
      task.currentSegment = null;
      if (finished != null) {
        task.totalBytes = finished.totalBytes;
        task.retryCount = finished.retryCount;
      }
      if (task.state == TaskState.completed) {
        task.endedAt ??= DateTime.now();
      } else if (task.isActive) {
        // 录制循环结束但没有给出终态（异常/被系统打断）：
        // 绝不能留下"界面显示录制中、实际已经不在写盘"的僵尸任务。
        task.state = TaskState.interrupted;
        task.endedAt ??= DateTime.now();
        task.errorMessage ??= '录制器意外退出，已录内容已保留，可继续录制';
      }
      _persistTask(task);
      if (!_disposed) notifyListeners();
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

  /// 小红书直链：默认画质用 `_hcv5401`（540P），该档位不存在时回退无后缀（1080P）。
  Future<String> _xhsUrl(LiveRoom room, RecordQuality quality) async {
    if (quality == RecordQuality.highest) return room.flvUrl;
    final String standard = room.flvUrlFor(RecordQuality.standard);
    if (await _urlAlive(standard)) return standard;
    debugPrint('[task] ${room.roomId} 没有 540P 档位，回退默认直链');
    return room.flvUrl;
  }

  Future<bool> _urlAlive(String url) async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6);
    try {
      final HttpClientRequest request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, FlvRecorder.defaultUserAgent);
      request.headers.set(HttpHeaders.refererHeader, 'https://www.xiaohongshu.com/');
      final HttpClientResponse response = await request.close();
      await response.drain<void>().catchError((_) {});
      return response.statusCode == HttpStatus.ok;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> stopTask(String id) async {
    final task = _tasks[id];
    if (task == null || !task.isActive) return;
    task.state = TaskState.stopped;
    task.endedAt = DateTime.now();
    task.currentSegment = null;
    task.externalOwner = false;
    notifyListeners();
    final recorder = _recorders[id];
    if (recorder != null) {
      await recorder.stop();
    }
    _persistTask(task);
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

  /// 这个任务是否真的由本 isolate 的录制器在写盘（预览页据此决定放直播还是放录像）。
  bool isRecordingHere(String id) => _recorders.containsKey(id);

  /// 回到前台时自检：显示"录制中"的任务必须真的还有 recorder。
  ///
  /// 这里只做"发现问题 → 安全收尾"，绝不重启/续录（续录必须用户确认，且要沿用原目录）。
  Future<void> onAppResumed() async {
    final DateTime now = DateTime.now();
    for (final RecordTask task in _tasks.values.toList()) {
      if (task.externalOwner || !task.isActive) continue;
      if (_recorders.containsKey(task.id)) continue;
      final DateTime? startedAt = task.startedAt;
      if (startedAt == null ||
          now.difference(startedAt) < const Duration(seconds: 15)) {
        continue;
      }
      _markInterrupted(task, '回到前台时发现录制器已退出，已录内容已保留，可继续录制');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _heartbeat?.cancel();
    _heartbeat = null;
    for (final r in _recorders.values) {
      unawaited(r.stop());
    }
    _recorders.clear();
    super.dispose();
  }
}
