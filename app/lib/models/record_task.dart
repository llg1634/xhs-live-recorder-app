import 'live_room.dart';

/// 录制任务状态。
enum TaskState {
  resolving, // 解析链接中
  recording, // 正在录制
  reconnecting, // 断流，探测重连中
  completed, // 直播结束
  stopped, // 用户停止
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

  /// 弹幕数量（本版本仅预留，恒为 0）。
  int commentCount = 0;

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
      };
}
