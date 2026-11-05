import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:live_recorder/models/live_room.dart';
import 'package:live_recorder/services/flv_recorder.dart';

/// 回归：写盘顺序必须与收到的字节顺序完全一致。
///
/// 背景：v1.0.1 曾用 `_SegmentSink` 在 flush 期间缓存数据、flush 结束后直接写新
/// 数据，导致被缓存的旧字节晚于新字节落盘 —— FLV 从某一刻起解析错位，App 内
/// 回放只能放前几秒。这个测试用「每块内容都不同」的数据流跨过多次 1 秒 flush，
/// 逐字节比对结果。
void main() {
  test('持续写入跨多次 flush：文件内容必须与收到的字节流完全一致', () async {
    final Directory dir = await Directory.systemTemp.createTemp('flv_order_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    const int chunkCount = 16;
    const int chunkSize = 16 * 1024;
    final List<Uint8List> sent = <Uint8List>[];

    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => server.close(force: true));

    final StreamSubscription<HttpRequest> sub = server.listen((
      HttpRequest request,
    ) async {
      final HttpResponse response = request.response;
      response.statusCode = HttpStatus.ok;
      response.headers.contentType = ContentType.binary;
      response.bufferOutput = false;
      for (var i = 0; i < chunkCount; i++) {
        // 每一块的每个字节都取不同的值（i+1），顺序错了立刻能看出来。
        final Uint8List chunk = Uint8List(chunkSize)
          ..fillRange(0, chunkSize, i + 1);
        sent.add(chunk);
        response.add(chunk);
        await response.flush();
        // 150ms × 16 = 2.4s，必然跨过两次以上的 1 秒定时 flush。
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      // 不关闭：保持连接，避免 recorder 判定 EOF 后重连出 part02。
      await Future<void>.delayed(const Duration(seconds: 20));
    });
    addTearDown(sub.cancel);

    final FlvRecorder recorder = FlvRecorder(
      room: const LiveRoom(
        platform: LivePlatform.xhs,
        roomId: '570523767964339555',
        pageUrl: 'https://www.xiaohongshu.com/livestream/570523767964339555',
        rawInput: 'https://www.xiaohongshu.com/livestream/570523767964339555',
        title: '顺序测试',
      ),
      outputDir: dir,
      urlProvider: () async => 'http://127.0.0.1:${server.port}/live.flv',
      stallTimeout: const Duration(seconds: 30),
      idleTimeout: const Duration(seconds: 30),
    );

    final Future<void> runFuture = recorder.run();
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 15));
    while (recorder.totalBytes < chunkCount * chunkSize) {
      if (DateTime.now().isAfter(deadline)) {
        fail('等待写入超时：totalBytes=${recorder.totalBytes}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await recorder.stop();
    await runFuture;

    expect(recorder.segments, hasLength(1), reason: '整段应保持在一个分段里');
    final Uint8List written =
        await File(recorder.segments.first.path).readAsBytes();

    expect(
      written.length,
      chunkCount * chunkSize,
      reason: '文件长度必须等于收到的字节数（不能丢块/重复）',
    );

    var offset = 0;
    for (var i = 0; i < sent.length; i++) {
      final Uint8List expected = sent[i];
      final Uint8List actual = written.sublist(offset, offset + chunkSize);
      // 只比较首尾各 64 字节即可定位顺序问题，同时避免大数组 equals 的开销。
      expect(
        actual.sublist(0, 64),
        equals(expected.sublist(0, 64)),
        reason: '第 $i 块开头顺序错误（offset=$offset）',
      );
      expect(
        actual.sublist(chunkSize - 64),
        equals(expected.sublist(chunkSize - 64)),
        reason: '第 $i 块结尾顺序错误（offset=$offset）',
      );
      offset += chunkSize;
    }
  });
}
