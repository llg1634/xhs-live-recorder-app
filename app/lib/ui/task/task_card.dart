import 'package:flutter/material.dart';

import '../../models/live_room.dart';
import '../../models/record_task.dart';
import '../../theme/glass_tokens.dart';
import '../widgets/feedback.dart';
import '../widgets/format_utils.dart';
import '../widgets/glass_button.dart';
import '../widgets/glass_pill.dart';
import '../widgets/glass_surface.dart';
import '../widgets/pressable.dart';
import '../widgets/signal_bar.dart';
import '../widgets/status_dot.dart';

/// 录制任务状态对应的主题色。
Color taskStateColor(GlassColors c, TaskState state) => switch (state) {
  TaskState.resolving => c.cyan,
  TaskState.recording => c.accent,
  TaskState.reconnecting => c.warning,
  TaskState.completed => c.success,
  TaskState.stopped => c.textTertiary,
  TaskState.error => c.danger,
};

/// 任务卡片：主播/标题、平台、状态、实时体积与速率、分段数、重试次数、停止按钮。
class TaskCard extends StatelessWidget {
  const TaskCard({
    super.key,
    required this.task,
    this.onTap,
    this.onLongPress,
    this.onStop,
    this.onPreview,
  });

  final RecordTask task;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onStop;

  /// 「预览」/「回放」按钮：录制中走实时预览，结束后走最近一段录像。
  final VoidCallback? onPreview;

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    final TaskState state = task.state;
    final Color tone = taskStateColor(c, state);
    final bool active = task.isActive;
    final LivePlatform? platform = task.room?.platform;
    final Color platformColor = switch (platform) {
      LivePlatform.xhs => c.accent,
      LivePlatform.douyin => c.cyan,
      null => c.textTertiary,
    };

    final Color? tint = switch (state) {
      TaskState.recording => c.accent,
      TaskState.error => c.danger,
      _ => null,
    };

    final bool pulsing =
        state == TaskState.recording ||
        state == TaskState.reconnecting ||
        state == TaskState.resolving;

    return GlassCard(
      margin: const EdgeInsets.only(bottom: GlassTokens.gap),
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
      tint: tint,
      semanticLabel: '${task.title}，${task.state.label}',
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              GlassPill(
                label: task.platformLabel,
                color: platformColor,
                dense: true,
              ),
              const SizedBox(width: 6),
              GlassPill(
                label: state.label,
                color: tone,
                dense: true,
                leading: BreathingDot(color: tone, size: 6, active: pulsing),
              ),
              const Spacer(),
              if (active && onStop != null)
                GlassIconButton(
                  icon: Icons.stop_rounded,
                  size: 34,
                  iconSize: 17,
                  color: c.danger,
                  tint: c.danger,
                  semanticLabel: '停止录制',
                  onPressed: onStop,
                )
              else
                Icon(
                  Icons.chevron_right_rounded,
                  size: 19,
                  color: c.textTertiary,
                ),
            ],
          ),
          const SizedBox(height: 11),
          Text(
            task.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GlassText.title(c).copyWith(fontSize: 17.5),
          ),
          const SizedBox(height: 5),
          Text(
            _subtitle(),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: GlassText.caption(
              c,
              color: c.textSecondary,
            ).copyWith(fontSize: 12),
          ),
          if (state == TaskState.error &&
              (task.errorMessage?.isNotEmpty ?? false))
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: _ErrorBox(message: task.errorMessage!),
            ),
          const SizedBox(height: 13),
          _MetricsRow(task: task, tone: tone, active: active),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: SignalBar(
                  color: tone,
                  active: active && state != TaskState.resolving,
                  height: 3,
                ),
              ),
              const SizedBox(width: 10),
              if (_canPreview)
                _PreviewPill(
                  label: task.isActive ? '预览直播' : '回放',
                  icon: task.isActive
                      ? Icons.play_circle_fill_rounded
                      : Icons.history_rounded,
                  tone: tone,
                  onTap: onPreview,
                )
              else
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      _footerLabel(),
                      style: GlassText.micro(
                        c,
                        color: c.textTertiary,
                      ).copyWith(fontSize: 10.5),
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      Icons.play_circle_outline_rounded,
                      size: 14,
                      color: c.textTertiary,
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _subtitle() {
    final LiveRoom? room = task.room;
    final String? roomPart = room == null
        ? null
        : '房间 ${shortRoomId(room.roomId)}';
    final String? commentPart = _commentPart();
    switch (task.state) {
      case TaskState.resolving:
        return '正在解析直播链接…';
      case TaskState.recording:
        return <String>[
          ?roomPart,
          '已录 ${formatDuration(task.elapsed)}',
          ?commentPart,
        ].join(' · ');
      case TaskState.reconnecting:
        return <String>[
          '断流重连中（第 ${task.retryCount} 次探测）',
          ?roomPart,
          ?commentPart,
        ].join(' · ');
      case TaskState.completed:
        return <String>[
          '直播结束',
          '共 ${task.segmentCount} 段',
          formatBytes(task.totalBytes),
          ?commentPart,
        ].join(' · ');
      case TaskState.stopped:
        return <String>[
          '已停止',
          '共 ${task.segmentCount} 段',
          formatBytes(task.totalBytes),
          ?commentPart,
        ].join(' · ');
      case TaskState.error:
        return <String>['录制出错', ?roomPart].join(' · ');
    }
  }

  /// 弹幕状态文案：未开启不显示；开启后显示条数或异常。
  String? _commentPart() {
    if (!task.commentsEnabled) return null;
    if (task.commentCount < 0) return '弹幕采集失败';
    if (task.commentCount == 0) {
      return task.isActive ? '弹幕连接中' : '弹幕 0 条';
    }
    return '弹幕 ${task.commentCount} 条';
  }

  /// 是否可预览：录制中走实时流；结束后有分段则可回放。
  bool get _canPreview {
    if (onPreview == null) return false;
    if (task.state == TaskState.resolving) return false;
    if (task.isActive) return true;
    return task.segments.isNotEmpty;
  }

  String _footerLabel() {
    if (task.state == TaskState.resolving) return '解析中…';
    return '暂无可用录像';
  }
}

