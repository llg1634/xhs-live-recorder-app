import 'dart:io';

import 'package:path/path.dart' as p;

/// 录像存储：默认写到公共目录 `/storage/emulated/0/Movies/直播录制`，
/// 不可写时回退到应用外部私有目录。
class StorageService {
  StorageService({this.preferredRoot = '/storage/emulated/0/Movies/直播录制'});

  final String preferredRoot;

  Directory? _resolved;
  Future<Directory>? _pending;

  /// 解析并创建录像根目录（并发调用共享同一次解析，避免写探针互相踩踏）。
  Future<Directory> root({String? fallbackRoot}) {
    final cached = _resolved;
    if (cached != null) return Future<Directory>.value(cached);

    final pending = _pending;
    if (pending != null) return pending;

    final future = _resolveRoot(fallbackRoot);
    _pending = future;
    return future.whenComplete(() {
      if (identical(_pending, future)) _pending = null;
    });
  }

  Future<Directory> _resolveRoot(String? fallbackRoot) async {
    final candidates = <String>[
      preferredRoot,
      ?fallbackRoot,
    ];

    for (final path in candidates) {
      try {
        final dir = Directory(path);
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        // 真正试写一次，避免只在根目录可读的机型上假成功。
        final probe = File(p.join(path, '.write_test'));
        await probe.writeAsString('ok', flush: true);
        await probe.delete();
        _resolved = dir;
        return dir;
      } catch (_) {
        continue;
      }
    }
    throw FileSystemException('没有可写的录像目录，已尝试：$candidates');
  }

  /// 为一次录制创建目录：`{platform}_{roomId}_{yyyyMMdd-HHmmss}`。
  Future<Directory> createTaskDir({
    required String platformKey,
    required String roomId,
    required DateTime startedAt,
    String? nickname,
  }) async {
    final base = await root();
    final stamp = _stamp(startedAt);
    final safeName = _sanitize(nickname ?? '');
    final folder = safeName.isEmpty
        ? '${platformKey}_${roomId}_$stamp'
        : '${platformKey}_${roomId}_${safeName}_$stamp';
    final dir = Directory(p.join(base.path, folder));
    await dir.create(recursive: true);
    return dir;
  }

  /// 列出已有录像目录（用于"录像管理"），按录制开始时间**倒序**（最新在前）。
  ///
  /// 注意：不能直接按 path 字符串排序——目录名以 `xhs_` / `douyin_` 开头，
  /// 字符串序会先按平台分组，导致"新的抖音"排在"旧的小红书"下面。
  Future<List<Directory>> listSessions() async {
    try {
      final base = await root();
      final entries = await base
          .list()
          .where((e) => e is Directory)
          .cast<Directory>()
          .toList();

      final times = <String, DateTime>{};
      for (final dir in entries) {
        final parsed = _parseStamp(p.basename(dir.path));
        if (parsed != null) {
          times[dir.path] = parsed;
        } else {
          try {
            times[dir.path] = (await dir.stat()).modified;
          } catch (_) {
            times[dir.path] = DateTime.fromMillisecondsSinceEpoch(0);
          }
        }
      }

      entries.sort((a, b) {
        final byTime = times[b.path]!.compareTo(times[a.path]!);
        if (byTime != 0) return byTime;
        return b.path.compareTo(a.path);
      });
      return entries;
    } catch (_) {
      return const [];
    }
  }

  /// 分段序号：`part01.flv` → 1；解析不出时退回文件名字符串。
  static int _segmentIndex(String path) {
    final m = RegExp(r'(\d+)\.flv$').firstMatch(p.basename(path));
    if (m == null) return 1 << 30;
    return int.tryParse(m.group(1)!) ?? (1 << 30);
  }

  /// 从目录名末尾解析 `yyyyMMdd-HHmmss` 时间戳。
  static DateTime? _parseStamp(String name) {
    final m = RegExp(r'(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})$')
        .firstMatch(name);
    if (m == null) return null;
    try {
      return DateTime(
        int.parse(m.group(1)!),
        int.parse(m.group(2)!),
        int.parse(m.group(3)!),
        int.parse(m.group(4)!),
        int.parse(m.group(5)!),
        int.parse(m.group(6)!),
      );
    } catch (_) {
      return null;
    }
  }

  /// 列出目录下的分段文件，按名称排序。
  Future<List<File>> listSegments(Directory dir) async {
    try {
      final files = await dir
          .list()
          .where((e) => e is File)
          .cast<File>()
          .where((f) => f.path.toLowerCase().endsWith('.flv'))
          .toList();
      // part2 要排在 part10 前面，所以按数字比较而不是字符串。
      files.sort((a, b) => _segmentIndex(a.path).compareTo(_segmentIndex(b.path)));
      return files;
    } catch (_) {
      return const [];
    }
  }

  Future<int> dirSize(Directory dir) async {
    var total = 0;
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }

  Future<void> deleteSession(Directory dir) async {
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  String _stamp(DateTime t) =>
      '${t.year}${_p(t.month)}${_p(t.day)}-${_p(t.hour)}${_p(t.minute)}${_p(t.second)}';

  String _p(int v) => v.toString().padLeft(2, '0');

  String _sanitize(String name) => name
      .replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .trim();
}
