import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:live_recorder/models/live_room.dart';
import 'package:live_recorder/services/flv_recorder.dart';

/// 临时压测：40MB 高速写入，检查是否有字节丢失/乱序。
void main() {
  test('40MB 高速写入完整性', () async {
    final Directory dir = await Directory.systemTemp.createTemp('flv_big_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    const int total = 40 * 1024 * 1024;
    const int chunkSize = 64 * 1024;

    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => server.close(force: true));
    server.listen((HttpRequest request) async {
      final HttpResponse response = request.response;
      response.statusCode = 200;
      response.headers.contentType = ContentType.binary;
      response.bufferOutput = false;
      var sent = 0;
      var i = 0;
      while (sent < total) {
        final Uint8List chunk = Uint8List(chunkSize);
        // 每块写序号，便于定位错位
        for (var j = 0; j < chunkSize; j += 4) {
          chunk[j] = i & 0xff;
          chunk[j + 1] = (i >> 8) & 0xff;
          chunk[j + 2] = (i >> 16) & 0xff;
          chunk[j + 3] = (i >> 24) & 0xff;
        }
        response.add(chunk);
        sent += chunkSize;
        i++;
        if (i % 16 == 0) await response.flush();
      }
      await Future<void>.delayed(const Duration(seconds: 10));
    });

    final FlvRecorder recorder = FlvRecorder(
      room: const LiveRoom(
        platform: LivePlatform.xhs,
        roomId: '1',
        pageUrl: 'https://example.com',
        rawInput: 'x',
      ),
      outputDir: dir,
      urlProvider: () async => 'http://127.0.0.1:${server.port}/live.flv',
      stallTimeout: const Duration(seconds: 30),
      idleTimeout: const Duration(seconds: 30),
    );

    final Future<void> runFuture = recorder.run();
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 40));
    while (recorder.totalBytes < total) {
      if (DateTime.now().isAfter(deadline)) {
        fail('超时 totalBytes=${recorder.totalBytes}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await recorder.stop();
    await runFuture;

    final Uint8List data =
        await File(recorder.segments.first.path).readAsBytes();
    expect(data.length, total, reason: '长度不一致');
    // 每 4 字节是一个块序号，检查递增
    var bad = -1;
    for (var off = 0; off < total; off += chunkSize) {
      final int idx = data[off] |
          (data[off + 1] << 8) |
          (data[off + 2] << 16) |
          (data[off + 3] << 24);
      final int expect = off ~/ chunkSize;
      if (idx != expect) {
        bad = off;
        break;
      }
    }
    expect(bad, -1, reason: '块序号错位，首个错误 offset=$bad');
  });
}
