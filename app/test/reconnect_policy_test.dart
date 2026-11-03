import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:live_recorder/services/flv_recorder.dart';

void main() {
  group('ReconnectPolicy 退避序列', () {
    test('2s→3s→5s→8s→13s→21s→30s 封顶，后续保持 30s', () {
      final ReconnectPolicy policy = ReconnectPolicy(jitterRatio: 0);
      final List<int> seconds = <int>[
        for (var attempt = 1; attempt <= 9; attempt++)
          policy.baseDelayFor(attempt).inSeconds,
      ];
      expect(seconds, <int>[2, 3, 5, 8, 13, 21, 30, 30, 30]);
    });

    test('抖动在基准 ±20% 范围内，且永不小于 1ms', () {
      final ReconnectPolicy policy = ReconnectPolicy(random: Random(20261103));
      for (var attempt = 1; attempt <= 20; attempt++) {
        final int base = policy.baseDelayFor(attempt).inMilliseconds;
        final int actual = policy.delayFor(attempt).inMilliseconds;
        expect(
          actual,
          inInclusiveRange((base * 0.8).floor() - 1, (base * 1.2).ceil() + 1),
          reason: 'attempt=$attempt base=${base}ms actual=${actual}ms',
        );
      }
    });

    test('第 0 次 / 负数次是非法参数', () {
      final ReconnectPolicy policy = ReconnectPolicy();
      expect(() => policy.baseDelayFor(0), throwsArgumentError);
      expect(() => policy.delayFor(-1), throwsArgumentError);
    });

    test('自定义快速序列（测试用）也遵守封顶', () {
      final ReconnectPolicy policy = ReconnectPolicy(
        baseDelays: const <Duration>[Duration(milliseconds: 20)],
        maxDelay: const Duration(milliseconds: 40),
        jitterRatio: 0,
      );
      expect(policy.baseDelayFor(1), const Duration(milliseconds: 20));
      expect(policy.baseDelayFor(2), const Duration(milliseconds: 40));
      expect(policy.baseDelayFor(99), const Duration(milliseconds: 40));
    });
  });

  group('错误分类：404 vs 瞬断', () {
    test('404/410 归为 liveEnded，5xx/403/429 归为 transient', () {
      expect(
        ReconnectPolicy.classifyStatus(HttpStatus.notFound),
        ReconnectErrorKind.liveEnded,
      );
      expect(
        ReconnectPolicy.classifyStatus(HttpStatus.gone),
        ReconnectErrorKind.liveEnded,
      );
      for (final int code in <int>[403, 408, 429, 500, 502, 503, 504]) {
        expect(
          ReconnectPolicy.classifyStatus(code),
          ReconnectErrorKind.transient,
          reason: 'HTTP $code 必须可重试',
        );
      }
      expect(
        ReconnectPolicy.classifyStatus(HttpStatus.ok),
        ReconnectErrorKind.none,
      );
    });

    test('SocketException / 超时 / 连接重置 / 提前 EOF 都是 transient', () {
      expect(
        ReconnectPolicy.classifyError(
          const SocketException('connection reset'),
        ),
        ReconnectErrorKind.transient,
      );
      expect(
        ReconnectPolicy.classifyError(TimeoutException('read timeout')),
        ReconnectErrorKind.transient,
      );
      expect(
        ReconnectPolicy.classifyError(
          const HttpException('Connection closed before full header'),
        ),
        ReconnectErrorKind.transient,
      );
      // 未知异常同样不能判定直播结束：必须继续重试。
      expect(
        ReconnectPolicy.classifyError(StateError('unexpected')),
        ReconnectErrorKind.transient,
      );
    });

    test('shouldStop 只认用户停止 / 确认直播结束', () {
      final ReconnectPolicy policy = ReconnectPolicy();
      expect(
        policy.shouldStop(userStopped: false, liveEndConfirmed: false),
        isFalse,
      );
      expect(
        policy.shouldStop(userStopped: true, liveEndConfirmed: false),
        isTrue,
      );
      expect(
        policy.shouldStop(userStopped: false, liveEndConfirmed: true),
        isTrue,
      );
    });
  });

  group('404 宽限判定', () {
    test('连续 404 必须同时满足 120s 与 12 次才判定直播结束', () {
      final LiveEndDetector detector = LiveEndDetector(
        grace: const Duration(seconds: 120),
        minAttempts: 12,
      );
      final DateTime start = DateTime(2026, 11, 3, 16, 30);
      for (var i = 0; i < 11; i++) {
        expect(
          detector.registerNotFound(start.add(Duration(seconds: i * 10))),
          isFalse,
          reason: '第 ${i + 1} 次 404 不能结束',
        );
      }
      // 第 12 次：次数够了，但只过了 110s，仍在宽限期内。
      expect(
        detector.registerNotFound(start.add(const Duration(seconds: 110))),
        isFalse,
      );
      // 时间也够了 → 确认直播结束。
      expect(
        detector.registerNotFound(start.add(const Duration(seconds: 120))),
        isTrue,
      );
    });

    test('中途恢复或出现非 404 错误会重置宽限计数', () {
      final LiveEndDetector detector = LiveEndDetector(
        grace: const Duration(seconds: 30),
        minAttempts: 3,
      );
      final DateTime start = DateTime(2026, 11, 3, 16, 30);
      expect(detector.registerNotFound(start), isFalse);
      expect(
        detector.registerNotFound(start.add(const Duration(seconds: 10))),
        isFalse,
      );
      detector.reset();
      expect(
        detector.registerNotFound(start.add(const Duration(seconds: 20))),
        isFalse,
      );
      expect(detector.consecutiveCount, 1);
    });
  });

  group('无限重试语义', () {
    test('任意多次瞬断都不应触发停止条件', () {
      final ReconnectPolicy policy = ReconnectPolicy(
        baseDelays: const <Duration>[Duration(milliseconds: 10)],
        maxDelay: const Duration(milliseconds: 10),
        jitterRatio: 0,
      );
      for (var attempt = 1; attempt <= 1000; attempt++) {
        expect(policy.delayFor(attempt).inMilliseconds, lessThanOrEqualTo(10));
        expect(
          policy.shouldStop(userStopped: false, liveEndConfirmed: false),
          isFalse,
        );
      }
    });

    test('长故障通知在 10 分钟后才升级', () {
      const ReconnectNotice early = ReconnectNotice(
        attempt: 5,
        failureDuration: Duration(minutes: 9, seconds: 59),
      );
      const ReconnectNotice late = ReconnectNotice(
        attempt: 20,
        failureDuration: Duration(minutes: 10),
      );
      expect(early.longFailure, isFalse);
      expect(late.longFailure, isTrue);
      expect(const ReconnectNotice.recovered().recovered, isTrue);
    });
  });
}
