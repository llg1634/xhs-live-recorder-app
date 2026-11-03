import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/live_room.dart';
import '../models/record_task.dart';

/// 一次失败属于哪一类：决定「继续无限重试」还是「可以判定直播结束」。
enum ReconnectErrorKind {
  none, // 成功 / 非失败状态
  transient, // 网络瞬断、超时、连接重置、5xx、403 签名过期、响应体提前 EOF
  liveEnded, // 404 / 410（仍需宽限确认，不能一次就结束）
}

/// 断流重连策略（纯逻辑，便于单测）。
///
/// 为什么不用固定 3 次探测：直播断流绝大多数是弱网/CDN 抖动，
/// 3 次 × 5 秒判死会把「轻微断流」直接变成「录制结束」。
/// 这里采用指数退避 + 抖动，且**永不因网络错误停止**；只有用户停止或
/// 连续 404/410 达到宽限期才结束任务。
class ReconnectPolicy {
  ReconnectPolicy({
    List<Duration>? baseDelays,
    this.maxDelay = const Duration(seconds: 30),
    this.jitterRatio = 0.2,
    this.notFoundGrace = const Duration(seconds: 120),
    this.notFoundMinAttempts = 12,
    Random? random,
  }) : baseDelays = baseDelays ?? defaultBaseDelays,
       _random = random ?? Random();

  /// 基准退避序列：2s → 3s → 5s → 8s → 13s → 21s → 30s 封顶。
  static const List<Duration> defaultBaseDelays = <Duration>[
    Duration(seconds: 2),
    Duration(seconds: 3),
    Duration(seconds: 5),
    Duration(seconds: 8),
    Duration(seconds: 13),
    Duration(seconds: 21),
    Duration(seconds: 30),
  ];

  final List<Duration> baseDelays;
  final Duration maxDelay;

  /// 抖动比例：±20%，避免大量客户端在同一秒集中重连。
  final double jitterRatio;

  /// 连续 404/410 的宽限：达到最少次数或持续时间任一条件即认定直播结束。
  final Duration notFoundGrace;
  final int notFoundMinAttempts;

  final Random _random;

  /// 第 [attempt] 次重连的**不抖动**基准间隔（attempt 从 1 开始）。
  Duration baseDelayFor(int attempt) {
    if (attempt < 1) {
      throw ArgumentError.value(attempt, 'attempt', '必须从 1 开始');
    }
    final int index = attempt - 1;
    if (index >= baseDelays.length) return maxDelay;
    final Duration candidate = baseDelays[index];
    return candidate > maxDelay ? maxDelay : candidate;
  }

  /// 第 [attempt] 次重连前的实际等待时间（基准 ± [jitterRatio]）。
  Duration delayFor(int attempt) {
    final Duration base = baseDelayFor(attempt);
    if (jitterRatio <= 0) return base;
    final double factor = 1 + (_random.nextDouble() * 2 - 1) * jitterRatio;
    final int ms = (base.inMilliseconds * factor).round();
    return Duration(milliseconds: ms < 1 ? 1 : ms);
  }

  /// 给单个录制器创建独立的 404 宽限计数器（状态不能跨任务共享）。
  LiveEndDetector newLiveEndDetector() =>
      LiveEndDetector(grace: notFoundGrace, minAttempts: notFoundMinAttempts);

  /// HTTP 状态码分类。
  static ReconnectErrorKind classifyStatus(int statusCode) {
    if (statusCode == HttpStatus.notFound || statusCode == HttpStatus.gone) {
      return ReconnectErrorKind.liveEnded;
    }
    if (statusCode >= 200 && statusCode < 300) {
      return ReconnectErrorKind.none;
    }
    return ReconnectErrorKind.transient;
  }

  /// 异常分类：SocketException / TimeoutException / 连接重置 /
  /// 响应体提前 EOF（HttpException）全部是可恢复的瞬时错误。
  static ReconnectErrorKind classifyError(Object error) {
    // 这里刻意不把任何异常升级为 liveEnded：异常本身不能证明直播结束，
    // 只有服务端明确返回 404/410 并持续超过宽限期才可以。
    if (error is SocketException ||
        error is TimeoutException ||
        error is HttpException ||
        error is IOException) {
      return ReconnectErrorKind.transient;
    }
    return ReconnectErrorKind.transient;
  }

