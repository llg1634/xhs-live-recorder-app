import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../models/live_room.dart';
import '../models/record_task.dart';

/// 单直播间 FLV 录制引擎。
///
/// 核心策略（已实测验证）：
/// - 小红书 FLV 直链无签名、无 Cookie 依赖，`房间号` 即可直连；
/// - 断流后**同一条 URL 重新连接**即可从当前直播点继续，不需要刷新页面；
/// - 断流后按 5 秒间隔探测 3 次，成功则开新分段继续录，全失败才判定直播结束；
/// - 每个分段是独立可播放的 FLV（含文件头），不做事后合并。
class FlvRecorder {
  FlvRecorder({
    required this.room,
    required this.outputDir,
    required this.urlProvider,
    this.userAgent = defaultUserAgent,
    this.referer = 'https://www.xiaohongshu.com/',
    this.idleTimeout = const Duration(seconds: 25),
    this.probeInterval = const Duration(seconds: 5),
    this.probeAttempts = 3,
    this.onState,
    this.onSegment,
    this.onProgress,
  });

  static const defaultUserAgent =
      'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

  final LiveRoom room;
  final Directory outputDir;

  /// 每次新建连接前调用，便于抖音这类带时效签名的平台刷新地址。
  final Future<String> Function() urlProvider;

  final String userAgent;
  final String referer;
  final Duration idleTimeout;
  final Duration probeInterval;
  final int probeAttempts;

  final void Function(TaskState state)? onState;
  final void Function(RecordSegment segment, bool finished)? onSegment;
  final void Function(int totalBytes, double bytesPerSecond)? onProgress;

  final List<RecordSegment> segments = [];
  int totalBytes = 0;
  int retryCount = 0;
  int probeFailCount = 0;

  final StreamController<Uint8List> _preview =
      StreamController<Uint8List>.broadcast();

  /// 当前分段开头的若干字节（FLV 头 + 首个 metadata/keyframe），
  /// 供中途接入的播放器补头。
  Uint8List? _flvHeader;
  Uint8List? _initTail;
  Uint8List? _lastKeyFrame;
  final List<int> _parseBuf = [];

  /// 给中途接入的播放器补的"病态头"：FLV 头 + 序列头 + 最近一个关键帧。
  Uint8List? get prelude {
    if (_flvHeader == null) return null;
    final b = BytesBuilder(copy: false);
    b.add(_flvHeader!);
    if (_initTail != null) b.add(_initTail!);
    if (_lastKeyFrame != null) b.add(_lastKeyFrame!);
    return b.toBytes();
  }

  /// 正在录制的实时数据（不含已写入磁盘的历史字节）。
  Stream<Uint8List> get previewStream => _preview.stream;

  bool _stopped = false;
  bool _running = false;
  Future<void>? _runFuture;
  HttpClient? _client;
  StreamSubscription<List<int>>? _subscription;
  IOSink? _sink;
  Timer? _idleTimer;
  Timer? _flushTimer;
  bool _idleHit = false;
  bool _sinkClosed = false;
  Completer<String>? _segmentDone;

  bool get isRunning => _running;

  /// 开始录制，直到用户停止或判定直播结束。
  Future<void> run() {
    if (_running) return _runFuture ?? Future.value();
    _running = true;
    _runFuture = _runLoop();
    return _runFuture!;
  }

