import 'package:flutter_test/flutter_test.dart';
import 'package:live_recorder/models/live_room.dart';
import 'package:live_recorder/models/record_task.dart';

void main() {
  test('小红书 FLV 直链由房间号构造', () {
    const room = LiveRoom(
      platform: LivePlatform.xhs,
      roomId: '570501740524334550',
      pageUrl: 'https://www.xiaohongshu.com/livestream/570501740524334550',
      rawInput: '',
    );
    expect(room.flvUrl,
        'https://live-source-play.xhscdn.com/live/570501740524334550.flv');
    expect(room.displayName, '小红书 570501740524334550');
  });

  test('抖音房间不构造直链（需运行时解析签名地址）', () {
    const room = LiveRoom(
      platform: LivePlatform.douyin,
      roomId: '675247105586',
      pageUrl: 'https://live.douyin.com/675247105586',
      rawInput: '',
    );
    expect(room.flvUrl, isEmpty);
  });

  test('任务状态：只有录制/重连/解析算活跃', () {
    expect(TaskState.recording.isActive, isTrue);
    expect(TaskState.reconnecting.isActive, isTrue);
    expect(TaskState.resolving.isActive, isTrue);
    expect(TaskState.completed.isActive, isFalse);
    expect(TaskState.stopped.isActive, isFalse);
    expect(TaskState.error.isActive, isFalse);
  });
}