  /// 把异常转成一句能写进任务/通知的中文原因。
  static String describeError(Object error) {
    if (error is SocketException) {
      return '网络连接异常：${error.message}';
    }
    if (error is TimeoutException) {
      return '网络超时';
    }
    if (error is HttpException) {
      return '连接被中断：${error.message}';
    }
    return '网络异常：$error';
  }

  /// 只有用户停止 / 确认直播结束才允许结束任务。
  bool shouldStop({
    required bool userStopped,
    required bool liveEndConfirmed,
  }) => userStopped || liveEndConfirmed;
}

/// 连续 404/410 的宽限判定。
///
/// 为什么要宽限：直播 CDN 偶发 404（节点切换/回源失败）并不等于直播结束，
/// 一次 404 就结束会误杀；反过来真结束时也没必要再重试几个小时。
/// 判定条件：连续 404/410 次数 >= [minAttempts] **且** 持续时间 >= [grace]
/// 两个条件同时满足才结束——只满足次数（弱网下 404 可能连成串又很快恢复）
/// 或只满足时长（拉长退避后几次 404 就跨过 2 分钟）都会误杀正在播的直播。
class LiveEndDetector {
  LiveEndDetector({required this.grace, required this.minAttempts});

  final Duration grace;
  final int minAttempts;

  DateTime? _firstAt;
  int _count = 0;

  int get consecutiveCount => _count;

  DateTime? get firstNotFoundAt => _firstAt;

  /// 记录一次 404/410；返回 true 表示可以确认直播已经结束。
  bool registerNotFound(DateTime now) {
    _firstAt ??= now;
    _count++;
    return _count >= minAttempts && now.difference(_firstAt!) >= grace;
  }

  /// 收到数据或遇到非 404/410 错误：宽限从头计算。
  void reset() {
    _firstAt = null;
    _count = 0;
  }
}

/// 重连状态通知：录制器 → 调度器，用于持久化重试次数与通知文案。
class ReconnectNotice {
  const ReconnectNotice({
    required this.attempt,
    this.errorText,
    this.nextRetryAt,
    this.failureDuration = Duration.zero,
    this.recovered = false,
  });

  const ReconnectNotice.recovered()
    : attempt = 0,
      errorText = null,
      nextRetryAt = null,
      failureDuration = Duration.zero,
      recovered = true;

  /// 当前连续重连的第几次（从 1 开始）。
  final int attempt;

  /// 本次失败原因。
  final String? errorText;

  /// 计划下一次重连的时间。
  final DateTime? nextRetryAt;

  /// 从第一次失败到现在持续了多久（用于 10 分钟长故障提示）。
  final Duration failureDuration;

  /// 是否已经恢复（收到数据）。
  final bool recovered;

  bool get longFailure => failureDuration >= const Duration(minutes: 10);
}

/// 录制分段的结束原因（内部使用）。
enum _SegmentReason { eof, idle, stall, error, notLive, stopped }

class _SegmentOutcome {
  const _SegmentOutcome(
    this.reason, {
    this.statusCode,
    this.errorText,
    this.sawData = false,
    this.fatal = false,
  });

  final _SegmentReason reason;
  final int? statusCode;
  final String? errorText;
  final bool sawData;

  /// 本地文件系统错误等「重试也不会好」的问题；交给上层标记 interrupted。
  final bool fatal;

  bool get isNotFound =>
      statusCode == HttpStatus.notFound || statusCode == HttpStatus.gone;
}

/// 串行化 `IOSink.add` / `flush` 的小包装。
///
/// Dart 的 IOSink.flush() 会把 sink 标记为 "bound to a stream"，期间任何 add
/// 都会抛 `Bad state: StreamSink is bound to a stream`。录制器的 1 秒定时 flush
/// 与持续到达的直播数据天然并发，必须把 flush 期间的字节先缓存在内存里，
/// 等 flush 完成后再写入；否则每秒就会中断一次分段。
class _SegmentSink {
  _SegmentSink(this._sink);

  final IOSink _sink;
  final List<int> _pending = <int>[];
  Future<void>? _flushing;
  bool _closed = false;