  Future<void> _runLoop() async {
    var finishedByUser = false;
    try {
      onState?.call(TaskState.recording);
      while (!_stopped) {
        final segmentIndex = segments.length + 1;
        final reason = await _recordSegment(segmentIndex);
        if (_stopped || reason == 'stopped') {
          finishedByUser = true;
          break;
        }

        if (reason == 'not-live') {
          // 404：直播未开播或已结束。
          break;
        }

        // 断流 → 探测
        onState?.call(TaskState.reconnecting);
        var alive = false;
        for (var i = 0; i < probeAttempts; i++) {
          probeFailCount = i + 1;
          await Future<void>.delayed(probeInterval);
          if (_stopped) break;
          alive = await _probe();
          if (alive) break;
        }
        probeFailCount = 0;
        if (_stopped) {
          finishedByUser = true;
          break;
        }
        if (!alive) {
          break; // 直播结束
        }
        retryCount++;
        onState?.call(TaskState.recording);
      }
    } finally {
      _running = false;
      await _teardown();
      if (!_preview.isClosed) {
        await _preview.close();
      }
      if (!finishedByUser && !_stopped) {
        onState?.call(TaskState.completed);
      }
    }
  }

  /// 录制一个分段；返回结束原因：`eof` / `idle` / `error` / `not-live` / `stopped`。
  Future<String> _recordSegment(int index) async {
    final url = await urlProvider();
    if (url.isEmpty) return 'not-live';

    final fileName = 'part${index.toString().padLeft(2, '0')}.flv';
    final file = File(p.join(outputDir.path, fileName));
    final segment = RecordSegment(
      path: file.path,
      index: index,
      startedAt: DateTime.now(),
    );
    segments.add(segment);

    await file.parent.create(recursive: true);
    final sink = file.openWrite();
    _sink = sink;
    _sinkClosed = false;
    segment.bytes = 0;
    _flvHeader = null;
    _initTail = null;
    _lastKeyFrame = null;
    _parseBuf.clear();
    onSegment?.call(segment, false);

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..userAgent = userAgent;
    _client = client;

    final done = Completer<String>();
    _segmentDone = done;
    var lastSampleAt = DateTime.now();
    var bytesAtSample = 0;

    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, userAgent);
      request.headers.set(HttpHeaders.refererHeader, referer);
      request.headers.set(HttpHeaders.acceptHeader, '*/*');
      final response = await request.close();

