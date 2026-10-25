import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../app.dart';
import '../../models/quality.dart';
import '../../services/recording_manager.dart';
import '../../services/storage_service.dart';
import '../../theme/glass_palette.dart';
import '../../theme/glass_tokens.dart';
import '../widgets/feedback.dart';
import '../widgets/glass_button.dart';
import '../widgets/glass_page_route.dart';
import '../widgets/glass_pill.dart';
import '../widgets/glass_surface.dart';
import '../widgets/pressable.dart';
import '../widgets/storage_root_cache.dart';
import 'app_settings.dart';

/// 「设置」页：主题模式、存储根目录、最大并发数、关于。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, this.active = true});

  /// 是否是当前可见 Tab；不可见时先不解析存储目录，避免与其他页面争用写探测。
  final bool active;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Future<Directory>? _rootFuture;

  @override
  void initState() {
    super.initState();
    if (widget.active) {
      _rootFuture = StorageRootCache.resolve(context.read<StorageService>());
    }
  }

  @override
  void didUpdateWidget(SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active && _rootFuture == null) {
      _rootFuture = StorageRootCache.resolve(context.read<StorageService>());
    }
  }

  void _loadRoot({bool retry = false}) {
    final StorageService storage = context.read<StorageService>();
    setState(() {
      _rootFuture = StorageRootCache.resolve(storage, retry: retry);
    });
  }

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    final ThemeController themeController = context.watch<ThemeController>();
    final AppSettingsController appSettings = context
        .watch<AppSettingsController>();
    final int maxConcurrent = context.select<RecordingManager, int>(
      (RecordingManager m) => m.maxConcurrentTasks,
    );
    final int active = context.select<RecordingManager, int>(
      (RecordingManager m) => m.activeCount,
    );

    return CustomScrollView(
      key: const PageStorageKey<String>('settings-scroll'),
      scrollCacheExtent: const ScrollCacheExtent.pixels(320),
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
                child: const GlassPageHeader(
                  title: '设置',
                  subtitle: '外观 · 存储 · 关于',
                  compact: true,
                  leading: GlassBadge(
                    icon: Icons.tune_rounded,
                    size: 44,
                    radius: 14,
                    gradient: true,
                  ),
                ),
              ),
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            GlassTokens.pagePadding,
            20,
            GlassTokens.pagePadding,
            0,
          ),
          sliver: SliverToBoxAdapter(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: GlassTokens.maxContentWidth,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const GlassSectionHeader(title: '外观'),
                    const SizedBox(height: 10),
                    _SettingsGroup(
                      children: <Widget>[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Row(
                                children: <Widget>[
                                  const _RowIcon(icon: Icons.palette_outlined),
                                  const SizedBox(width: 10),
                                  Text(
                                    '主题模式',
                                    style: GlassText.label(c)
                                        .copyWith(fontSize: 14),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              _ThemeModeChooser(
                                mode: themeController.mode,
                                onChanged: (ThemeMode mode) {
                                  themeController.mode = mode;
                                  HapticFeedback.selectionClick();
                                },
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '深色 / 浅色均针对液态玻璃单独调校，可跟随系统自动切换。',
                                style: GlassText.caption(
                                  c,
                                  color: c.textTertiary,
                                ).copyWith(fontSize: 11.5),
                              ),
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 14),
                                child: GlassDivider(),
                              ),
                              Row(
                                children: <Widget>[
                                  const _RowIcon(
                                    icon: Icons.color_lens_outlined,
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    '主题色',
                                    style: GlassText.label(c)
                                        .copyWith(fontSize: 14),
                                  ),
                                  const Spacer(),
                                  Text(
                                    themeController.palette.label,
                                    style: GlassText.micro(
                                      c,
                                      color: c.accent,
                                    ).copyWith(fontWeight: FontWeight.w700),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              _ThemePaletteChooser(
                                selected: themeController.palette,
                                onChanged: (GlassPalette palette) {
                                  themeController.palette = palette;
                                  HapticFeedback.selectionClick();
                                },
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '主题色同时作用于强调色、语义色、玻璃 tint 与背景光斑。',
                                style: GlassText.caption(
                                  c,
                                  color: c.textTertiary,
                                ).copyWith(fontSize: 11.5),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: GlassTokens.gapXl),
                    const GlassSectionHeader(title: '存储'),
                    const SizedBox(height: 10),
                    _SettingsGroup(
                      children: <Widget>[
                        _InfoRow(
                          icon: Icons.folder_outlined,
                          title: '存储根目录',
                          subtitleWidget: FutureBuilder<Directory>(
                            future: _rootFuture,
                            builder:
                                (
                                  BuildContext context,
                                  AsyncSnapshot<Directory> snapshot,
                                ) {
                                  if (snapshot.connectionState !=
                                      ConnectionState.done) {
                                    return _PathText(
                                      text: '读取中…',
                                      color: c.textTertiary,
                                    );
                                  }
                                  if (snapshot.hasError) {
                                    return _PathText(
                                      text: '没有可写的录像目录\n${snapshot.error}',
                                      color: c.danger,
                                    );
                                  }
                                  return _PathText(
                                    text: snapshot.data?.path ?? '未知',
                                    color: c.textSecondary,
                                  );
                                },
                          ),
                          trailing: FutureBuilder<Directory>(
                            future: _rootFuture,
                            builder:
                                (
                                  BuildContext context,
                                  AsyncSnapshot<Directory> snapshot,
                                ) {
                                  final String? path = snapshot.data?.path;
                                  return Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: <Widget>[
                                      GlassIconButton(
                                        icon: Icons.refresh_rounded,
                                        size: 34,
                                        iconSize: 15,
                                        color: c.textSecondary,
                                        semanticLabel: '重新读取存储目录',
                                        onPressed: () => _loadRoot(retry: true),
                                      ),
                                      const SizedBox(width: 6),
                                      GlassIconButton(
                                        icon: Icons.copy_rounded,
                                        size: 34,
                                        iconSize: 15,
                                        color: c.textSecondary,
                                        semanticLabel: '复制存储路径',
                                        onPressed: path == null
                                            ? null
                                            : () => copyToClipboard(
                                                context,
                                                path,
                                              ),
                                      ),
                                    ],
                                  );
                                },
                          ),
                        ),
                        const GlassDivider(indent: 16, endIndent: 16),
                        _InfoRow(
                          icon: Icons.sd_storage_outlined,
                          title: '写入策略',
                          subtitle: '优先公共目录 Movies/直播录制，不可写时回退到应用私有目录。',
                        ),
                        const GlassDivider(indent: 16, endIndent: 16),
                        _InfoRow(
                          icon: Icons.delete_sweep_outlined,
                          title: '删除前二次确认',
                          subtitle: '关闭后，左滑或长按删除录像会直接执行，不再弹确认框。',
                          trailing: Switch.adaptive(
                            value: appSettings.deleteConfirm,
                            activeTrackColor: c.accent,
                            onChanged: (bool value) {
                              HapticFeedback.selectionClick();
                              appSettings.deleteConfirm = value;
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: GlassTokens.gapXl),
                    const GlassSectionHeader(title: '录制'),
                    const SizedBox(height: 10),
                    _SettingsGroup(
                      children: <Widget>[
                        _InfoRow(
                          icon: Icons.layers_outlined,
                          title: '最大并发数',
                          value: '$maxConcurrent',
                          valueColor: c.accent,
                          iconColor: c.accent,
                        ),
                        const GlassDivider(indent: 16, endIndent: 16),
                        _InfoRow(
                          icon: Icons.high_quality_outlined,
                          title: '画质',
                          subtitle: '最高：原画/1080P；默认：720P/540P，更省流量。',
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              GlassPill(
                                label: '最高',
                                dense: true,
                                filled: appSettings.quality ==
                                    RecordQuality.highest,
                                color: c.accent,
                                onTap: () {
                                  HapticFeedback.selectionClick();
                                  appSettings.quality = RecordQuality.highest;
                                },
                              ),
                              const SizedBox(width: 6),
                              GlassPill(
                                label: '默认',
                                dense: true,
                                filled: appSettings.quality ==
                                    RecordQuality.standard,
                                color: c.accent,
                                onTap: () {
                                  HapticFeedback.selectionClick();
                                  appSettings.quality = RecordQuality.standard;
                                },
                              ),
                            ],
                          ),
                        ),
                        const GlassDivider(indent: 16, endIndent: 16),
                        _InfoRow(
                          icon: Icons.sensors_rounded,
                          title: '当前录制中',
                          value: '$active',
                          valueColor: active > 0 ? c.accent : c.textSecondary,
                        ),
                        const GlassDivider(indent: 16, endIndent: 16),
                        _InfoRow(
                          icon: Icons.swap_horiz_rounded,
                          title: '断流重连',
                          value: '5s × 3',
                        ),
                        const GlassDivider(indent: 16, endIndent: 16),
                        const _InfoRow(
                          icon: Icons.public_rounded,
                          title: '支持平台',
                          subtitle:
                              '小红书 · 抖音（均已支持录制与弹幕）\n'
                              '录制 FLV · 弹幕 JSONL + ASS 字幕',
                        ),
                      ],
                    ),
                    const SizedBox(height: GlassTokens.gapXl),
                    const GlassSectionHeader(title: '关于'),
                    const SizedBox(height: 10),
                    _SettingsGroup(
                      children: <Widget>[
                        _InfoRow(
                          icon: Icons.info_outline_rounded,
                          title: '应用',
                          value: '直播录制',
                        ),
                        const GlassDivider(indent: 16, endIndent: 16),
                        _InfoRow(
                          icon: Icons.tag_rounded,
                          title: '版本',
                          value: '1.0.0',
                        ),
                        const GlassDivider(indent: 16, endIndent: 16),
                        _InfoRow(
                          icon: Icons.memory_rounded,
                          title: '运行环境',
                          subtitle: 'Flutter · 本地 HTTP 流代理 · flv.js 播放内核',
                        ),
                        const GlassDivider(indent: 16, endIndent: 16),
                        _InfoRow(
                          icon: Icons.lock_outline_rounded,
                          title: '隐私',
                          subtitle: '录制全程在本地完成，不上传任何视频数据。',
                        ),
                      ],
                    ),
                    const SizedBox(height: GlassTokens.gapXl),
                    Center(
                      child: Column(
                        children: <Widget>[
                          Container(
                            width: 46,
                            height: 46,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(15),
                              gradient: c.brandGradient,
                              boxShadow: <BoxShadow>[
                                BoxShadow(
                                  color: c.accent.withValues(alpha: 0.35),
                                  blurRadius: 20,
                                  offset: const Offset(0, 8),
                                  spreadRadius: -4,
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.videocam_rounded,
                              color: Colors.white,
                              size: 24,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            '液态玻璃 · Liquid Glass',
                            style: GlassText.caption(
                              c,
                              color: c.textTertiary,
                            ).copyWith(fontSize: 11.5),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
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
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    // 设置页一次会出现多个分组面板，统一用更轻的 blurSm 控制首帧模糊层成本。
    return GlassSurface(
      radius: GlassTokens.radiusCard,
      blur: GlassTokens.blurSm,
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

class _RowIcon extends StatelessWidget {
  const _RowIcon({required this.icon, this.color});

  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    final Color tone = color ?? c.textSecondary;
    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(9),
        color: tone.withValues(alpha: c.isDark ? 0.14 : 0.1),
        border: Border.all(color: tone.withValues(alpha: 0.3)),
      ),
      child: Icon(icon, size: 15, color: tone),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.subtitleWidget,
    this.value,
    this.valueColor,
    this.trailing,
    this.iconColor,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? subtitleWidget;
  final String? value;
  final Color? valueColor;
  final Widget? trailing;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 13, 12, 13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: _RowIcon(icon: icon, color: iconColor),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: GlassText.label(c).copyWith(fontSize: 13.5)),
                if (subtitleWidget != null) ...<Widget>[
                  const SizedBox(height: 5),
                  subtitleWidget!,
                ],
                if (subtitle != null) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    subtitle!,
                    style: GlassText.caption(
                      c,
                      color: c.textTertiary,
                    ).copyWith(fontSize: 11.5, height: 1.45),
                  ),
                ],
              ],
            ),
          ),
          if (value != null) ...<Widget>[
            const SizedBox(width: 10),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                value!,
                style: GlassText.numeric(
                  c,
                  size: 14,
                  color: valueColor ?? c.textPrimary,
                ),
              ),
            ),
          ],
          if (trailing != null) ...<Widget>[
            const SizedBox(width: 8),
            trailing!,
          ],
        ],
      ),
    );
  }
}

class _PathText extends StatelessWidget {
  const _PathText({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    return Text(
      text,
      style: GlassText.caption(
        c,
        color: color,
      ).copyWith(fontSize: 11.5, height: 1.4),
    );
  }
}

/// 一排主题色圆点：点选即时生效，并由 [ThemeController] 持久化。
class _ThemePaletteChooser extends StatelessWidget {
  const _ThemePaletteChooser({required this.selected, required this.onChanged});

  final GlassPalette selected;
  final ValueChanged<GlassPalette> onChanged;

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    final Brightness brightness = Theme.of(context).brightness;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(GlassTokens.radiusMd),
        color: c.fieldFill,
        border: Border.all(color: c.divider),
      ),
      child: Row(
        children: <Widget>[
          for (final GlassPalette palette in GlassPalette.values)
            Expanded(
              child: _PaletteDot(
                palette: palette,
                colors: GlassPalettes.colorsOf(palette, brightness),
                selected: palette == selected,
                onTap: () => onChanged(palette),
              ),
            ),
        ],
      ),
    );
  }
}