  void add(List<int> data) {
    if (_closed) return;
    if (_flushing != null) {
      _pending.addAll(data);
      return;
    }
    _sink.add(data);
  }

  Future<void> flush() {
    if (_closed) return Future<void>.value();
    final Future<void>? inFlight = _flushing;
    if (inFlight != null) return inFlight;
    if (_pending.isNotEmpty) {
      _sink.add(_pending);
      _pending.clear();
    }
    final Future<void> future = _sink.flush().whenComplete(() {
      _flushing = null;
    });
    _flushing = future;
    return future;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final Future<void>? inFlight = _flushing;
    if (inFlight != null) {
      try {
        await inFlight;
      } catch (_) {}
    }
    if (_pending.isNotEmpty) {
      _sink.add(_pending);
      _pending.clear();
    }
    try {
      await _sink.flush();
    } catch (_) {}
    await _sink.close();
  }
}

/// 单直播间 FLV 录制引擎。
///
/// 核心策略（已实测验证）：
/// - 小红书 FLV 直链无签名、无 Cookie 依赖，`房间号` 即可直连；
/// - 断流后**同一条 URL 重新连接**即可从当前直播点继续，不需要刷新页面；
/// - 断流后按 [ReconnectPolicy] 无限退避重连（2s→30s 封顶 + 抖动），
///   每次连接成功都开一个新分段（partNN 递增），旧分段绝不覆盖；
/// - 只有用户停止、或服务端连续 404/410 超过宽限期，才结束任务；
/// - 读流超过 [stallTimeout] 没有新字节 → 看门狗主动断开重连，
///   不等 25s idle 超时（弱网下旧逻辑会把「卡住」拖成「结束」）。
class FlvRecorder {
  FlvRecorder({
    required this.room,
    required this.outputDir,
    required this.urlProvider,
    this.userAgent = defaultUserAgent,
    this.referer = 'https://www.xiaohongshu.com/',
    this.idleTimeout = const Duration(seconds: 25),
    this.stallTimeout = const Duration(seconds: 18),
    this.connectTimeout = const Duration(seconds: 10),
    ReconnectPolicy? reconnectPolicy,
    this.onState,
    this.onSegment,
    this.onProgress,
    this.onReconnect,
  }) : reconnectPolicy = reconnectPolicy ?? ReconnectPolicy();

  static const defaultUserAgent =
      'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

  final LiveRoom room;
  final Directory outputDir;

  /// 每次新建连接前调用，便于抖音这类带时效签名的平台刷新地址。
  ///
  /// 允许抛异常 / 返回空串：录制器会把它当作可重试错误，**不会结束任务**。
  final Future<String> Function() urlProvider;

  final String userAgent;
  final String referer;
  final Duration idleTimeout;
  final Duration stallTimeout;
  final Duration connectTimeout;
  final ReconnectPolicy reconnectPolicy;

  final void Function(TaskState state)? onState;
  final void Function(RecordSegment segment, bool finished)? onSegment;
  final void Function(int totalBytes, double bytesPerSecond)? onProgress;
  final void Function(ReconnectNotice notice)? onReconnect;

  final List<RecordSegment> segments = [];
  int totalBytes = 0;

  /// 累计重连次数（跨多次断流不清零，供 UI 显示）。
  int retryCount = 0;

  /// 最后一次收到直播数据的本机时间（看门狗/调度器判断"是否真的还在写盘"）。
  DateTime? lastDataAt;

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
  Timer? _idleTimer;
  Timer? _watchdogTimer;
  Timer? _flushTimer;
  Timer? _retryTimer;
  Completer<void>? _retryWaiter;
  bool _sinkClosed = false;
  bool _currentSegmentSawData = false;
  Completer<_SegmentOutcome>? _segmentDone;

  /// 是否处于「已通知 reconnecting、还没收到数据」的窗口。
  /// 第一块数据到达时立刻切回 recording，而不是等这一分段结束。
  bool _reconnectPending = false;

  /// 本轮连续失败的起点（收到数据后清零），用于 10 分钟长故障提示。
  DateTime? _failureStartedAt;

  bool get isRunning => _running;

