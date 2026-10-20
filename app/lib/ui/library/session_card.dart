import 'package:flutter/material.dart';

import '../../theme/glass_tokens.dart';
import '../widgets/format_utils.dart';
import '../widgets/glass_button.dart';
import '../widgets/glass_pill.dart';
import '../widgets/glass_surface.dart';
import '../widgets/pressable.dart';
import 'session_info.dart';

/// 录像卡片：目录名/大小/分段列表/时间，点击展开，滑出或长按删除。
class SessionCard extends StatelessWidget {
  const SessionCard({
    super.key,
    required this.session,
    required this.expanded,
    required this.onToggle,
    required this.onLongPress,
    required this.onPlaySegment,
    this.onDelete,
  });

  final SessionInfo session;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback? onLongPress;
  final void Function(SessionSegment segment, int index) onPlaySegment;
  final VoidCallback? onDelete;

  Color _tone(GlassColors c) => switch (session.platformKey) {
    'xhs' => c.accent,
    'douyin' => c.cyan,
    _ => c.accentAlt,
  };

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    final Color tone = _tone(c);
    final String sizeText = session.bytes == null
        ? '计算中…'
        : formatBytes(session.bytes!);
    final String meta =
        '${formatClock(session.startedAt)} · $sizeText · ${session.segmentCount} 段'
        '${session.comments > 0 ? ' · 弹幕 ${session.comments} 条' : ''}';

    return GlassSurface(
      radius: GlassTokens.radiusCard,
      blur: GlassTokens.blur,
      padding: EdgeInsets.fromLTRB(14, 13, 12, expanded ? 8 : 13),
      tint: expanded ? tone : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Pressable(
            onTap: onToggle,
            onLongPress: onLongPress,
            behavior: HitTestBehavior.opaque,
            child: Row(
              children: <Widget>[
                GlassBadge(
                  icon: session.platformKey == 'douyin'
                      ? Icons.music_note_rounded
                      : Icons.video_file_rounded,
                  color: tone,
                  size: 42,
                  radius: 13,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Flexible(
                            child: Text(
                              session.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GlassText.title(c)
                                  .copyWith(fontSize: 15.5),
                            ),
                          ),
                          const SizedBox(width: 7),
                          GlassPill(
                            label: session.platformLabel,
                            color: tone,
                            dense: true,
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GlassText.caption(
                          c,
                          color: c.textSecondary,
                        ).copyWith(fontSize: 11.5),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                AnimatedRotation(
                  turns: expanded ? 0.5 : 0,
                  duration: GlassTokens.medium,
                  curve: GlassTokens.easeOut,
                  child: Icon(
                    Icons.expand_more_rounded,
                    size: 20,
                    color: c.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          AnimatedSize(
            duration: GlassTokens.medium,
            curve: GlassTokens.easeOut,
            alignment: Alignment.topCenter,
            child: expanded
                ? _ExpandedBody(
                    session: session,
                    tone: tone,
                    onPlaySegment: onPlaySegment,
                    onDelete: onDelete,
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

class _ExpandedBody extends StatelessWidget {
  const _ExpandedBody({
    required this.session,
    required this.tone,
    required this.onPlaySegment,
    required this.onDelete,
  });

  final SessionInfo session;
  final Color tone;
  final void Function(SessionSegment segment, int index) onPlaySegment;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    final List<SessionSegment>? segments = session.segments;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const SizedBox(height: 12),
        const GlassDivider(),
        const SizedBox(height: 4),
        if (segments == null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(tone),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '正在读取分段…',
                  style: GlassText.caption(
                    c,
                    color: c.textSecondary,
                  ).copyWith(fontSize: 12),
                ),
              ],
            ),
          )
        else if (segments.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              '目录里没有 flv 分段文件',
              style: GlassText.caption(
                c,
                color: c.textTertiary,
              ).copyWith(fontSize: 12),
            ),
          )
        else
          for (int i = 0; i < segments.length; i++)
            _SegmentRow(
              index: i,
              segment: segments[i],
              tone: tone,
              onTap: () => onPlaySegment(segments[i], i),
            ),
        if (onDelete != null)
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 2),
            child: Row(
              children: <Widget>[
                const Spacer(),
                GlassTextButton(
                  label: '删除本次录像',
                  icon: Icons.delete_outline_rounded,
                  color: c.danger,
                  onPressed: onDelete,
                ),
              ],
            ),
          ),
        const SizedBox(height: 2),
      ],
    );
  }
}

class _SegmentRow extends StatelessWidget {
  const _SegmentRow({
    required this.index,
    required this.segment,
    required this.tone,
    required this.onTap,
  });

  final int index;
  final SessionSegment segment;
  final Color tone;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    return Pressable(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: <Widget>[
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: tone.withValues(alpha: c.isDark ? 0.14 : 0.1),
                border: Border.all(color: tone.withValues(alpha: 0.28)),
              ),
              child: Text(
                '${index + 1}'.padLeft(2, '0'),
                style: GlassText.numeric(c, size: 10.5, color: tone),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '分段 ${index + 1}',
                    style: GlassText.label(c).copyWith(fontSize: 13),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'FLV · ${formatBytes(segment.bytes)}',
                    style: GlassText.micro(
                      c,
                      color: c.textTertiary,
                    ).copyWith(fontSize: 10.5),
                  ),
                ],
              ),
            ),
            Icon(Icons.play_circle_outline_rounded, size: 20, color: tone),
          ],
        ),
      ),
    );
  }
}
