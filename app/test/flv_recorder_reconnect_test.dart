import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:live_recorder/models/live_room.dart';
import 'package:live_recorder/models/record_task.dart';
import 'package:live_recorder/services/flv_recorder.dart';

/// 极速重连策略：把 2s→30s 压到 20ms，集成测试才能在几秒内跑完。
ReconnectPolicy _fastPolicy({
  Duration notFoundGrace = const Duration(milliseconds: 300),
  int notFoundMinAttempts = 2,
}) {
  return ReconnectPolicy(
    baseDelays: const <Duration>[Duration(milliseconds: 20)],
    maxDelay: const Duration(milliseconds: 40),
    jitterRatio: 0,
    notFoundGrace: notFoundGrace,
    notFoundMinAttempts: notFoundMinAttempts,
  );
}

LiveRoom _room() => const LiveRoom(
  platform: LivePlatform.xhs,
  roomId: '570523767964339555',
  pageUrl: 'https://www.xiaohongshu.com/livestream/570523767964339555',
  rawInput: 'https://www.xiaohongshu.com/livestream/570523767964339555',
  title: '测试直播间',
);

Future<void> _waitUntil(
  bool Function() predicate, {
  String? reason,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException(reason ?? '等待条件超时');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// 写够指定字节后强行 detach + destroy socket（模拟 CDN 断流 / RST），
/// 而不是礼貌地 close（真实断流通常没有 FIN）。
Future<void> _sendAndReset(HttpRequest request, int totalBytes) async {
  final HttpResponse response = request.response;
  response.statusCode = HttpStatus.ok;
  response.headers.contentType = ContentType.binary;
  response.contentLength = totalBytes;
  final Socket socket = await response.detachSocket(writeHeaders: true);
  final Uint8List chunk = Uint8List(64 * 1024)..fillRange(0, 64 * 1024, 0x46);
  var remaining = totalBytes;
  while (remaining > 0) {
    final int n = remaining < chunk.length ? remaining : chunk.length;
    socket.add(n == chunk.length ? chunk : chunk.sublist(0, n));
    remaining -= n;
  }
  await socket.flush();
  socket.destroy();
}

/// 发一小段数据后保持连接（半开、不再有数据）：用于看门狗测试。
Future<void> _sendAndHang(HttpRequest request, {int bytes = 64 * 1024}) async {
  final HttpResponse response = request.response;
  response.statusCode = HttpStatus.ok;
  response.headers.contentType = ContentType.binary;
  response.bufferOutput = false;
  response.add(Uint8List(bytes)..fillRange(0, bytes, 0x46));
  await response.flush();
  // 刻意不 close：模拟「连接还在、但没有新数据」的卡死状态。
}

/// 持续发送小 chunk 若干秒且不关闭连接：专门覆盖「1 秒定时 flush 与 add 并发」
/// 的回归（旧实现会抛 StreamSink is bound to a stream）。
Future<void> _streamForAWhile(
  HttpRequest request, {
  int chunks = 20,
  Duration interval = const Duration(milliseconds: 100),
}) async {
  final HttpResponse response = request.response;
  response.statusCode = HttpStatus.ok;
  response.headers.contentType = ContentType.binary;
  response.bufferOutput = false;
  for (var i = 0; i < chunks; i++) {
    response.add(Uint8List(16 * 1024)..fillRange(0, 16 * 1024, 0x46));
    await response.flush();
    await Future<void>.delayed(interval);
  }
  // 不 close：保持半开，等测试主动 stop。
  await Future<void>.delayed(const Duration(seconds: 15));
}

void main() {
  group('FlvRecorder 自动重连（本地 HttpServer 集成）', () {
    test('发 200KB 后强行断开 socket → 自动重连、写出 part02、状态不是 completed', () async {
      final Directory dir = await Directory.systemTemp.createTemp(
        'flv_reconnect_',
      );
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });

      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => server.close(force: true));

      var connections = 0;
      final StreamSubscription<HttpRequest> sub = server.listen((
        HttpRequest request,
      ) {
        connections++;
        if (connections == 1) {
          unawaited(
            _sendAndReset(request, 200 * 1024).catchError((Object _) {}),
          );
        } else {
          unawaited(_sendAndHang(request).catchError((Object _) {}));
        }
      });
      addTearDown(sub.cancel);

      final String url = 'http://127.0.0.1:${server.port}/live.flv';
      final List<TaskState> states = <TaskState>[];
      var urlCalls = 0;
      final FlvRecorder recorder = FlvRecorder(
        room: _room(),
        outputDir: dir,
        urlProvider: () async {
          urlCalls++;
          return url;
        },
        reconnectPolicy: _fastPolicy(),
        stallTimeout: const Duration(seconds: 5),
        idleTimeout: const Duration(seconds: 10),
        onState: states.add,
      );

      final Future<void> runFuture = recorder.run();
      await _waitUntil(
        () => recorder.segments.length >= 2 && recorder.segments[1].bytes > 0,
        reason: '没有自动重连出第二个分段',
      );

      expect(urlCalls, greaterThanOrEqualTo(2), reason: '每轮重连都要重新解析地址');
      expect(recorder.segments.first.bytes, 200 * 1024);
      expect(recorder.segments.length, greaterThanOrEqualTo(2));
      expect(await File(recorder.segments[1].path).exists(), isTrue);
      expect(await File(recorder.segments[1].path).length(), greaterThan(0));
      expect(states, contains(TaskState.reconnecting));
      expect(states, isNot(contains(TaskState.completed)));
      // 第二段第一块数据到达就应该恢复 recording，而不是等分段结束。
      expect(states.last, TaskState.recording);
      expect(recorder.isRunning, isTrue);

      await recorder.stop();
      await runFuture;
      expect(states, isNot(contains(TaskState.completed)));
    });

    test('持续 404 → 宽限期后 completed（不误报网络错误）', () async {
      final Directory dir = await Directory.systemTemp.createTemp('flv_404_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });

      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => server.close(force: true));

      var requests = 0;
      final StreamSubscription<HttpRequest> sub = server.listen((
        HttpRequest request,
      ) {
        requests++;
        request.response.statusCode = HttpStatus.notFound;
        request.response.write('live not found');
        unawaited(request.response.close().catchError((Object _) {}));
      });
      addTearDown(sub.cancel);

      final List<TaskState> states = <TaskState>[];
      final FlvRecorder recorder = FlvRecorder(
        room: _room(),
        outputDir: dir,
        urlProvider: () async => 'http://127.0.0.1:${server.port}/live.flv',
        reconnectPolicy: _fastPolicy(
          notFoundGrace: const Duration(milliseconds: 250),
          notFoundMinAttempts: 2,
        ),
        stallTimeout: const Duration(seconds: 5),
        onState: states.add,
      );

      await recorder.run().timeout(const Duration(seconds: 10));

      expect(states.last, TaskState.completed);
      expect(states, isNot(contains(TaskState.error)));
      expect(requests, greaterThanOrEqualTo(2), reason: '404 也要按退避重试到宽限期');
      expect(recorder.isRunning, isFalse);
    });

    test('urlProvider 一直抛异常 → 无限重试不结束，stop 后退出', () async {
      final Directory dir = await Directory.systemTemp.createTemp('flv_url_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });

      final List<TaskState> states = <TaskState>[];
      var calls = 0;
      final FlvRecorder recorder = FlvRecorder(
        room: _room(),
        outputDir: dir,
        urlProvider: () async {
          calls++;
          throw const SocketException('network is unreachable');
        },
        reconnectPolicy: _fastPolicy(),
        stallTimeout: const Duration(seconds: 5),
        onState: states.add,
      );

      final Future<void> runFuture = recorder.run();
      await _waitUntil(() => calls >= 4, reason: 'urlProvider 没有被持续重试');
      expect(recorder.isRunning, isTrue);
      expect(states, contains(TaskState.reconnecting));
      expect(states, isNot(contains(TaskState.completed)));
      expect(states, isNot(contains(TaskState.interrupted)));

      await recorder.stop();
      await runFuture;
      expect(states, isNot(contains(TaskState.completed)));
      expect(states, isNot(contains(TaskState.interrupted)));
    });

    test('读流 350ms 无新字节 → 看门狗主动断开并重连出新分段', () async {
      final Directory dir = await Directory.systemTemp.createTemp('flv_stall_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });

      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => server.close(force: true));

      var connections = 0;
      final StreamSubscription<HttpRequest> sub = server.listen((
        HttpRequest request,
      ) {
        connections++;
        unawaited(_sendAndHang(request).catchError((Object _) {}));
      });
      addTearDown(sub.cancel);

      final List<TaskState> states = <TaskState>[];
      final FlvRecorder recorder = FlvRecorder(
        room: _room(),
        outputDir: dir,
        urlProvider: () async => 'http://127.0.0.1:${server.port}/live.flv',
        reconnectPolicy: _fastPolicy(),
        stallTimeout: const Duration(milliseconds: 350),
        idleTimeout: const Duration(seconds: 10),
        onState: states.add,
      );

      final Future<void> runFuture = recorder.run();
      await _waitUntil(
        () => recorder.segments.length >= 2 && connections >= 2,
        reason: '看门狗没有触发重连',
      );
      expect(states, contains(TaskState.reconnecting));
      expect(states, isNot(contains(TaskState.completed)));

      await recorder.stop();
      await runFuture;
      expect(states, isNot(contains(TaskState.completed)));
    });

    test('持续数据跨过 1s 定时 flush：不因 bound stream 中断分段', () async {
      final Directory dir = await Directory.systemTemp.createTemp('flv_flush_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });

      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => server.close(force: true));
      final StreamSubscription<HttpRequest> sub = server.listen((
        HttpRequest request,
      ) {
        unawaited(_streamForAWhile(request).catchError((Object _) {}));
      });
      addTearDown(sub.cancel);

      final List<TaskState> states = <TaskState>[];
      final FlvRecorder recorder = FlvRecorder(
        room: _room(),
        outputDir: dir,
        urlProvider: () async => 'http://127.0.0.1:${server.port}/live.flv',
        reconnectPolicy: _fastPolicy(),
        stallTimeout: const Duration(seconds: 5),
        // 故意把 idle 设得比总发送时长（2s）短：只有每个 chunk 都滑动重置，
        // 才能保持同一分段；旧实现会 800ms 就 idle 断段。
        idleTimeout: const Duration(milliseconds: 800),
        onState: states.add,
      );

      final Future<void> runFuture = recorder.run();
      await _waitUntil(
        () => recorder.totalBytes >= 160 * 1024,
        reason: '2 秒内没有写入预期数据',
        timeout: const Duration(seconds: 5),
      );
      // 已跨过至少 1 次 1s 定时 flush；旧实现会在 1s 时抛
      // Bad state: StreamSink is bound to a stream 并进入 reconnecting。
      expect(recorder.segments.length, 1);
      expect(states, isNot(contains(TaskState.reconnecting)));
      expect(recorder.isRunning, isTrue);

      await recorder.stop();
      await runFuture;
    });
  });
}