  /// 开始录制，直到用户停止或确认直播结束。
  Future<void> run() {
    if (_running) return _runFuture ?? Future.value();
    _running = true;
    _runFuture = _runLoop();
    return _runFuture!;
  }

  Future<void> _runLoop() async {
    var finishedByUser = false;
    var liveEnded = false;
    var attempt = 0;
    final LiveEndDetector liveEnd = reconnectPolicy.newLiveEndDetector();
    try {
      onState?.call(TaskState.recording);
      while (!_stopped) {
        final int segmentIndex = await _nextSegmentIndex();
        if (_stopped) {
          finishedByUser = true;
          break;
        }
        final _SegmentOutcome outcome = await _recordSegment(segmentIndex);
        if (_stopped || outcome.reason == _SegmentReason.stopped) {
          finishedByUser = true;
          break;
        }
        if (outcome.fatal) {
          // 本地文件系统错误：重试也写不进去，保留已录内容交给上层中断。
          break;
        }

        if (outcome.sawData) {
          // 这条连接真正收到过数据：地址/签名有效，退避与 404 宽限从头算。
          attempt = 0;
          _failureStartedAt = null;
          liveEnd.reset();
        }

        if (outcome.isNotFound) {
          if (liveEnd.registerNotFound(DateTime.now())) {
            liveEnded = true;
            break;
          }
        } else {
          // 只要不是连续 404/410，就不按"直播结束"处理。
          liveEnd.reset();
        }

        attempt++;
        retryCount++;
        _reconnectPending = true;
        _failureStartedAt ??= DateTime.now();
        final Duration delay = reconnectPolicy.delayFor(attempt);
        final DateTime nextRetryAt = DateTime.now().add(delay);
        final String errorText =
            outcome.errorText ??
            (outcome.isNotFound
                ? 'HTTP ${outcome.statusCode}（直播可能已结束，宽限确认中）'
                : '连接断开');
        onState?.call(TaskState.reconnecting);
        onReconnect?.call(
          ReconnectNotice(
            attempt: attempt,
            errorText: errorText,
            nextRetryAt: nextRetryAt,
            failureDuration: DateTime.now().difference(_failureStartedAt!),
          ),
        );
        await _waitBeforeRetry(delay);
      }
    } catch (e) {
      // 录制循环本身不应抛出：任何意外都按"中断可继续"处理，绝不静默结束。
      debugPrint('[rec] run loop crashed: $e');
    } finally {
      _running = false;
      await _teardown();
      if (!_preview.isClosed) {
        await _preview.close();
      }
      if (finishedByUser || _stopped) {
        // 用户停止：由 RecordingManager 负责置 stopped，这里不覆盖状态。
      } else if (liveEnded) {
        onState?.call(TaskState.completed);
      } else {
        onState?.call(TaskState.interrupted);
      }
    }
  }

  /// 可被 [stop] 立即打断的退避等待（否则用户点停止要等最多 30 秒）。
  Future<void> _waitBeforeRetry(Duration delay) {
    final completer = Completer<void>();
    _retryWaiter = completer;
    _retryTimer = Timer(delay, () {
      if (!completer.isCompleted) completer.complete();
    });
    return completer.future.whenComplete(() {
      _retryTimer?.cancel();
      _retryTimer = null;
      if (identical(_retryWaiter, completer)) _retryWaiter = null;
    });
  }

  /// 下一个分段号：**以磁盘上已有的 partNN 为准**，绝不覆盖已经录好的文件。
  ///
  /// 之前用的是 `segments.length + 1`：只要分段列表因为恢复/重扫失败而变短，
  /// 就会重新从 `part01.flv` 开始写，而 `File.openWrite()` 默认是截断模式，
  /// 一次"继续录制 / 重新连接"就可能把整段已录内容清空。
  Future<int> _nextSegmentIndex() async {
    final List<String> existing = <String>[];
    try {
      await for (final FileSystemEntity entity in outputDir.list()) {
        if (entity is File) existing.add(entity.path);
      }
    } catch (_) {
      // 目录读不到时退回内存里的分段数，后面的 exists() 兜底仍会避开已有文件。
    }
    return nextIndexFor(existing, fallbackCount: segments.length);
  }