class _PaletteDot extends StatelessWidget {
  const _PaletteDot({
    required this.palette,
    required this.colors,
    required this.selected,
    required this.onTap,
  });

  final GlassPalette palette;
  final GlassColors colors;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: '主题色 ${palette.label}，${palette.description}',
      child: Pressable(
        onTap: onTap,
        haptic: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AnimatedContainer(
              duration: GlassTokens.fast,
              curve: GlassTokens.easeOut,
              width: 34,
              height: 34,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? c.textPrimary : Colors.transparent,
                  width: 1.5,
                ),
                boxShadow: selected
                    ? <BoxShadow>[
                        BoxShadow(
                          color: colors.accent.withValues(alpha: 0.45),
                          blurRadius: 12,
                          offset: const Offset(0, 3),
                        ),
                      ]
                    : null,
              ),
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: <Color>[colors.accent, colors.accentAlt],
                  ),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.5),
                  ),
                ),
                child: selected
                    ? const Icon(
                        Icons.check_rounded,
                        size: 16,
                        color: Colors.white,
                      )
                    : null,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              palette.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  GlassText.micro(
                    c,
                    color: selected ? c.textPrimary : c.textTertiary,
                  ).copyWith(
                    fontSize: 9.5,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThemeModeChooser extends StatelessWidget {
  const _ThemeModeChooser({required this.mode, required this.onChanged});

  final ThemeMode mode;
  final ValueChanged<ThemeMode> onChanged;

  static const List<(ThemeMode, IconData, String)> _options =
      <(ThemeMode, IconData, String)>[
        (ThemeMode.system, Icons.brightness_auto_rounded, '跟随系统'),
        (ThemeMode.light, Icons.light_mode_rounded, '浅色'),
        (ThemeMode.dark, Icons.dark_mode_rounded, '深色'),
      ];

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(GlassTokens.radiusMd),
        color: c.fieldFill,
        border: Border.all(color: c.divider),
      ),
      child: Row(
        children: <Widget>[
          for (final (ThemeMode optionMode, IconData icon, String label)
              in _options)
            Expanded(
              child: Pressable(
                onTap: () => onChanged(optionMode),
                child: AnimatedContainer(
                  duration: GlassTokens.medium,
                  curve: GlassTokens.easeOut,
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: mode == optionMode
                          ? <Color>[
                              c.accent.withValues(
                                alpha: c.isDark ? 0.26 : 0.15,
                              ),
                              c.accentAlt.withValues(
                                alpha: c.isDark ? 0.18 : 0.1,
                              ),
                            ]
                          : <Color>[Colors.transparent, Colors.transparent],
                    ),
                    border: Border.all(
                      color: mode == optionMode
                          ? c.accent.withValues(alpha: 0.35)
                          : Colors.transparent,
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(
                        icon,
                        size: 18,
                        color: mode == optionMode ? c.accent : c.textTertiary,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            GlassText.micro(
                              c,
                              color: mode == optionMode
                                  ? c.accent
                                  : c.textTertiary,
                            ).copyWith(
                              fontSize: 10.5,
                              fontWeight: mode == optionMode
                                  ? FontWeight.w700
                                  : FontWeight.w600,
                            ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
