import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';

import '../../models/record_task.dart';
import '../../services/local_server.dart';
import '../../services/recording_manager.dart';
import '../../theme/glass_tokens.dart';
import '../preview/live_preview_page.dart';
import '../widgets/empty_state.dart';
import '../widgets/feedback.dart';
import '../widgets/glass_button.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/glass_page_route.dart';
import '../widgets/glass_pill.dart';
import 'record_composer.dart';
import 'task_card.dart';

/// 「录制」页：大标题 + 输入区 + 开始录制 + 任务卡片列表 + 空态。
class RecordPage extends StatelessWidget {
  const RecordPage({super.key});

  @override
  Widget build(BuildContext context) {
    final RecordingManager manager = context.watch<RecordingManager>();
    final List<RecordTask> tasks = manager.tasks;
    final int active = manager.activeCount;
    // 真正在录的（含断流探测中）才叫「录制中」，解析中/已结束/出错都不算，避免计数跳动。
    final int recordingCount = tasks
        .where(
          (RecordTask t) =>
              t.state == TaskState.recording ||
              t.state == TaskState.reconnecting,
        )
        .length;
    final GlassColors c = GlassColors.of(context);

    return CustomScrollView(
      key: const PageStorageKey<String>('record-scroll'),
      scrollCacheExtent: const ScrollCacheExtent.pixels(320),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            GlassTokens.pagePadding,
            10,
            GlassTokens.pagePadding,
            0,
          ),
          sliver: SliverToBoxAdapter(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: GlassTokens.maxContentWidth,
                ),
                child: GlassPageHeader(
                  title: '直播录制',
                  subtitle: '小红书 / 抖音 · 粘贴链接即可开录',
                  compact: true,
                  leading: const GlassBadge(
                    icon: Icons.videocam_rounded,
                    size: 44,
                    radius: 14,
                    gradient: true,
                  ),
                  trailing: recordingCount > 0
                      ? GlassPill(
                          label: '录制中 $recordingCount',
                          icon: Icons.sensors_rounded,
                          dense: true,
                          color: c.accent,
                        )
                      : null,
                ),
              ),
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            GlassTokens.pagePadding,
            18,
            GlassTokens.pagePadding,
            0,
          ),
          sliver: SliverToBoxAdapter(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: GlassTokens.maxContentWidth,
                ),
                child: RecordComposer(
                  activeCount: active,
                  maxConcurrent: manager.maxConcurrentTasks,
                  onStart: (String raw, bool withComments) =>
                      _startTask(context, raw, withComments: withComments),
                ),
              ),
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            GlassTokens.pagePadding,
            22,
            GlassTokens.pagePadding,
            10,
          ),
          sliver: SliverToBoxAdapter(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: GlassTokens.maxContentWidth,
                ),
                child: GlassSectionHeader(
                  title: tasks.isEmpty ? '录制任务' : '录制任务 · ${tasks.length}',
                  trailing: active > 0
                      ? GlassTextButton(
                          label: '全部停止',
                          icon: Icons.stop_circle_outlined,
                          color: c.danger,
                          onPressed: () => _stopAll(context),
                        )
                      : null,
                ),
              ),
            ),
          ),
        ),
        if (tasks.isEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              GlassTokens.pagePadding,
              12,
              GlassTokens.pagePadding,
              0,
            ),
            sliver: SliverToBoxAdapter(
              child: GlassEmptyState(
                title: '还没有录制任务',
                message:
                    '把小红书直播的分享链接或整段文案粘贴到上方，'
                    '点「开始录制」，录像会自动分段保存到本地。',
                steps: <String>[
                  '复制直播间的分享链接或整段文案',
                  '回到这里点「粘贴」，再点「开始录制」',
                  '录制中点击任务卡片可实时预览',
                ],
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(
              horizontal: GlassTokens.pagePadding,
            ),
            sliver: SliverList.builder(
              itemCount: tasks.length,
              itemBuilder: (BuildContext context, int index) {
                final RecordTask task = tasks[index];
                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: GlassTokens.maxContentWidth,
                    ),
                    child: RepaintBoundary(
                      child: _AnimatedEntry(
                        key: ValueKey<String>(task.id),
                        index: index,
                        child: TaskCard(
                          task: task,
                          onTap: () => _openTask(context, task),
                          onPreview: () => _openTask(context, task),
                          onLongPress: () => _showTaskActions(context, task),
                          onStop: () => _stopTask(context, task),
                          onResume: () => _resumeTask(context, task),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        SliverPadding(
          padding: EdgeInsets.only(
            bottom: GlassTokens.pageBottomInset(context),
          ),
        ),
      ],
    );
  }

  Future<String?> _startTask(
    BuildContext context,
    String raw, {
    bool withComments = false,
  }) async {
    final RecordingManager manager = context.read<RecordingManager>();
    try {
      await manager.startTask(raw, withComments: withComments);
      if (context.mounted) {
        showGlassSnack(
          context,
          withComments ? '已开始录制（含弹幕采集），正在解析链接' : '已开始录制，正在解析直播链接',
        );
      }
      return null;
    } on StateError catch (e) {
      return e.message;
    } catch (e) {
      return '开始录制失败：${e.toString().replaceFirst('Exception: ', '')}';
    }
  }

  Future<void> _stopTask(BuildContext context, RecordTask task) async {
    final RecordingManager manager = context.read<RecordingManager>();
    await manager.stopTask(task.id);
    if (context.mounted) {
      showGlassSnack(context, '已停止「${task.title}」');
    }
  }

  Future<void> _stopAll(BuildContext context) async {
    final RecordingManager manager = context.read<RecordingManager>();
    await manager.stopAll();
    if (context.mounted) {
      showGlassSnack(context, '已停止全部录制任务');
    }
  }

  /// 继续一个被中断的任务：沿用原目录，分段号接着排。
  Future<void> _resumeTask(BuildContext context, RecordTask task) async {
    final RecordingManager manager = context.read<RecordingManager>();
    try {
      await manager.resumeTask(task.id);
      if (context.mounted) {
        showGlassSnack(context, '继续录制「${task.title}」');
      }
    } catch (e) {
      if (context.mounted) {
        showGlassSnack(context, '继续失败：${e.toString().replaceFirst('Bad state: ', '')}');
      }
    }
  }

  void _openTask(BuildContext context, RecordTask task) {
    final LocalStreamServer server = context.read<LocalStreamServer>();
    if (task.state == TaskState.resolving) {
      showGlassSnack(context, '正在解析直播链接，请稍候再预览');
      return;
    }
    String? url;
    if (task.isActive) {
      url = server.playerUrlForLive(task.id);
    } else if (task.segments.isNotEmpty) {
      url = server.playerUrlForFile(task.segments.last.path);
    }
    if (url == null) {
      final String message = task.state == TaskState.error
          ? (task.errorMessage ?? '录制出错，暂无可用录像')
          : '这个任务没有可播放的录像';
      showGlassSnack(context, message, error: true);
      return;
    }
    Navigator.of(context).push<void>(
      glassPageRoute<void>(
        context,
        page: LivePreviewPage(title: task.title, url: url),
      ),
    );
  }

  Future<void> _showTaskActions(BuildContext context, RecordTask task) async {
    final RecordingManager manager = context.read<RecordingManager>();
    final List<GlassAction> actions = <GlassAction>[
      if (task.isActive)
        const GlassAction(
          value: 'stop',
          label: '停止录制',
          icon: Icons.stop_circle_outlined,
          destructive: true,
        ),
      if (task.segments.isNotEmpty)
        const GlassAction(
          value: 'replay',
          label: '回放最后一段',
          icon: Icons.play_circle_outline_rounded,
        ),
      if (!task.isActive)
        const GlassAction(
          value: 'remove',
          label: '移除任务记录',
          icon: Icons.delete_outline_rounded,
          destructive: true,
        ),
    ];
    if (actions.isEmpty) return;
    final String? choice = await showGlassActionSheet(
      context,
      title: task.title,
      subtitle: '${task.platformLabel} · ${task.state.label}',
      actions: actions,
    );
    if (choice == null || !context.mounted) return;
    switch (choice) {
      case 'stop':
        await _stopTask(context, task);
      case 'replay':
        _openTask(context, task);
      case 'remove':
        manager.removeTask(task.id);
        if (context.mounted) {
          showGlassSnack(context, '已移除任务记录（录像文件仍保留在本地）');
        }
    }
  }
}

/// 列表项入场：淡入 + 轻微上移，最多错峰 6 项。
class _AnimatedEntry extends StatelessWidget {
  const _AnimatedEntry({super.key, required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    final int stagger = index.clamp(0, 6);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: Duration(milliseconds: 300 + stagger * 45),
      curve: Curves.easeOutCubic,
      builder: (BuildContext context, double value, Widget? child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, (1 - value) * 12),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}