  /// 计算下一个分段号（纯函数，便于单测）：磁盘上最大的 partNN + 1。
  static int nextIndexFor(
    Iterable<String> existingPaths, {
    int fallbackCount = 0,
  }) {
    var maxIndex = fallbackCount;
    for (final String path in existingPaths) {
      final int? index = segmentIndexFromPath(path);
      if (index != null && index > maxIndex) maxIndex = index;
    }
    return maxIndex + 1;
  }

  /// 从 `part12.flv` 解析出 12；不是分段文件名返回 null。
  static int? segmentIndexFromPath(String path) {
    final RegExpMatch? match = RegExp(
      r'part(\d+)\.flv$',
      caseSensitive: false,
    ).firstMatch(path);
    if (match == null) return null;
    return int.tryParse(match.group(1) ?? '');
  }

  /// `part01.flv` 这种固定宽度命名，保证按文件名排序也是录制顺序。
  static String _segmentFileName(int index) =>
      'part${index.toString().padLeft(2, '0')}.flv';

  /// 找一个未被占用的分段文件名；只计算路径，不提前创建空文件。
  ///
  /// 失败的重连尝试不应该在录像目录里留下几十个 0 字节 `partNN.flv`，
  /// 所以文件在**收到第一块数据时**才真正 openWrite。
  Future<File> _freeSegmentFile(int index) async {
    var safeIndex = index;
    var file = File(p.join(outputDir.path, _segmentFileName(safeIndex)));
    for (var i = 0; i < 32; i++) {
      if (!await file.exists()) return file;
      safeIndex++;
      file = File(p.join(outputDir.path, _segmentFileName(safeIndex)));
    }
    throw FileSystemException('32 个分段候选名均已被占用', file.path);
  }

  /// 录制一个分段；返回结束原因与是否真的收到过数据。
  Future<_SegmentOutcome> _recordSegment(int index) async {
    if (_stopped) {
      return const _SegmentOutcome(_SegmentReason.stopped, errorText: '用户停止录制');
    }
    final String url;
    try {
      url = (await urlProvider()).trim();
    } catch (e) {
      return _SegmentOutcome(
        _SegmentReason.error,
        errorText: '解析直播地址失败：${ReconnectPolicy.describeError(e)}',
      );
    }
    if (url.isEmpty) {
      return const _SegmentOutcome(
        _SegmentReason.error,
        errorText: '直播地址为空，稍后重新解析',
      );
    }
    final Uri? uri = Uri.tryParse(url);
    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return const _SegmentOutcome(
        _SegmentReason.error,
        errorText: '直播地址格式无效，稍后重新解析',
      );
    }

    final File file;
    try {
      await outputDir.create(recursive: true);
      file = await _freeSegmentFile(index);
    } catch (e) {
      return _SegmentOutcome(
        _SegmentReason.error,
        errorText: '无法创建录像文件：$e',
        fatal: true,
      );
    }

    final HttpClient client = HttpClient()
      ..connectionTimeout = connectTimeout
      ..userAgent = userAgent;
    _client = client;

    RecordSegment? segment;
    _SegmentSink? sink;
    _sinkClosed = false; // 新连接开始，上一个分段留下的关闭标记不能带进来
    _currentSegmentSawData = false;
    var sawData = false;
    var lastSampleAt = DateTime.now();
    var bytesAtSample = totalBytes;

    final Completer<_SegmentOutcome> done = Completer<_SegmentOutcome>();
    _segmentDone = done;

    void finish(_SegmentReason reason, {String? errorText, int? statusCode}) {
      if (done.isCompleted) return;
      done.complete(
        _SegmentOutcome(
          reason,
          statusCode: statusCode,
          errorText: errorText,
          sawData: sawData,
        ),
      );
    }