      if (response.statusCode != 200) {
        await response.drain<void>().catchError((_) {});
        // 404 = 直播未开播/已结束，直接判定结束；
        // 其它状态（403 签名过期 / 5xx / 429）当作断流，走 3 次探测重连，
        // 每次探测都会通过 urlProvider 重新解析最新签名地址。
        done.complete(response.statusCode == 404 ? 'not-live' : 'error');
      } else {
        _restartIdleTimer();
        _flushTimer?.cancel();
        _flushTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
          try {
            await sink.flush();
          } catch (_) {}
        });

        _subscription = response.listen(
          (chunk) {
            if (chunk.isEmpty || _sinkClosed) return;
            _restartIdleTimer();
            final bytes = Uint8List.fromList(chunk);
            _consumeForPrelude(bytes);
            try {
              sink.add(bytes);
            } catch (_) {
              // 停止录制时 sink 可能已关闭，丢弃剩余数据即可。
              return;
            }
            segment.bytes += bytes.length;
            totalBytes += bytes.length;
            if (!_preview.isClosed) _preview.add(bytes);

            final now = DateTime.now();
            final elapsed = now.difference(lastSampleAt).inMilliseconds;
            if (elapsed >= 1000) {
              final bps = (totalBytes - bytesAtSample) * 1000 / elapsed;
              lastSampleAt = now;
              bytesAtSample = totalBytes;
              onProgress?.call(totalBytes, bps);
            }
          },
          onDone: () {
            if (!done.isCompleted) done.complete(_idleHit ? 'idle' : 'eof');
          },
          onError: (Object _) {
            if (!done.isCompleted) done.complete('error');
          },
          cancelOnError: true,
        );
      }

      final reason = await done.future;

      // 用户停止：直接收尾。
      if (_stopped) return 'stopped';

      // 连接建立成功但一个字节都没给，视为没开播 / 被拒绝。
      if (reason == 'not-live') return 'not-live';

      return reason;
    } on SocketException {
      return 'error';
    } on TimeoutException {
      return 'error';
    } catch (_) {
      return 'error';
    } finally {
      _idleTimer?.cancel();
      _flushTimer?.cancel();
      await _subscription?.cancel().catchError((_) {});
      _subscription = null;
      try {
        await sink.flush();
        _sinkClosed = true;
        await sink.close();
      } catch (_) {}
      _sink = null;
      client.close(force: true);
      _client = null;

      segment.endedAt = DateTime.now();
      onSegment?.call(segment, true);
    }
  }

  /// 增量解析 FLV 标签，缓存「FLV 头 + 脚本标签/AVC 序列头 + 最近关键帧」。
  ///
  /// 中途接入的播放器只有拿到序列头 + 关键帧才能立刻出画，否则会黑屏等下一个 GOP。
  void _consumeForPrelude(Uint8List chunk) {
    _parseBuf.addAll(chunk);

    if (_flvHeader == null && _parseBuf.length >= 13) {
      _flvHeader = Uint8List.fromList(_parseBuf.sublist(0, 13));
      _parseBuf.removeRange(0, 13);
    }

    while (_parseBuf.length >= 11) {
      final tagType = _parseBuf[0] & 0x1F;
      final size = (_parseBuf[1] << 16) | (_parseBuf[2] << 8) | _parseBuf[3];
      final total = 11 + size + 4;
      if (_parseBuf.length < total) break;

      final tagBytes = Uint8List.fromList(_parseBuf.sublist(0, total));
      final body = _parseBuf.sublist(11, 11 + size);
      _parseBuf.removeRange(0, total);

      if (tagType == 18) {
        // onMetaData
        _initTail = _concatBytes(_initTail, tagBytes);
      } else if (tagType == 9 && body.length >= 2) {
        final frameType = (body[0] >> 4) & 0x0F;
        final avcPacketType = body[1];
        if (avcPacketType == 0) {
          // AVC sequence header
          _initTail = _concatBytes(_initTail, tagBytes);
        } else if (frameType == 1) {
          _lastKeyFrame = tagBytes;
        }
      }

      if (_parseBuf.length > 4 * 1024 * 1024) _parseBuf.clear();
    }
  }

  Uint8List _concatBytes(Uint8List? a, Uint8List b) {
    if (a == null) return b;
    final out = Uint8List(a.length + b.length)
      ..setRange(0, a.length, a)
      ..setRange(a.length, a.length + b.length, b);
    return out;
  }

  void _restartIdleTimer() {
    _idleHit = false;
    _idleTimer?.cancel();
    _idleTimer = Timer(idleTimeout, () {
      _idleHit = true;
      _subscription?.cancel();
      final done = _segmentDone;
      if (done != null && !done.isCompleted) done.complete('idle');
    });
  }

  /// 探测直播是否还活着：能建立连接并读到 FLV 头即视为活着。
  Future<bool> _probe() async {
    final url = await urlProvider();
    if (url.isEmpty) return false;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..userAgent = userAgent;
    try {
      final request = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 8));
      request.headers.set(HttpHeaders.userAgentHeader, userAgent);
      request.headers.set(HttpHeaders.refererHeader, referer);
      final response =
          await request.close().timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        await response.drain<void>().catchError((_) {});
        return false;
      }
      final first = await response.first.timeout(const Duration(seconds: 8));
      return first.length >= 3 && first[0] == 0x46 && first[1] == 0x4C;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// 停止录制（会结束当前分段）。
  Future<void> stop() async {
    _stopped = true;
    _idleTimer?.cancel();
    final done = _segmentDone;
    if (done != null && !done.isCompleted) done.complete('stopped');
    await _subscription?.cancel().catchError((_) {});
    _client?.close(force: true);
    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (_) {}
    await _runFuture;
  }

  Future<void> _teardown() async {
    _idleTimer?.cancel();
    _flushTimer?.cancel();
    await _subscription?.cancel().catchError((_) {});
    _subscription = null;
    _client?.close(force: true);
    _client = null;
  }
}
