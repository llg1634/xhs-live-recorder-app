import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/glass_tokens.dart';

/// 插画式空态提示：玻璃卡片 + 声波条 + 漂浮胶囊，带极缓慢的上下浮动。
class GlassEmptyState extends StatelessWidget {
  const GlassEmptyState({
    super.key,
    required this.title,
    required this.message,
    this.steps = const <String>[],
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
  });

  final String title;
  final String message;
  final List<String> steps;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    return Padding(
      padding: padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const _FloatingArtwork(),
          const SizedBox(height: GlassTokens.gap),
          Text(
            title,
            textAlign: TextAlign.center,
            style: GlassText.title(c).copyWith(fontSize: 18),
          ),
          const SizedBox(height: 7),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 330),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: GlassText.caption(
                c,
                color: c.textSecondary,
              ).copyWith(fontSize: 13, height: 1.5),
            ),
          ),
          if (steps.isNotEmpty) ...<Widget>[
            const SizedBox(height: GlassTokens.gapLg),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (int i = 0; i < steps.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: _StepRow(index: i + 1, text: steps[i]),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.index, required this.text});

  final int index;
  final String text;

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 20,
          height: 20,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: c.accent.withValues(alpha: c.isDark ? 0.18 : 0.12),
            border: Border.all(color: c.accent.withValues(alpha: 0.35)),
          ),
          child: Text(
            '$index',
            style: GlassText.micro(
              c,
              color: c.accent,
            ).copyWith(fontSize: 10.5, fontWeight: FontWeight.w800),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          text,
          style: GlassText.caption(
            c,
            color: c.textSecondary,
          ).copyWith(fontSize: 12.5),
        ),
      ],
    );
  }
}

class _FloatingArtwork extends StatefulWidget {
  const _FloatingArtwork();

  @override
  State<_FloatingArtwork> createState() => _FloatingArtworkState();
}

class _FloatingArtworkState extends State<_FloatingArtwork>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 4200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      if (_controller.isAnimating) _controller.stop();
      _controller.value = 0.5;
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (BuildContext context, Widget? child) {
          final double t = Curves.easeInOut.transform(_controller.value);
          return Transform.translate(
            offset: Offset(0, -5 * t),
            child: CustomPaint(
              size: const Size(196, 152),
              painter: _ArtworkPainter(c, t),
            ),
          );
        },
      ),
    );
  }
}

class _ArtworkPainter extends CustomPainter {
  const _ArtworkPainter(this.colors, this.t);

  final GlassColors colors;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final bool dark = colors.isDark;
    final Offset center = Offset(size.width / 2, size.height * 0.5);

    // 光晕。
    final double haloRadius = size.height * 0.52;
    canvas.drawCircle(
      center,
      haloRadius,
      Paint()
        ..shader = uiGradientRadial(center, haloRadius, <Color>[
          colors.accent.withValues(alpha: dark ? 0.24 : 0.16),
          colors.accent.withValues(alpha: 0),
        ]),
    );

    // 轨道环。
    canvas.drawCircle(
      center,
      haloRadius * 0.82,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = dark
            ? colors.glassBorderTop.withValues(alpha: 0.22)
            : colors.accent.withValues(alpha: 0.16),
    );
    canvas.drawCircle(
      center,
      haloRadius * 1.02,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = dark
            ? colors.glassBorderTop.withValues(alpha: 0.1)
            : colors.accentAlt.withValues(alpha: 0.12),
    );

    // 中央玻璃卡片。
    final Rect cardRect = Rect.fromCenter(
      center: center,
      width: size.width * 0.56,
      height: size.height * 0.4,
    );
    final RRect card = RRect.fromRectAndRadius(
      cardRect,
      const Radius.circular(20),
    );
    canvas.drawRRect(
      card,
      Paint()
        ..shader = uiGradientLinear(cardRect, <Color>[
          colors.accent.withValues(alpha: dark ? 0.14 : 0.1),
          colors.accentAlt.withValues(alpha: dark ? 0.06 : 0.05),
        ]),
    );
    canvas.drawRRect(
      card,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = dark
            ? colors.glassBorderTop.withValues(alpha: 0.5)
            : colors.accent.withValues(alpha: 0.24),
    );

    // 声波条。
    const List<double> pattern = <double>[0.34, 0.62, 0.92, 0.52, 0.78, 0.42];
    final List<Color> bars = <Color>[
      colors.accent,
      colors.accent,
      colors.accentAlt,
      colors.cyan,
      colors.accentAlt,
      colors.accent,
    ];
    final double barWidth = cardRect.width * 0.075;
    final double gap = barWidth * 0.95;
    final double totalWidth =
        pattern.length * barWidth + (pattern.length - 1) * gap;
    double x = cardRect.center.dx - totalWidth / 2;
    for (int i = 0; i < pattern.length; i++) {
      final double wave = 0.82 + 0.18 * math.sin((t * math.pi * 2) + i * 0.9);
      final double barHeight = cardRect.height * 0.66 * pattern[i] * wave;
      final RRect bar = RRect.fromRectAndRadius(
        Rect.fromLTWH(
          x,
          cardRect.center.dy - barHeight / 2,
          barWidth,
          barHeight,
        ),
        Radius.circular(barWidth),
      );
      canvas.drawRRect(
        bar,
        Paint()..color = bars[i].withValues(alpha: dark ? 0.92 : 0.88),
      );
      x += barWidth + gap;
    }

    // 漂浮的小胶囊。
    _pill(
      canvas,
      Rect.fromLTWH(
        size.width * 0.78,
        size.height * 0.16 - 3 * t,
        size.width * 0.19,
        11,
      ),
      colors.accentAlt,
    );
    _pill(
      canvas,
      Rect.fromLTWH(
        size.width * 0.03,
        size.height * 0.7 + 4 * t,
        size.width * 0.16,
        10,
      ),
      colors.cyan,
    );
    _dot(
      canvas,
      Offset(size.width * 0.16, size.height * 0.16 + 2 * t),
      4.5,
      colors.accent,
    );
    _dot(
      canvas,
      Offset(size.width * 0.9, size.height * 0.78 - 3 * t),
      3.5,
      colors.accentAlt,
    );
  }

  void _pill(Canvas canvas, Rect rect, Color color) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(rect.height)),
      Paint()..color = color.withValues(alpha: colors.isDark ? 0.5 : 0.6),
    );
  }

  void _dot(Canvas canvas, Offset center, double radius, Color color) {
    canvas.drawCircle(
      center,
      radius,
      Paint()..color = color.withValues(alpha: colors.isDark ? 0.8 : 0.85),
    );
  }

  @override
  bool shouldRepaint(_ArtworkPainter oldDelegate) =>
      oldDelegate.t != t || oldDelegate.colors != colors;
}

// 下面两个小工具避免 UI 代码直接依赖 dart:ui 的类型命名。
Shader uiGradientRadial(Offset center, double radius, List<Color> colors) =>
    RadialGradient(colors: colors)
        .createShader(Rect.fromCircle(center: center, radius: radius));

Shader uiGradientLinear(Rect rect, List<Color> colors) => LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: colors,
).createShader(rect);
