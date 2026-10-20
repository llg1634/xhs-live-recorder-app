import 'package:flutter/material.dart';

import '../../theme/glass_tokens.dart';
import 'glass_surface.dart';
import 'pressable.dart';

/// 底部 Tab 项。
class GlassTabItem {
  const GlassTabItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
}

/// 悬浮玻璃底部导航。
class GlassTabBar extends StatelessWidget {
  const GlassTabBar({
    super.key,
    required this.index,
    required this.onChanged,
    this.recordingCount = 0,
    this.items = const <GlassTabItem>[
      GlassTabItem(
        icon: Icons.videocam_outlined,
        activeIcon: Icons.videocam_rounded,
        label: '录制',
      ),
      GlassTabItem(
        icon: Icons.video_library_outlined,
        activeIcon: Icons.video_library_rounded,
        label: '录像',
      ),
      GlassTabItem(
        icon: Icons.settings_outlined,
        activeIcon: Icons.settings_rounded,
        label: '设置',
      ),
    ],
  });

  final int index;
  final ValueChanged<int> onChanged;
  final int recordingCount;
  final List<GlassTabItem> items;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        GlassTokens.navBarMargin,
        0,
        GlassTokens.navBarMargin,
        12 + MediaQuery.paddingOf(context).bottom,
      ),
      child: GlassSurface(
        radius: GlassTokens.radiusLg,
        blur: GlassTokens.blurLg,
        grouped: false,
        padding: const EdgeInsets.all(6),
        child: SizedBox(
          height: 54,
          child: Row(
            children: <Widget>[
              for (int i = 0; i < items.length; i++)
                Expanded(
                  child: _TabButton(
                    item: items[i],
                    active: i == index,
                    badge: i == 0 && recordingCount > 0 ? recordingCount : null,
                    onTap: () => onChanged(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.item,
    required this.active,
    required this.onTap,
    this.badge,
  });

  final GlassTabItem item;
  final bool active;
  final VoidCallback onTap;
  final int? badge;

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    final Color fg = active ? c.textPrimary : c.textTertiary;
    final Color iconFg = active ? c.accent : c.textTertiary;
    return Pressable(
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          AnimatedContainer(
            duration: GlassTokens.medium,
            curve: GlassTokens.easeOut,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(GlassTokens.radiusMd),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: active
                    ? <Color>[
                        c.accent.withValues(alpha: c.isDark ? 0.24 : 0.15),
                        c.accentAlt.withValues(alpha: c.isDark ? 0.15 : 0.09),
                      ]
                    : <Color>[Colors.transparent, Colors.transparent],
              ),
              border: Border.all(
                color: active
                    ? c.accent.withValues(alpha: c.isDark ? 0.44 : 0.30)
                    : Colors.transparent,
              ),
            ),
          ),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    AnimatedSwitcher(
                      duration: GlassTokens.fast,
                      child: Icon(
                        active ? item.activeIcon : item.icon,
                        key: ValueKey<bool>(active),
                        size: 21,
                        color: iconFg,
                      ),
                    ),
                    if (badge != null)
                      Positioned(
                        right: -10,
                        top: -4,
                        child: Container(
                          constraints: const BoxConstraints(minWidth: 15),
                          height: 15,
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            color: c.accent,
                            border: Border.all(
                              color: c.canvasBottom,
                              width: 1.5,
                            ),
                          ),
                          child: Text(
                            '$badge',
                            style: GlassText.micro(c, color: Colors.white)
                                .copyWith(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w800,
                                  height: 1,
                                ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 3),
                AnimatedDefaultTextStyle(
                  duration: GlassTokens.fast,
                  style: GlassText.micro(c, color: fg).copyWith(
                    fontSize: 10.5,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                  child: Text(item.label, maxLines: 1),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
