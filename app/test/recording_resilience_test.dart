import 'package:flutter_test/flutter_test.dart';
import 'package:live_recorder/models/record_task.dart';
import 'package:live_recorder/services/flv_recorder.dart';

void main() {
  group('分段号推导（防止覆盖已录内容）', () {
    test('磁盘上已有 part01..part03 时，下一个分段从 part04 开始', () {
      expect(
        FlvRecorder.nextIndexFor(<String>[
          '/rec/part01.flv',
          '/rec/part02.flv',
          '/rec/part03.flv',
        ]),
        4,
      );
    });

    test('内存里的分段数比磁盘多时取较大值', () {
      expect(
        FlvRecorder.nextIndexFor(<String>['/rec/part01.flv'], fallbackCount: 5),
        6,
      );
    });

    test('忽略非分段文件（session.json / comments.jsonl）', () {
      expect(
        FlvRecorder.nextIndexFor(<String>[
          '/rec/session.json',
          '/rec/comments.jsonl',
          '/rec/part02.flv',
        ]),
        3,
      );
    });

    test('part 序号解析与大小写兼容', () {
      expect(FlvRecorder.segmentIndexFromPath('/rec/part12.flv'), 12);
      expect(FlvRecorder.segmentIndexFromPath('/rec/part01.FLV'), 1);
      expect(FlvRecorder.segmentIndexFromPath('/rec/comments.jsonl'), isNull);
    });

    test('空目录从 part01 开始', () {
      expect(FlvRecorder.nextIndexFor(const <String>[]), 1);
    });
  });

  group('session.json 恢复字段', () {
    test('ownerPid / savedAt 能往返（跨 isolate 判活依据）', () {
      final RecordTask task =
          RecordTask(id: 't1', rawInput: 'https://example.com/live');
      task.outputDir = '/rec/xhs_1_20261020-190000';
      task.state = TaskState.recording;
      task.ownerPid = 4242;

      final Map<String, dynamic> json = <String, dynamic>{
        ...task.toJson(),
        'savedAt': DateTime.now().toIso8601String(),
        'ownerPid': 4242,
      };
      final RecordTask restored = RecordTask.fromJson(json);

      expect(restored.ownerPid, 4242);
      expect(restored.savedAt, isNotNull);
      expect(restored.state, TaskState.recording);
      expect(restored.externalOwner, isFalse);
    });
  });
}
