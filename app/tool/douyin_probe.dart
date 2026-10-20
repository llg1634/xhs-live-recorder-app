// 抖音分享页 → FLV 直链 的纯 Dart 探测（与应用内逻辑一致）。
// 运行：cd app && dart run tool/douyin_probe.dart <短链或reflow链接>
import 'dart:io';

import 'package:live_recorder/models/live_room.dart';
import 'package:live_recorder/services/douyin_resolver.dart';
import 'package:live_recorder/services/link_resolver.dart';

Future<void> main(List<String> args) async {
  final input = args.isNotEmpty
      ? args.first
      : 'https://v.douyin.com/86A8ex9zF0E/';
  final room = await LinkResolver().resolve(input);
  stdout.writeln('room: ${room.platform.key} ${room.roomId}');
  stdout.writeln('pageUrl: ${room.pageUrl}');

  final url = room.pageUrl.contains('/reflow/')
      ? await DouyinResolver().resolveFromReflow(room.roomId)
      : await DouyinResolver().resolveFlvUrl(room.roomId);
  stdout.writeln('flv len=${url.length}');
  stdout.writeln('flv: $url');

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0 (Linux; Android 13)');
    final resp = await req.close();
    stdout.writeln('pull status=${resp.statusCode} ctype=${resp.headers.contentType}');
    var got = 0;
    final first = <int>[];
    await for (final chunk in resp) {
      got += chunk.length;
      if (first.length < 8) first.addAll(chunk.take(8 - first.length));
      if (got >= 512 * 1024) break;
    }
    stdout.writeln('got=$got bytes, head=${first.take(3).toList()}');
    stdout.writeln('isFLV=${first.length >= 3 && first[0] == 0x46 && first[1] == 0x4C}');
  } finally {
    client.close(force: true);
  }
  // 打印 response 头里可能提示的跳转
  stdout.writeln('DONE');
  exit(0);
}