    try {
      debugPrint('[rec] part$index connecting: $uri');
      final HttpClientRequest request = await client
          .getUrl(uri)
          .timeout(connectTimeout);
      request.headers.set(HttpHeaders.userAgentHeader, userAgent);
      request.headers.set(HttpHeaders.refererHeader, referer);
      request.headers.set(HttpHeaders.acceptHeader, '*/*');
      final HttpClientResponse response = await request.close().timeout(
        connectTimeout,
      );
      debugPrint('[rec] part$index HTTP ${response.statusCode}');

      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>().catchError((_) {});
        final int code = response.statusCode;
        final bool gone =
            ReconnectPolicy.classifyStatus(code) ==
            ReconnectErrorKind.liveEnded;
        return _SegmentOutcome(
          gone ? _SegmentReason.notLive : _SegmentReason.error,
          statusCode: code,
          errorText: gone
              ? 'HTTP $code（直播可能已结束，宽限确认中）'
              : 'HTTP $code（将重新解析地址后重试）',
        );
      }

      // 连接成功：先记一次"活着"的时间，之后按滑动窗口看门狗判断停滞。
      lastDataAt = DateTime.now();
      _restartIdleTimer();
      _startWatchdog();

      _subscription = response.listen(
        (chunk) {
          if (chunk.isEmpty || _sinkClosed) return;

          if (!sawData) {
            sawData = true;
            _currentSegmentSawData = true;
            debugPrint('[rec] part$index first data: ${chunk.length}B');
            try {
              final RecordSegment created = RecordSegment(
                path: file.path,
                index: index,
                startedAt: DateTime.now(),
              );
              segment = created;
              segments.add(created);
              final _SegmentSink opened = _SegmentSink(file.openWrite());
              sink = opened;
              _sinkClosed = false;
              _flvHeader = null;
              _initTail = null;
              _lastKeyFrame = null;
              _parseBuf.clear();
              _startFlushTimer(opened);
              onSegment?.call(created, false);

              // 第一块数据到了：重连成功，立刻恢复「录制中」，
              // 不用等这一分段结束（否则断流期间的通知会一直停在重连中）。
              if (_reconnectPending) {
                _reconnectPending = false;
                _failureStartedAt = null;
                onState?.call(TaskState.recording);
                onReconnect?.call(const ReconnectNotice.recovered());
              }
            } catch (e) {
              finish(_SegmentReason.error, errorText: '创建分段文件失败：$e');
              return;
            }
          }

          lastDataAt = DateTime.now();
          // 每个 chunk 都重置 idle 定时器：否则持续有数据时 25s 也会被误判"没数据"
          // 而强制结束分段（重连后每 25s 断一次，和旧版 15s 判死同类问题）。
          _restartIdleTimer();
          final Uint8List bytes = chunk is Uint8List
              ? chunk
              : Uint8List.fromList(chunk);
          _consumeForPrelude(bytes);
          try {
            sink!.add(bytes);
          } catch (e) {
            finish(_SegmentReason.error, errorText: '写入录像文件失败：$e');
            return;
          }
          segment!.bytes += bytes.length;
          totalBytes += bytes.length;
          if (!_preview.isClosed) _preview.add(bytes);

          final DateTime now = DateTime.now();
          final int elapsed = now.difference(lastSampleAt).inMilliseconds;
          if (elapsed >= 1000) {
            final double bps = (totalBytes - bytesAtSample) * 1000 / elapsed;
            lastSampleAt = now;
            bytesAtSample = totalBytes;
            onProgress?.call(totalBytes, bps);
          }
        },
        onDone: () {
          finish(
            _SegmentReason.eof,
            errorText: sawData ? '直播流被断开（响应体提前结束），准备重连' : '连接已建立但没有收到数据，准备重连',
          );
        },
        onError: (Object error) {
          finish(
            _SegmentReason.error,
            errorText: ReconnectPolicy.describeError(error),
          );
        },
        cancelOnError: true,
      );

