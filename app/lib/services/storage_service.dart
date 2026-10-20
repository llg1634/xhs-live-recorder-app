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

  /// 列出已有录像目录（用于"录像管理"）。
  Future<List<Directory>> listSessions() async {
    try {
      final base = await root();
      final entries = await base
          .list()
          .where((e) => e is Directory)
          .cast<Directory>()
          .toList();
      entries.sort((a, b) => b.path.compareTo(a.path));
      return entries;
    } catch (_) {
      return const [];
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
      files.sort((a, b) => a.path.compareTo(b.path));
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
