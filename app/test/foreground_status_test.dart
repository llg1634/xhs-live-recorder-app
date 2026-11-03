import 'package:flutter_test/flutter_test.dart';
import 'package:live_recorder/services/foreground_service.dart';

void main() {
  group('前台通知文案', () {
    test('单任务重连中：第 N 次 + 已录 X MB', () {
      ForegroundKeepAlive.updateStatus(
        const ForegroundStatus(
          reconnectingCount: 1,
          reconnectAttempt: 5,
          totalBytes: 12 * 1024 * 1024,
        ),
      );
      expect(ForegroundKeepAlive.titleFor(1), '直播录制 · 重连中');
      expect(ForegroundKeepAlive.textFor(1), '重连中（第 5 次）· 已录 12.0 MB');
    });

    test('超过 10 分钟：文案升级为网络异常，但仍然显示重试次数', () {
      ForegroundKeepAlive.updateStatus(
        const ForegroundStatus(
          reconnectingCount: 1,
          reconnectAttempt: 23,
          totalBytes: 800 * 1024 * 1024,
          longFailure: true,
        ),
      );
      expect(ForegroundKeepAlive.textFor(1), '网络异常，已重试 23 次· 已录 800 MB');
    });

    test('重连成功：恢复录制中文案', () {
      ForegroundKeepAlive.updateStatus(
        const ForegroundStatus(totalBytes: 5 * 1024 * 1024),
      );
      expect(ForegroundKeepAlive.titleFor(1), '正在录制 1 个直播间');
      expect(ForegroundKeepAlive.textFor(1), '录制中，息屏也会继续· 已录 5.0 MB');
    });

    test('多任务汇总：只显示重连任务数与最大尝试次数', () {
      ForegroundKeepAlive.updateStatus(
        const ForegroundStatus(
          reconnectingCount: 2,
          reconnectAttempt: 7,
          totalBytes: 3 * 1024 * 1024 * 1024,
        ),
      );
      expect(ForegroundKeepAlive.titleFor(3), '直播录制 · 3 个任务');
      expect(ForegroundKeepAlive.textFor(3), '2 个任务重连中（第 7 次）· 已录 3072 MB');
    });
  });
}
