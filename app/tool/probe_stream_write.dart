// 诊断脚本：用 Dart HttpClient 直接拉 15 秒直播流写成 FLV，
// 用来判断「录出来的文件损坏」是网络层/解码层问题，还是写盘层问题。
//
// 用法: dart run tool/probe_stream_write.dart <url> <out.flv> [seconds]
import 'dart:async';
import 'dart:io';

Future<void> main(List<String> args) async {
  final String url = args.isNotEmpty
      ? args[0]
      : 'https://live-source-play.xhscdn.com/live/570527874005388546.flv';
  final String out = args.length > 1 ? args[1] : 'probe_out.flv';
  final int seconds = args.length > 2 ? int.parse(args[2]) : 15;

  final HttpClient client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..userAgent =
        'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

  final HttpClientRequest request = await client.getUrl(Uri.parse(url));
  request.headers.set(HttpHeaders.refererHeader, 'https://www.xiaohongshu.com/');
  request.headers.set(HttpHeaders.acceptHeader, '*/*');
  final HttpClientResponse response = await request.close();
  stdout.writeln('status=${response.statusCode} headers=${response.headers}');

  final IOSink sink = File(out).openWrite();
  int total = 0;
  final Completer<void> done = Completer<void>();
  late final StreamSubscription<List<int>> sub;
  sub = response.listen(
    (List<int> chunk) {
      sink.add(chunk);
      total += chunk.length;
      if (total > 40 * 1024 * 1024) {
        if (!done.isCompleted) done.complete();
      }
    },
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
    onError: (Object e) {
      stderr.writeln('stream error: $e');
      if (!done.isCompleted) done.complete();
    },
    cancelOnError: true,
  );

  Timer(const Duration(seconds: 15), () {
    if (!done.isCompleted) done.complete();
  });
  await done.future;
  await sub.cancel();
  client.close(force: true);
  await sink.flush();
  await sink.close();
  stdout.writeln('wrote $total bytes to $out');
}