/// 出错原因：完整显示，可一键复制。
class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 9, 5, 9),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(GlassTokens.radiusSm),
        color: c.danger.withValues(alpha: c.isDark ? 0.12 : 0.07),
        border: Border.all(
          color: c.danger.withValues(alpha: c.isDark ? 0.34 : 0.26),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(Icons.error_outline_rounded, size: 15, color: c.danger),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              message,
              style: GlassText.caption(
                c,
                color: c.danger,
              ).copyWith(fontSize: 12, height: 1.45),
            ),
          ),
          const SizedBox(width: 2),
          Pressable(
            onTap: () => copyToClipboard(context, message),
            child: Padding(
              padding: const EdgeInsets.all(5),
              child: Icon(Icons.copy_rounded, size: 14, color: c.danger),
            ),
          ),
        ],
      ),
    );
  }
}

/// 卡片右下角的预览/回放按钮（录制中始终可见，强调"边录边看"）。
class _PreviewPill extends StatelessWidget {
  const _PreviewPill({
    required this.label,
    required this.icon,
    required this.tone,
    this.onTap,
  });

  final String label;
  final IconData icon;
  final Color tone;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    return Pressable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(GlassTokens.radiusPill),
          color: tone.withValues(alpha: c.isDark ? 0.16 : 0.1),
          border: Border.all(
            color: tone.withValues(alpha: c.isDark ? 0.46 : 0.32),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 13, color: tone),
            const SizedBox(width: 4),
            Text(
              label,
              style: GlassText.micro(
                c,
                color: tone,
              ).copyWith(fontSize: 10.5, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricsRow extends StatelessWidget {
  const _MetricsRow({
    required this.task,
    required this.tone,
    required this.active,
  });

  final RecordTask task;
  final Color tone;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    final Widget divider = Container(width: 1, height: 26, color: c.divider);
    return Row(
      children: <Widget>[
        Expanded(
          child: _Metric(
            label: active ? '实时体积' : '总体积',
            value: formatBytes(task.totalBytes),
            highlight: active,
            tone: tone,
          ),
        ),
        divider,
        Expanded(
          child: _Metric(
            label: '速率',
            value: formatRate(task.bytesPerSecond),
            highlight: active,
            tone: tone,
          ),
        ),
        divider,
        Expanded(
          child: _Metric(label: '分段数', value: '${task.segmentCount}'),
        ),
        divider,
        Expanded(
          child: _Metric(
            label: '重试',
            value: '${task.retryCount}',
            highlight: task.retryCount > 0,
            tone: c.warning,
          ),
        ),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    this.highlight = false,
    this.tone,
  });

  final String label;
  final String value;
  final bool highlight;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GlassText.micro(
            c,
            color: c.textTertiary,
          ).copyWith(fontSize: 10.5),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GlassText.numeric(
            c,
            size: 13.5,
            color: highlight && tone != null ? tone : c.textPrimary,
          ),
        ),
      ],
    );
  }
}
