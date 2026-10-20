import 'dart:io';

import '../../services/storage_service.dart';

/// 共享的"录像根目录解析"。
///
/// [StorageService.root] 在首次调用时会做一次真实写盘探测；如果多个页面同时
/// 首次调用（例如首页三页同时挂载），两次探测会争用同一个 `.write_test` 文件，
/// 导致其中一个失败。这里把首次解析合并成一个 Future，成功后再由
/// [StorageService] 自己的缓存兜底。
abstract final class StorageRootCache {
  static final Map<StorageService, Future<Directory>> _futures =
      Map<StorageService, Future<Directory>>.identity();

  /// 解析根目录；[retry] 为 true 时强制重新探测（设置页的"重新读取"）。
  static Future<Directory> resolve(
    StorageService storage, {
    bool retry = false,
  }) {
    final Future<Directory>? cached = _futures[storage];
    if (!retry && cached != null) return cached;

    final Future<Directory> future = storage.root();
    _futures[storage] = future;
    // 失败不缓存，允许用户点"重试"重新探测。
    future.then<void>(
      (Directory _) {},
      onError: (Object error, StackTrace stack) {
        if (identical(_futures[storage], future)) {
          _futures.remove(storage);
        }
      },
    );
    return future;
  }
}
