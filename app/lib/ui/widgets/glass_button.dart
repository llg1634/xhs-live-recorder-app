import 'package:flutter/material.dart';

import '../../theme/glass_tokens.dart';
import 'glass_surface.dart';
import 'pressable.dart';

enum GlassButtonVariant {
  /// 品牌渐变主按钮（洋红 → 紫）。
  primary,

  /// 玻璃底 + 主题色文字。
  glass,

  /// 危险操作。
  danger,
}

/// 玻璃按钮。
class GlassButton extends StatelessWidget {
  const GlassButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.variant = GlassButtonVariant.primary,
    this.expand = true,
    this.height = GlassTokens.buttonHeight,
    this.loading = false,
    this.radius = GlassTokens.radiusMd,
    this.fontSize = 15.5,
    this.trailing,
    this.gradient,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final GlassButtonVariant variant;
  final bool expand;
  final double height;
  final bool loading;
  final double radius;
  final double fontSize;
  final Widget? trailing;

  /// 主按钮的自定义渐变色（例如删除确认用危险色），首色决定外发光。
  final List<Color>? gradient;

  bool get _enabled => onPressed != null && !loading;

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    final BorderRadius borderRadius = BorderRadius.circular(radius);

    final Widget labelRow = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        if (loading)
          SizedBox(
            width: 17,
            height: 17,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(
                variant == GlassButtonVariant.primary
                    ? Colors.white
                    : (variant == GlassButtonVariant.danger
                          ? c.danger
                          : c.accent),
              ),
            ),
          )
        else if (icon != null)
          Icon(
            icon,
            size: 19,
            color: variant == GlassButtonVariant.primary
                ? Colors.white
                : (variant == GlassButtonVariant.danger ? c.danger : c.accent),
          ),
        if (loading || icon != null) const SizedBox(width: 9),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GlassText.label(
              c,
              color: variant == GlassButtonVariant.primary
                  ? Colors.white
                  : (variant == GlassButtonVariant.danger
                        ? c.danger
                        : c.textPrimary),
            ).copyWith(fontSize: fontSize, fontWeight: FontWeight.w700),
          ),
        ),
        if (trailing != null) ...<Widget>[const SizedBox(width: 8), trailing!],
      ],
    );

    final Widget child;
    if (variant == GlassButtonVariant.primary) {
      final List<Color> colors = gradient ?? <Color>[c.accent, c.accentAlt];
      child = Opacity(
        opacity: _enabled ? 1 : 0.5,
        child: Container(
          height: height,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: colors,
            ),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.22),
              width: 1,
            ),
            boxShadow: _enabled
                ? <BoxShadow>[
                    BoxShadow(
                      color: colors.first.withValues(
                        alpha: c.isDark ? 0.42 : 0.3,
                      ),
                      blurRadius: 24,
                      offset: const Offset(0, 10),
                      spreadRadius: -6,
                    ),
                  ]
                : null,
          ),
          foregroundDecoration: BoxDecoration(
            borderRadius: borderRadius,
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                Colors.white.withValues(alpha: 0.26),
                Colors.white.withValues(alpha: 0.02),
                Colors.transparent,
              ],
              stops: const <double>[0, 0.42, 1],
            ),
          ),
          child: labelRow,
        ),
      );
    } else {
      child = Opacity(
        opacity: _enabled ? 1 : 0.45,
        child: GlassSurface(
          radius: radius,
          blur: GlassTokens.blurSm,
          tint: variant == GlassButtonVariant.danger ? c.danger : c.accent,
          child: Container(
            height: height,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: labelRow,
          ),
        ),
      );
    }

    return Pressable(onTap: _enabled ? onPressed : null, child: child);
  }
}

/// 圆形玻璃图标按钮。
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.size = GlassTokens.iconButtonSize,
    this.iconSize,
    this.color,
    this.tint,
    this.filled = false,
    this.semanticLabel,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final double size;
  final double? iconSize;
  final Color? color;
  final Color? tint;
  final bool filled;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    final Color iconColor = color ?? c.textPrimary;
    return Semantics(
      button: true,
      label: semanticLabel,
      child: Pressable(
        onTap: onPressed,
        child: GlassSurface(
          radius: size / 2,
          blur: GlassTokens.blurSm,
          shadow: false,
          tint: filled ? (tint ?? c.accent) : tint,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(icon, size: iconSize ?? size * 0.46, color: iconColor),
          ),
        ),
      ),
    );
  }
}

/// 玻璃质感"文字按钮"（无底色，点击区域带内边距）。
class GlassTextButton extends StatelessWidget {
  const GlassTextButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.color,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    final Color fg = color ?? c.accent;
    return Pressable(
      onTap: onPressed,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (icon != null) ...<Widget>[
              Icon(icon, size: 15, color: fg),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: GlassText.label(c, color: fg).copyWith(fontSize: 12.5),
            ),
          ],
        ),
      ),
    );
  }
}
