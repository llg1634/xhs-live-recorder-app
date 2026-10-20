import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/local_server.dart';
import '../../services/storage_service.dart';
import '../../theme/glass_tokens.dart';
import '../preview/live_preview_page.dart';
import '../widgets/empty_state.dart';
import '../widgets/feedback.dart';
import '../widgets/format_utils.dart';
import '../widgets/glass_button.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/glass_page_route.dart';
import '../widgets/glass_pill.dart';
import '../widgets/glass_surface.dart';
import '../widgets/storage_root_cache.dart';
import 'session_card.dart';
import 'session_info.dart';

/// 「录像」页：扫描存储目录，展示目录名 / 大小 / 分段列表 / 时间；
/// 点击分段回放，长按或左滑删除（二次确认）。
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, this.active = true});

  final bool active;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final List<SessionInfo> _sessions = <SessionInfo>[];
  bool _loading = true;
  String? _error;
  String? _expandedPath;
  int _generation = 0;
  DateTime? _lastLoaded;

  @override
  void initState() {
    super.initState();
    if (widget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  @override
  void didUpdateWidget(LibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active &&
        !oldWidget.active &&
        DateTime.now().difference(_lastLoaded ?? DateTime(1970)) >
            const Duration(seconds: 2)) {
      _load(silent: true);
    }
  }

  Future<void> _load({bool silent = false, bool retryRoot = false}) async {
    final StorageService storage = context.read<StorageService>();
    final int generation = ++_generation;
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      await StorageRootCache.resolve(storage, retry: retryRoot);
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = '没有可写的录像目录：$e';
      });
      return;
    }
    final List<Directory> dirs = await storage.listSessions();
    if (!mounted || generation != _generation) return;
    final List<SessionInfo> sessions = dirs
        .map(SessionInfo.fromDirectory)
        .toList();
    setState(() {
      _sessions
        ..clear()
        ..addAll(sessions);
      _loading = false;
      _error = null;
      _lastLoaded = DateTime.now();
      if (_expandedPath != null &&
          !_sessions.any((SessionInfo s) => s.dir.path == _expandedPath)) {
        _expandedPath = null;
      }
    });

    for (final SessionInfo session in sessions) {
      if (!mounted || generation != _generation) return;
      await _enrich(storage, session, generation);
    }
  }

  Future<void> _enrich(
    StorageService storage,
    SessionInfo session,
    int generation,
  ) async {
    try {
      final List<File> files = await storage.listSegments(session.dir);
      int total = 0;
      final List<SessionSegment> segments = <SessionSegment>[];
      for (final File file in files) {
        int length = 0;
        try {
          length = await file.length();
        } catch (_) {
          length = 0;
        }
        total += length;
        segments.add(SessionSegment(file: file, bytes: length));
      }
      if (session.parsedStartedAt == null) {
        try {
          final FileStat stat = await session.dir.stat();
          session.startedAt = stat.modified;
        } catch (_) {
          // 保持创建时间兜底。
        }
      }
      // 弹幕条数：comments.jsonl 的行数（没有该文件就是 0）。
      int comments = 0;
      try {
        final File commentFile = File('${session.dir.path}/comments.jsonl');
        if (await commentFile.exists()) {
          final String content = await commentFile.readAsString();
          if (content.isNotEmpty) {
            comments = '\n'.allMatches(content).length;
            if (!content.endsWith('\n')) comments++;
          }
        }
      } catch (_) {
        comments = 0;
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        session.segments = segments;
        session.bytes = total;
        session.comments = comments;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        session.segments = <SessionSegment>[];
        session.bytes = 0;
      });
    }
  }

  void _toggle(SessionInfo session) {
    setState(() {
      _expandedPath = _expandedPath == session.dir.path
          ? null
          : session.dir.path;
    });
  }

  void _playSegment(SessionInfo session, SessionSegment segment, int index) {
    final LocalStreamServer server = context.read<LocalStreamServer>();
    Navigator.of(context).push<void>(
      glassPageRoute<void>(
        context,
        page: LivePreviewPage(
          title: '${session.displayName} · 分段 ${index + 1}',
          url: server.playerUrlForFile(segment.file.path),
        ),
      ),
    );
  }

  Future<bool> _confirmDeleteDialog(SessionInfo session) {
    final String size = session.bytes == null
        ? '分段还在统计中'
        : '共 ${formatBytes(session.bytes!)}';
    return showGlassConfirmDialog(
      context,
      title: '删除这次录像？',
      message:
          '「${session.displayName}」'
          '（${session.platformLabel} · ${formatClock(session.startedAt)}）\n'
          '$size，删除后无法恢复。',
      confirmLabel: '删除',
      destructive: true,
    );
  }

  /// 真正删除文件；返回是否成功（失败时已提示）。
  Future<bool> _deleteFiles(SessionInfo session) async {
    final StorageService storage = context.read<StorageService>();
    try {
      await storage.deleteSession(session.dir);
      if (mounted) {
        showGlassSnack(context, '已删除「${session.displayName}」');
      }
      return true;
    } catch (e) {
      if (mounted) {
        showGlassSnack(context, '删除失败：$e', error: true);
      }
      return false;
    }
  }

  void _removeFromList(SessionInfo session) {
    if (!mounted) return;
    setState(() {
      _sessions.removeWhere((SessionInfo s) => s.dir.path == session.dir.path);
      if (_expandedPath == session.dir.path) {
        _expandedPath = null;
      }
    });
  }

  Future<void> _deleteFromButton(SessionInfo session) async {
    if (!await _confirmDeleteDialog(session)) return;
    if (!mounted) return;
    final bool ok = await _deleteFiles(session);
    if (ok) _removeFromList(session);
  }

  Future<void> _showActions(SessionInfo session) async {
    final String? choice = await showGlassActionSheet(
      context,
      title: session.displayName,
      subtitle:
          '${session.platformLabel} · '
          '${formatClock(session.startedAt)} · ${session.segmentCount} 段',
      actions: <GlassAction>[
        if (session.segments?.isNotEmpty ?? false)
          const GlassAction(
            value: 'play',
            label: '回放第一段',
            icon: Icons.play_circle_outline_rounded,
          ),
        const GlassAction(
          value: 'delete',
          label: '删除录像',
          icon: Icons.delete_outline_rounded,
          destructive: true,
        ),
      ],
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'play':
        final List<SessionSegment>? segments = session.segments;
        if (segments == null || segments.isEmpty) {
          showGlassSnack(context, '分段还在读取中', error: true);
        } else {
          _playSegment(session, segments.first, 0);
        }
      case 'delete':
        await _deleteFromButton(session);
    }
  }

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    final bool hasSessions = _sessions.isNotEmpty;
    final int? totalBytes = _totalBytes();
    final int? totalSegments = _totalSegments();

    return RefreshIndicator(
      color: c.accent,
      backgroundColor: c.canvasBottom,
      onRefresh: () => _load(silent: true, retryRoot: true),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
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
                    title: '录像',
                    subtitle: hasSessions
                        ? '${_sessions.length} 场录像 · 点击分段回放'
                        : '本地保存的直播录像',
                    compact: true,
                    leading: const GlassBadge(
                      icon: Icons.video_library_rounded,
                      size: 44,
                      radius: 14,
                      gradient: true,
                    ),
                    trailing: GlassIconButton(
                      icon: Icons.refresh_rounded,
                      size: 40,
                      semanticLabel: '刷新录像列表',
                      onPressed: () => _load(silent: true, retryRoot: true),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_error != null)
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
                    child: _ErrorCard(
                      message: _error!,
                      onRetry: () => _load(retryRoot: true),
                    ),
                  ),
                ),
              ),
            ),
          if (hasSessions)
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
                    child: _SummaryCard(
                      sessions: _sessions.length,
                      bytes: totalBytes,
                      segments: totalSegments,
                    ),
                  ),
                ),
              ),
            ),
          if (hasSessions)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                GlassTokens.pagePadding,
                12,
                GlassTokens.pagePadding,
                2,
              ),
              sliver: SliverToBoxAdapter(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: GlassTokens.maxContentWidth,
                    ),
                    child: _ListHint(
                      text: '点击卡片展开分段 · 左滑或长按可删除整场录像',
                      color: GlassColors.of(context).textTertiary,
                    ),
                  ),
                ),
              ),
            ),
          if (_loading && !hasSessions)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                GlassTokens.pagePadding,
                18,
                GlassTokens.pagePadding,
                0,
              ),
              sliver: SliverList.builder(
                itemCount: 3,
                itemBuilder: (BuildContext context, int index) => Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: GlassTokens.maxContentWidth,
                    ),
                    child: const _SkeletonCard(),
                  ),
                ),
              ),
            ),
          if (!_loading && !hasSessions)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                GlassTokens.pagePadding,
                20,
                GlassTokens.pagePadding,
                0,
              ),
              sliver: SliverToBoxAdapter(
                child: GlassEmptyState(
                  title: '还没有录像',
                  message:
                      '开始录制后，录像会按任务目录保存在本地。'
                      '这里可以展开查看分段、点击回放，或左滑删除整场录像。',
                  steps: <String>[
                    '在「录制」页粘贴链接并开始录制',
                    '录制结束后回到本页下拉刷新',
                    '点击卡片展开分段，点击分段回放',
                  ],
                ),
              ),
            ),
          if (hasSessions)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                GlassTokens.pagePadding,
                12,
                GlassTokens.pagePadding,
                0,
              ),
              sliver: SliverList.builder(
                itemCount: _sessions.length,
                itemBuilder: (BuildContext context, int index) {
                  final SessionInfo session = _sessions[index];
                  return Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: GlassTokens.maxContentWidth,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: GlassTokens.gap),
                        child: Dismissible(
                          key: ValueKey<String>(session.dir.path),
                          direction: DismissDirection.endToStart,
                          dismissThresholds: const <DismissDirection, double>{
                            DismissDirection.endToStart: 0.35,
                          },
                          background: _DeleteBackground(
                            label: '删除「${session.displayName}」',
                          ),
                          confirmDismiss: (DismissDirection direction) async {
                            if (!await _confirmDeleteDialog(session)) {
                              return false;
                            }
                            return _deleteFiles(session);
                          },
                          onDismissed: (DismissDirection direction) =>
                              _removeFromList(session),
                          child: SessionCard(
                            session: session,
                            expanded: _expandedPath == session.dir.path,
                            onToggle: () => _toggle(session),
                            onLongPress: () => _showActions(session),
                            onDelete: () => _deleteFromButton(session),
                            onPlaySegment: (SessionSegment segment, int i) =>
                                _playSegment(session, segment, i),
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
      ),
    );
  }

  int? _totalBytes() {
    if (_sessions.isEmpty) return 0;
    int total = 0;
    for (final SessionInfo session in _sessions) {
      final int? bytes = session.bytes;
      if (bytes == null) return null;
      total += bytes;
    }
    return total;
  }

  int? _totalSegments() {
    if (_sessions.isEmpty) return 0;
    int total = 0;
    for (final SessionInfo session in _sessions) {
      final List<SessionSegment>? segments = session.segments;
      if (segments == null) return null;
      total += segments.length;
    }
    return total;
  }
}

