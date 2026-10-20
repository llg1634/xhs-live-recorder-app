import 'dart:io';

import '../widgets/format_utils.dart';

/// 一个分段文件。
class SessionSegment {
  const SessionSegment({required this.file, required this.bytes});

  final File file;
  final int bytes;
}

/// 一次录制（一个录像目录）。
///
/// 目录名由 [StorageService.createTaskDir] 生成：
/// `{platform}_{roomId}_{nickname}_{yyyyMMdd-HHmmss}`。
class SessionInfo {
  SessionInfo({
    required this.dir,
    required this.name,
    required this.platformKey,
    required this.roomId,
    required this.nickname,
    required this.parsedStartedAt,
    DateTime? fallbackStartedAt,
  }) : startedAt =
           parsedStartedAt ??
           fallbackStartedAt ??
           DateTime.fromMillisecondsSinceEpoch(0);

  final Directory dir;
  final String name;
  final String platformKey;
  final String roomId;
  final String nickname;
  final DateTime? parsedStartedAt;

  /// 解析不出目录名时间戳时，用目录 mtime 兜底。
  DateTime startedAt;

  List<SessionSegment>? segments;
  int? bytes;

  /// 弹幕条数（comments.jsonl 行数）。
  int comments = 0;

  bool get enriched => segments != null;

  String get platformLabel => switch (platformKey) {
    'xhs' => '小红书',
    'douyin' => '抖音',
    _ => '直播',
  };

  String get displayName {
    if (nickname.isNotEmpty) return nickname;
    if (roomId.isNotEmpty) return '房间 $roomId';
    return name;
  }

  int get segmentCount => segments?.length ?? 0;

  factory SessionInfo.fromDirectory(Directory dir) {
    final String name = dir.path.split(RegExp(r'[\\/]')).last;
    final DateTime? parsed = parseStampFromName(name);
    final String base = parsed == null
        ? name
        : name.replaceFirst(RegExp(r'_\d{8}-\d{6}$'), '');
    final List<String> parts = base.split('_');
    final String platformKey = parts.isNotEmpty ? parts.first : '';
    final String roomId = parts.length > 1 ? parts[1] : '';
    final String nickname = parts.length > 2
        ? parts.sublist(2).join(' ').replaceAll(RegExp(r'\s+'), ' ').trim()
        : '';
    return SessionInfo(
      dir: dir,
      name: name,
      platformKey: platformKey,
      roomId: roomId,
      nickname: nickname,
      parsedStartedAt: parsed,
    );
  }
}
