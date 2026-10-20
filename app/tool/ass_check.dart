// ASS/SRT 导出自检：node 无关，纯 Dart。
// 运行：cd app && dart run tool/ass_check.dart
import 'dart:convert';
import 'dart:io';

import 'package:live_recorder/services/ass_export.dart';

Future<void> main() async {
  final dir = Directory.systemTemp.createTempSync('ass_check');
  final start = DateTime(2026, 10, 20, 23, 0, 0).millisecondsSinceEpoch;

  final lines = <String>[];
  for (var i = 0; i < 5; i++) {
    lines.add(jsonEncode({
      'ts': start + 1500 + i * 2000,
      'user': 'momo',
      'text': '测试弹幕$i',
    }));
  }
  File('${dir.path}/comments.jsonl').writeAsStringSync('${lines.join('\n')}\n');

  final count = await AssExporter.export(
    outputDir: dir.path,
    startEpochMs: start,
  );
  stdout.writeln('exported=$count');
  final ass = File('${dir.path}/comments.ass').readAsStringSync();
  stdout.writeln(ass.split('\n').take(14).join('\n'));
  stdout.writeln('--- dialogue ---');
  for (final l in ass.split('\n').where((l) => l.startsWith('Dialogue'))) {
    stdout.writeln(l);
  }
  stdout.writeln('--- srt head ---');
  final srt = File('${dir.path}/comments.srt').readAsStringSync();
  stdout.writeln(srt.split('\n').take(6).join('\n'));
  dir.deleteSync(recursive: true);
}