      final _SegmentOutcome result = await done.future;
      debugPrint(
        '[rec] part$index end: ${result.reason.name} '
        'sawData=${result.sawData} error=${result.errorText}',
      );
      return result;
    } on SocketException catch (e) {
      return _SegmentOutcome(
        _SegmentReason.error,
        errorText: ReconnectPolicy.describeError(e),
        sawData: sawData,
      );
    } on TimeoutException catch (e) {
      return _SegmentOutcome(
        _SegmentReason.error,
        errorText: ReconnectPolicy.describeError(e),
        sawData: sawData,
      );
    } catch (e) {
      return _SegmentOutcome(
        _SegmentReason.error,
        errorText: ReconnectPolicy.describeError(e),
        sawData: sawData,
      );
    } finally {
      _idleTimer?.cancel();
      _idleTimer = null;
      _watchdogTimer?.cancel();
      _watchdogTimer = null;
      _flushTimer?.cancel();
      _flushTimer = null;
      await _subscription?.cancel().catchError((_) {});
      _subscription = null;

      // 重连前必须把已经写入的字节 flush 到磁盘：断流时不能丢最后 1 秒数据。
      final _SegmentSink? sinkToClose = sink;
      try {
        if (sinkToClose != null) {
          await sinkToClose.flush();
          _sinkClosed = true;
          await sinkToClose.close();
        }
      } catch (_) {}
      client.close(force: true);
      _client = null;

      final RecordSegment? segmentToFinish = segment;
      if (segmentToFinish != null) {
        segmentToFinish.endedAt = DateTime.now();
        onSegment?.call(segmentToFinish, true);
      }
      _segmentDone = null;
    }
  }

  void _startFlushTimer(_SegmentSink sink) {
    _flushTimer?.cancel();
    _flushTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      try {
        await sink.flush();
      } catch (_) {}
    });
  }

  /// 看门狗：每秒钟检查「最近一次收到数据」的滑动窗口。
  ///
  /// 为什么不用 25s idle：直播卡住时连接往往不会断，只是没有数据；
  /// 等 25s 才结束时，观众侧可能已经断流十几秒。18s 主动重连更快恢复。
  void _startWatchdog() {
    _watchdogTimer?.cancel();
    if (stallTimeout <= Duration.zero) return;
    final Duration tick = stallTimeout < const Duration(seconds: 2)
        ? const Duration(milliseconds: 200)
        : const Duration(seconds: 1);
    _watchdogTimer = Timer.periodic(tick, (_) {
      final DateTime? last = lastDataAt;
      if (last == null || _sinkClosed) return;
      if (DateTime.now().difference(last) < stallTimeout) return;
      final Completer<_SegmentOutcome>? pending = _segmentDone;
      if (pending != null && !pending.isCompleted) {
        pending.complete(
          _SegmentOutcome(
            _SegmentReason.stall,
            errorText: '超过 ${_durationText(stallTimeout)}没有收到数据，主动断开重连',
            sawData: _currentSegmentSawData,
          ),
        );
      }
      _subscription?.cancel();
    });
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

  /// 把超时时间变成日志里可读的 `18s` / `350ms`。
  String _durationText(Duration value) => value.inSeconds >= 1
      ? '${value.inSeconds}s'
      : '${value.inMilliseconds}ms';

  void _restartIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(idleTimeout, () {
      _subscription?.cancel();
      final Completer<_SegmentOutcome>? done = _segmentDone;
      if (done != null && !done.isCompleted) {
        done.complete(
          _SegmentOutcome(
            _SegmentReason.idle,
            errorText: '超过 ${_durationText(idleTimeout)}没有新数据，结束当前分段',
            sawData: _currentSegmentSawData,
          ),
        );
      }
    });
  }

  /// 停止录制（会结束当前分段）。等待可被立即唤醒，不会卡在退避计时里。
  Future<void> stop() async {
    _stopped = true;
    _idleTimer?.cancel();
    _watchdogTimer?.cancel();
    _flushTimer?.cancel();
    _retryTimer?.cancel();
    final Completer<void>? waiter = _retryWaiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();

    final Completer<_SegmentOutcome>? done = _segmentDone;
    if (done != null && !done.isCompleted) {
      done.complete(
        _SegmentOutcome(
          _SegmentReason.stopped,
          errorText: '用户停止录制',
          sawData: _currentSegmentSawData,
        ),
      );
    }
    await _subscription?.cancel().catchError((_) {});
    _client?.close(force: true);
    // 分段的 flush / close 统一交给 _recordSegment 的 finally，
    // 避免 stop 与 finally 同时关闭同一个 sink（Windows 上会留下句柄）。
    await _runFuture;
  }

  Future<void> _teardown() async {
    _idleTimer?.cancel();
    _idleTimer = null;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _flushTimer?.cancel();
    _flushTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    await _subscription?.cancel().catchError((_) {});
    _subscription = null;
    _client?.close(force: true);
    _client = null;
  }
}
