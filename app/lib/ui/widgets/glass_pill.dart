import 'package:flutter/material.dart';

import '../../theme/glass_tokens.dart';
import 'pressable.dart';

/// 玻璃胶囊标签：平台、状态、元信息。
class GlassPill extends StatelessWidget {
  const GlassPill({
    super.key,
    required this.label,
    this.color,
    this.leading,
    this.icon,
    this.dense = false,
    this.onTap,
    this.maxWidth,
    this.filled = false,
  });

  final String label;
  final Color? color;
  final Widget? leading;
  final IconData? icon;
  final bool dense;
  final VoidCallback? onTap;
  final double? maxWidth;

  /// 实心（用于主色标签）。
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    final Color fg = color ?? c.textSecondary;
    final bool dark = c.isDark;

    final Widget content = Container(
      constraints: BoxConstraints(maxWidth: maxWidth ?? double.infinity),
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 8 : 10,
        vertical: dense ? 4 : 6,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(GlassTokens.radiusPill),
        color: filled
            ? fg.withValues(alpha: dark ? 0.28 : 0.9)
            : fg.withValues(alpha: dark ? 0.14 : 0.12),
        border: Border.all(
          color: filled
              ? Colors.white.withValues(alpha: dark ? 0.24 : 0.6)
              : fg.withValues(alpha: dark ? 0.34 : 0.26),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (leading != null) ...<Widget>[
            leading!,
            SizedBox(width: dense ? 4 : 6),
          ],
          if (icon != null) ...<Widget>[
            Icon(
              icon,
              size: dense ? 12 : 13,
              color: filled ? Colors.white : fg,
            ),
            SizedBox(width: dense ? 4 : 5),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GlassText.micro(c, color: filled ? Colors.white : fg)
                  .copyWith(
                    fontSize: dense ? 11 : 11.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.1,
                  ),
            ),
          ),
        ],
      ),
    );

    if (onTap == null) return content;
    return Pressable(onTap: onTap, child: content);
  }
}

/// 带图标的圆形小徽标（列表左侧、头像位）。
class GlassBadge extends StatelessWidget {
  const GlassBadge({
    super.key,
    required this.icon,
    this.color,
    this.size = 44,
    this.radius,
    this.gradient = false,
  });

  final IconData icon;
  final Color? color;
  final double size;
  final double? radius;
  final bool gradient;

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    final Color tint = color ?? c.accent;
    final BorderRadius borderRadius = BorderRadius.circular(
      radius ?? size * 0.32,
    );
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        gradient: gradient
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[
                  tint.withValues(alpha: 0.95),
                  c.accentAlt.withValues(alpha: 0.85),
                ],
              )
            : null,
        color: gradient ? null : tint.withValues(alpha: c.isDark ? 0.16 : 0.14),
        border: Border.all(
          color: gradient
              ? Colors.white.withValues(alpha: 0.3)
              : tint.withValues(alpha: c.isDark ? 0.34 : 0.3),
        ),
        boxShadow: gradient
            ? <BoxShadow>[
                BoxShadow(
                  color: tint.withValues(alpha: 0.35),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                  spreadRadius: -4,
                ),
              ]
            : null,
      ),
      child: Icon(
        icon,
        size: size * 0.46,
        color: gradient ? Colors.white : tint,
      ),
    );
  }
}
