import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../theme/glass_tokens.dart';
import 'glass_scroll_activity.dart';
import 'pressable.dart';

/// 液态玻璃基础面板。
///
/// 结构（自外向内）：
/// 1. 外阴影（悬浮感）；
/// 2. 1px 渐变高光描边（左上百 0.35 → 右下白 0.05）；
/// 3. 背景模糊层（[BackdropFilter]，在 [BackdropGroup] 内自动合并为一次模糊）；
/// 4. 半透明渐变填充 + 顶部高光 + 底部内阴影；
/// 5. 内容。
///
/// 注意：玻璃必须叠在 [GlassAmbientBackground] 或真实内容之上，不能放在纯色底上做"假玻璃"。
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.radius = GlassTokens.radiusCard,
    this.blur = GlassTokens.blur,
    this.padding = EdgeInsets.zero,
    this.margin,
    this.tint,
    this.fillTop,
    this.fillBottom,
    this.borderTop,
    this.borderBottom,
    this.borderWidth = 1,
    this.shadow = true,
    this.sheen = true,
    this.innerShade = true,
    this.grouped = true,
    this.width,
    this.height,
    this.alignment,
  });

  final Widget child;
  final double radius;
  final double blur;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;

  /// 给整块玻璃加主题色倾向（状态卡片 / 危险按钮等）。
  final Color? tint;
  final Color? fillTop;
  final Color? fillBottom;
  final Color? borderTop;
  final Color? borderBottom;
  final double borderWidth;
  final bool shadow;

  /// 顶部反光。
  final bool sheen;

  /// 底部内阴影（让玻璃有厚度）。
  final bool innerShade;

  /// 是否参与 [BackdropGroup] 的共享模糊（有 group 祖先时生效）。
  final bool grouped;

  final double? width;
  final double? height;
  final AlignmentGeometry? alignment;

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    final bool dark = c.isDark;
    final Radius outerRadius = Radius.circular(radius);
    final BorderRadius borderRadius = BorderRadius.all(outerRadius);
    final BorderRadius innerBorderRadius = BorderRadius.all(
      Radius.circular(math.max(0, radius - borderWidth)),
    );

    final Gradient fill;
    if (fillTop != null && fillBottom != null) {
      fill = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: <Color>[fillTop!, fillBottom!],
      );
    } else if (tint != null) {
      fill = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: <Color>[
          Color.alphaBlend(
            tint!.withValues(alpha: dark ? 0.14 : 0.26),
            c.glassFillTop,
          ),
          Color.alphaBlend(
            tint!.withValues(alpha: dark ? 0.05 : 0.1),
            c.glassFillBottom,
          ),
        ],
      );
    } else {
      fill = c.glassFill;
    }

    final Gradient border;
    if (borderTop != null && borderBottom != null) {
      border = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: <Color>[borderTop!, borderBottom!],
      );
    } else if (tint != null) {
      border = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: <Color>[
          tint!.withValues(alpha: dark ? 0.42 : 0.55),
          c.glassBorderBottom,
        ],
      );
    } else {
      border = c.glassBorder;
    }

    // 只有当前可见 Tab 会订阅滚动状态：隐藏页的 TickerMode 为 false，
    // 不必跟着别页的滚动去重建自己的模糊层。
    final ValueListenable<bool>? scrolling =
        TickerMode.valuesOf(context).enabled
        ? GlassScrollActivity.maybeOf(context)
        : null;

    final Widget body = ClipRRect(
      borderRadius: innerBorderRadius,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: <Widget>[
          Positioned.fill(
            child: _GlassBackdropLayer(
              blur: blur,
              grouped: grouped,
              scrolling: scrolling,
            ),
          ),
          Positioned.fill(
            child: DecoratedBox(decoration: BoxDecoration(gradient: fill)),
          ),
          if (sheen)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(gradient: c.glassSheen),
                ),
              ),
            ),
          if (innerShade)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[
                        Colors.transparent,
                        (dark ? Colors.black : c.glassTint).withValues(
                          alpha: dark ? 0.14 : 0.035,
                        ),
                      ],
                      stops: const <double>[0.55, 1],
                    ),
                  ),
                ),
              ),
            ),
          Padding(padding: padding, child: child),
        ],
      ),
    );

    Widget surface = Container(
      width: width,
      height: height,
      alignment: alignment,
      decoration: BoxDecoration(borderRadius: borderRadius, gradient: border),
      padding: EdgeInsets.all(borderWidth),
      child: body,
    );

    if (shadow) {
      surface = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          boxShadow: c.cardShadows(),
        ),
        child: surface,
      );
    }

    if (margin != null) {
      surface = Padding(padding: margin!, child: surface);
    }

    return surface;
  }
}

/// 模糊层：滚动中把 sigma 压到约 38%，停止后恢复。
///
/// 用 [ValueListenableBuilder] 只重建这一层，玻璃的渐变、描边、内容都不重建。
class _GlassBackdropLayer extends StatelessWidget {
  const _GlassBackdropLayer({
    required this.blur,
    required this.grouped,
    this.scrolling,
  });

  final double blur;
  final bool grouped;
  final ValueListenable<bool>? scrolling;

  @override
  Widget build(BuildContext context) {
    final ValueListenable<bool>? activity = scrolling;
    if (activity == null) return _buildLayer(false);
    return ValueListenableBuilder<bool>(
      valueListenable: activity,
      builder: (BuildContext context, bool isScrolling, Widget? child) =>
          _buildLayer(isScrolling),
    );
  }

  Widget _buildLayer(bool isScrolling) {
    final double sigma = isScrolling ? math.max(4, blur * 0.38) : blur;
    final ui.ImageFilter filter = ui.ImageFilter.blur(
      sigmaX: sigma,
      sigmaY: sigma,
    );
    return grouped
        ? BackdropFilter.grouped(filter: filter, child: const SizedBox.expand())
        : BackdropFilter(filter: filter, child: const SizedBox.expand());
  }
}

/// 玻璃卡片：圆角 22、内边距 16，可选点击/长按。
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = GlassTokens.radiusCard,
    this.onTap,
    this.onLongPress,
    this.tint,
    this.blur,
    this.shadow = true,
    this.margin,
    this.semanticLabel,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Color? tint;
  final double? blur;
  final bool shadow;
  final EdgeInsetsGeometry? margin;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final Widget surface = GlassSurface(
      radius: radius,
      blur: blur ?? GlassTokens.blur,
      padding: padding,
      tint: tint,
      shadow: shadow,
      child: child,
    );
    if (onTap == null && onLongPress == null) {
      return margin == null
          ? surface
          : Padding(padding: margin!, child: surface);
    }
    final Widget pressable = Pressable(
      onTap: onTap,
      onLongPress: onLongPress,
      semanticLabel: semanticLabel,
      child: surface,
    );
    return margin == null
        ? pressable
        : Padding(padding: margin!, child: pressable);
  }
}

/// 玻璃质感分隔线：中间亮、两端淡出。
class GlassDivider extends StatelessWidget {
  const GlassDivider({super.key, this.indent = 0, this.endIndent = 0});

  final double indent;
  final double endIndent;

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    return Padding(
      padding: EdgeInsets.only(left: indent, right: endIndent),
      child: Container(
        height: 1,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: <Color>[
              c.divider.withValues(alpha: 0),
              c.divider,
              c.divider.withValues(alpha: 0),
            ],
          ),
        ),
      ),
    );
  }
}
