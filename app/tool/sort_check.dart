// 录像排序自检：跨平台、按真实时间倒序。
// 运行：cd app && dart run tool/sort_check.dart
import 'dart:io';

import 'package:live_recorder/services/storage_service.dart';
import 'package:path/path.dart' as p;

Future<void> main() async {
  final root = Directory.systemTemp.createTempSync('sort_check');
  final names = [
    'xhs_111_20261020-232000',
    'douyin_222_20261021-001000',
    'xhs_333_20261019-100000',
    'douyin_444_nick_20261020-120000',
  ];
  for (final n in names) {
    Directory(p.join(root.path, n)).createSync();
  }

  final service = StorageService(preferredRoot: root.path);
  final list = await service.listSessions();
  for (final d in list) {
    stdout.writeln(p.basename(d.path));
  }
  final expected = [
    'douyin_222_20261021-001000',
    'xhs_111_20261020-232000',
    'douyin_444_nick_20261020-120000',
    'xhs_333_20261019-100000',
  ];
  final got = list.map((d) => p.basename(d.path)).toList();
  final ok = got.length == expected.length &&
      List.generate(got.length, (i) => got[i] == expected[i]).every((e) => e);
  stdout.writeln(ok ? 'SORT_OK' : 'SORT_FAIL');
  root.deleteSync(recursive: true);
}