class _ListHint extends StatelessWidget {
  const _ListHint({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    return Row(
      children: <Widget>[
        Icon(Icons.touch_app_outlined, size: 13, color: color),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GlassText.caption(c, color: color).copyWith(fontSize: 11),
          ),
        ),
      ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.sessions,
    required this.bytes,
    required this.segments,
  });

  final int sessions;
  final int? bytes;
  final int? segments;

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    final Widget divider = Container(width: 1, height: 28, color: c.divider);
    return GlassSurface(
      radius: GlassTokens.radiusCard,
      blur: GlassTokens.blur,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: <Widget>[
          Expanded(
            child: _SummaryStat(
              value: '$sessions',
              label: '场录像',
              color: c.accent,
            ),
          ),
          divider,
          Expanded(
            child: _SummaryStat(
              value: bytes == null ? '计算中' : formatBytes(bytes!),
              label: '占用空间',
              color: c.accentAlt,
            ),
          ),
          divider,
          Expanded(
            child: _SummaryStat(
              value: segments == null ? '—' : '$segments',
              label: '分段总数',
              color: c.cyan,
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryStat extends StatelessWidget {
  const _SummaryStat({
    required this.value,
    required this.label,
    required this.color,
  });

  final String value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GlassText.numeric(c, size: 15.5, color: color),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GlassText.micro(
            c,
            color: c.textTertiary,
          ).copyWith(fontSize: 10.5),
        ),
      ],
    );
  }
}

class _DeleteBackground extends StatelessWidget {
  const _DeleteBackground({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    return Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(GlassTokens.radiusCard),
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: <Color>[
            c.danger.withValues(alpha: 0),
            c.danger.withValues(alpha: 0.75),
          ],
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.delete_outline_rounded, color: Colors.white, size: 20),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 150),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GlassText.label(
                c,
                color: Colors.white,
              ).copyWith(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    return GlassSurface(
      radius: GlassTokens.radiusCard,
      blur: GlassTokens.blur,
      tint: c.danger,
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      child: Row(
        children: <Widget>[
          Icon(Icons.folder_off_outlined, color: c.danger, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: GlassText.caption(
                c,
                color: c.danger,
              ).copyWith(fontSize: 12, height: 1.45),
            ),
          ),
          GlassTextButton(
            label: '重试',
            icon: Icons.refresh_rounded,
            color: c.danger,
            onPressed: onRetry,
          ),
        ],
      ),
    );
  }
}

class _SkeletonCard extends StatefulWidget {
  const _SkeletonCard();

  @override
  State<_SkeletonCard> createState() => _SkeletonCardState();
}

class _SkeletonCardState extends State<_SkeletonCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    final Widget block = Container(
      decoration: BoxDecoration(
        color: c.isDark
            ? Colors.white.withValues(alpha: 0.07)
            : Colors.black.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(6),
      ),
    );
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) {
        return Opacity(opacity: 0.45 + _controller.value * 0.45, child: child);
      },
      child: Padding(
        padding: const EdgeInsets.only(bottom: GlassTokens.gap),
        child: GlassSurface(
          radius: GlassTokens.radiusCard,
          blur: GlassTokens.blur,
          padding: const EdgeInsets.all(14),
          child: Row(
            children: <Widget>[
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: c.isDark
                      ? Colors.white.withValues(alpha: 0.07)
                      : Colors.black.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(13),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    SizedBox(width: 140, height: 13, child: block),
                    const SizedBox(height: 8),
                    SizedBox(width: 210, height: 10, child: block),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
