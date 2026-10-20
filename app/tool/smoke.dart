// 核心引擎离线冒烟测试（纯 Dart，不依赖 Flutter 运行时）。
// 运行：cd app && dart run tool/smoke.dart
import 'dart:async';
import 'dart:io';

import 'package:live_recorder/models/live_room.dart';
import 'package:live_recorder/services/douyin_resolver.dart';
import 'package:live_recorder/services/flv_recorder.dart';
import 'package:live_recorder/services/link_resolver.dart';

Future<void> main(List<String> args) async {
  final seconds = args.isNotEmpty ? int.tryParse(args[0]) ?? 12 : 12;
  final input = args.length > 1
      ? args[1]
      : '小红书，你的生活指南#第五人格赛事正在直播，来和我一起支持ta吧。 '
          'https://xhslink.com/o/9iND1710iyA 复制本条信息，打开【小红书】，直接观看直播！';

  stdout.writeln('== 1. 解析分享文案 ==');
  stdout.writeln('input: $input');
  final room = await LinkResolver().resolve(input);
  stdout.writeln('room: ${room.platform.label} roomId=${room.roomId}');
  stdout.writeln('title: ${room.title} | anchor: ${room.anchorName}');
  stdout.writeln('pageUrl: ${room.pageUrl}');
  stdout.writeln('flvUrl: ${room.flvUrl}');

  String url = room.flvUrl;
  if (room.platform == LivePlatform.douyin) {
    stdout.writeln('== 抖音：解析真实签名直链 ==');
    final dy = DouyinResolver();
    url = room.pageUrl.contains('/reflow/')
        ? await dy.resolveFromReflow(room.roomId)
        : await dy.resolveFlvUrl(room.roomId);
    stdout.writeln('douyin flv: ${url.substring(0, url.length.clamp(0, 140))}...');
  }

  final dir = Directory('smoke_out');
  if (await dir.exists()) await dir.delete(recursive: true);
  await dir.create(recursive: true);

  stdout.writeln('== 2. 录制 $seconds 秒 ==');
  var endState = '';
  final recorder = FlvRecorder(
    room: room,
    outputDir: dir,
    urlProvider: () async => url,
    referer: room.platform == LivePlatform.xhs
        ? 'https://www.xiaohongshu.com/'
        : 'https://live.douyin.com/',
    onState: (s) {
      endState = s.name;
      stdout.writeln('  [state] ${s.name}');
    },
    onSegment: (seg, finished) {
      stdout.writeln('  [segment${finished ? ' end' : ''}] '
          '${seg.path} ${seg.bytes}B');
    },
    onProgress: (bytes, bps) {
      stdout.writeln('  [progress] ${(bytes / 1024 / 1024).toStringAsFixed(2)}MB '
          '${(bps / 1024).toStringAsFixed(0)}KB/s');
    },
  );

  final timer = Timer(Duration(seconds: seconds), () {
    stdout.writeln('  [stop] 主动停止');
    recorder.stop();
  });
  await recorder.run();
  timer.cancel();

  stdout.writeln('== 3. 校验产物 ==');
  stdout.writeln('end state: $endState, retries=${recorder.retryCount}');
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.flv'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in files) {
    final len = f.lengthSync();
    final head = f.openSync().readSync(3);
    final isFlv = head.length >= 3 &&
        head[0] == 0x46 &&
        head[1] == 0x4C &&
        head[2] == 0x56;
    stdout.writeln(
        '  ${f.path} ${(len / 1024 / 1024).toStringAsFixed(2)}MB FLV=${isFlv}');
  }
  if (files.isEmpty) {
    stderr.writeln('!! 没有产出 FLV 文件');
    exitCode = 1;
  }
}
