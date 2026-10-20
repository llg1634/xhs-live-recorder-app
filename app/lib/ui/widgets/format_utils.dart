/// 体积 / 速率 / 时长 / 时间 的显示格式化。
library;

/// 1024 进制体积：`0 B` / `824 KB` / `1.2 MB` / `13.4 GB`。
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const List<String> units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  if (unit == 0) return '${value.round()} B';
  final String text = value >= 100
      ? value.toStringAsFixed(0)
      : value >= 10
      ? value.toStringAsFixed(1)
      : value.toStringAsFixed(2);
  return '$text ${units[unit]}';
}

/// 实时下载速率：`0 B/s` / `1.4 MB/s`。
String formatRate(double bytesPerSecond) {
  if (bytesPerSecond <= 0) return '0 B/s';
  return '${formatBytes(bytesPerSecond.round())}/s';
}

/// 时长：`03:12` / `1:03:12`。超过 24 小时显示 `26:11:03`。
String formatDuration(Duration duration) {
  final int total = duration.inSeconds < 0 ? 0 : duration.inSeconds;
  final int h = total ~/ 3600;
  final int m = (total % 3600) ~/ 60;
  final int s = total % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  if (h > 0) return '$h:${two(m)}:${two(s)}';
  return '${two(m)}:${two(s)}';
}

/// 相对时间：`今天 14:03` / `昨天 09:12` / `10-19 22:41` / `2025-10-19 22:41`。
String formatClock(DateTime time, {DateTime? now}) {
  final DateTime current = now ?? DateTime.now();
  final DateTime day = DateTime(time.year, time.month, time.day);
  final DateTime today = DateTime(current.year, current.month, current.day);
  final int diff = today.difference(day).inDays;
  String two(int v) => v.toString().padLeft(2, '0');
  final String clock = '${two(time.hour)}:${two(time.minute)}';
  if (diff == 0) return '今天 $clock';
  if (diff == 1) return '昨天 $clock';
  if (time.year == current.year) {
    return '${two(time.month)}-${two(time.day)} $clock';
  }
  return '${time.year}-${two(time.month)}-${two(time.day)} $clock';
}

/// 完整时间：`2026-10-20 14:03`。
String formatDateTime(DateTime time) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}';
}

/// 房间号展示：过长时截断中间。
String shortRoomId(String roomId, {int max = 19}) {
  if (roomId.length <= max) return roomId;
  final int head = (max / 2).ceil();
  final int tail = max - head - 1;
  return '${roomId.substring(0, head)}…${roomId.substring(roomId.length - tail)}';
}

/// 目录名（`xhs_123_nick_20261020-190000`）解析时间戳。
DateTime? parseStampFromName(String name) {
  final RegExpMatch? match = RegExp(
    r'(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})$',
  ).firstMatch(name);
  if (match == null) return null;
  final int year = int.tryParse(match.group(1) ?? '') ?? 0;
  final int month = int.tryParse(match.group(2) ?? '') ?? 0;
  final int day = int.tryParse(match.group(3) ?? '') ?? 0;
  final int hour = int.tryParse(match.group(4) ?? '') ?? 0;
  final int minute = int.tryParse(match.group(5) ?? '') ?? 0;
  final int second = int.tryParse(match.group(6) ?? '') ?? 0;
  if (month == 0 || day == 0) return null;
  return DateTime(year, month, day, hour, minute, second);
}
