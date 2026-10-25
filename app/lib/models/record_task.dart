import 'live_room.dart';

/// 录制任务状态。
enum TaskState {
  resolving, // 解析链接中
  recording, // 正在录制
  reconnecting, // 断流，探测重连中
  completed, // 直播结束
  stopped, // 用户停止
  interrupted, // 进程被杀 / 应用被划掉，录制中断（可继续）
  error, // 出错
}

extension TaskStateX on TaskState {
  bool get isActive =>
      this == TaskState.resolving ||
      this == TaskState.recording ||
      this == TaskState.reconnecting;

  String get label => switch (this) {
        TaskState.resolving => '解析中',
        TaskState.recording => '录制中',
        TaskState.reconnecting => '重连探测中',
        TaskState.completed => '直播结束',
        TaskState.stopped => '已停止',
        TaskState.interrupted => '已中断',
        TaskState.error => '出错',
      };
}

/// 一个录制分段文件。
class RecordSegment {
  RecordSegment({
    required this.path,
    required this.index,
    required this.startedAt,
    this.bytes = 0,
    this.endedAt,
  });

  final String path;
  final int index;
  final DateTime startedAt;
  int bytes;
  DateTime? endedAt;

  Duration get duration =>
      (endedAt ?? DateTime.now()).difference(startedAt);

  bool get isComplete => endedAt != null;

  Map<String, dynamic> toJson() => {
        'path': path,
        'index': index,
        'startedAt': startedAt.toIso8601String(),
        'endedAt': endedAt?.toIso8601String(),
        'bytes': bytes,
      };

  static RecordSegment fromJson(Map<String, dynamic> json) => RecordSegment(
        path: '${json['path']}',
        index: (json['index'] as num?)?.toInt() ?? 0,
        startedAt:
            DateTime.tryParse('${json['startedAt']}') ?? DateTime.now(),
        endedAt: json['endedAt'] == null
            ? null
            : DateTime.tryParse('${json['endedAt']}'),
        bytes: (json['bytes'] as num?)?.toInt() ?? 0,
      );
}

/// 单个直播间的录制任务。
class RecordTask {
  RecordTask({required this.id, required this.rawInput, DateTime? createdAt})
      : createdAt = createdAt ?? DateTime.now();

  final String id;

  /// 用户输入的原始链接/分享文案。
  final String rawInput;

  final DateTime createdAt;

  LiveRoom? room;
  TaskState state = TaskState.resolving;
  String? errorMessage;

  /// 输出目录（绝对路径）。
  String? outputDir;

  /// 已写入字节数。
  int totalBytes = 0;

  /// 断流重连次数。
  int retryCount = 0;

  /// 探测失败次数（用于"直播结束"判定）。
  int probeFailCount = 0;

  /// 最近的下载速率（字节/秒）。
  double bytesPerSecond = 0;

  /// 当前分段。
  RecordSegment? currentSegment;

  final List<RecordSegment> segments = [];

  DateTime? startedAt;
  DateTime? endedAt;

  /// 弹幕数量。
  int commentCount = 0;

  /// 是否同时采集弹幕（仅小红书，默认关；用户按任务手动开启）。
  bool commentsEnabled = false;

  /// 最近一条弹幕时间。
  DateTime? lastCommentAt;

  /// session.json 的落盘时间（用于恢复时过滤太旧的任务）。
  DateTime? savedAt;

  String get title => room?.displayName ?? '解析中…';

  String get platformLabel => room?.platform.label ?? '—';

  Duration get elapsed =>
      (endedAt ?? DateTime.now()).difference(startedAt ?? createdAt);

  int get segmentCount => segments.length;

  bool get isActive => state.isActive;

  Map<String, dynamic> toJson() => {
        'id': id,
        'rawInput': rawInput,
        'createdAt': createdAt.toIso8601String(),
        'room': room?.toJson(),
        'state': state.name,
        'errorMessage': errorMessage,
        'outputDir': outputDir,
        'totalBytes': totalBytes,
        'retryCount': retryCount,
        'startedAt': startedAt?.toIso8601String(),
        'endedAt': endedAt?.toIso8601String(),
        'segments': segments.map((s) => s.toJson()).toList(),
        'commentCount': commentCount,
        'commentsEnabled': commentsEnabled,
        'lastCommentAt': lastCommentAt?.toIso8601String(),
      };

  /// 从 `session.json` 恢复任务（用于进程被杀后的补偿）。
  static RecordTask fromJson(Map<String, dynamic> json) {
    final task = RecordTask(
      id: '${json['id']}',
      rawInput: '${json['rawInput'] ?? ''}',
      createdAt: DateTime.tryParse('${json['createdAt']}') ?? DateTime.now(),
    );
    final room = json['room'];
    if (room is Map<String, dynamic>) {
      try {
        task.room = LiveRoom.fromJson(room);
      } catch (_) {}
    }
    final stateName = json['state']?.toString();
    task.state = TaskState.values.firstWhere(
      (s) => s.name == stateName,
      orElse: () => TaskState.interrupted,
    );
    task.errorMessage = json['errorMessage']?.toString();
    task.outputDir = json['outputDir']?.toString();
    task.totalBytes = (json['totalBytes'] as num?)?.toInt() ?? 0;
    task.retryCount = (json['retryCount'] as num?)?.toInt() ?? 0;
    task.startedAt = DateTime.tryParse('${json['startedAt']}');
    task.endedAt = DateTime.tryParse('${json['endedAt']}');
    task.commentCount = (json['commentCount'] as num?)?.toInt() ?? 0;
    task.commentsEnabled = json['commentsEnabled'] == true;
    task.lastCommentAt = DateTime.tryParse('${json['lastCommentAt']}');
    task.savedAt = DateTime.tryParse('${json['savedAt']}');
    final segments = json['segments'];
    if (segments is List) {
      for (final item in segments) {
        if (item is Map<String, dynamic>) {
          task.segments.add(RecordSegment.fromJson(item));
        }
      }
    }
    return task;
  }
}
