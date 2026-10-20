import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../theme/glass_tokens.dart';

/// 背景氛围层：深色为近黑底 + 紫/洋红/青低透明光斑；浅色为雾白底 + 同色系淡光斑。
///
/// 光斑是静态的（不逐帧动画），保证玻璃模糊 + 长列表滚动时的帧率稳定；
/// 动态感由状态呼吸点、按钮按压、页面过渡提供。
class GlassAmbientBackground extends StatelessWidget {
  const GlassAmbientBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[c.canvasTop, c.canvasBottom],
              ),
            ),
          ),
          CustomPaint(painter: _BlobPainter(c)),
          // 顶部柔光，让大标题区有"光从上方来"的感觉。
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: const Alignment(0, -0.15),
                colors: <Color>[
                  (c.isDark ? Colors.white : Colors.white).withValues(
                    alpha: c.isDark ? 0.04 : 0.45,
                  ),
                  Colors.transparent,
                ],
              ),
            ),
          ),
          CustomPaint(painter: _GrainPainter(c)),
        ],
      ),
    );
  }
}

class _BlobPainter extends CustomPainter {
  const _BlobPainter(this.colors);

  final GlassColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;

    // 主光斑：左上紫、右上洋红、左下蓝紫、右下青。
    _blob(canvas, Offset(w * -0.12, h * 0.05), w * 0.92, colors.blobs[0]);
    _blob(canvas, Offset(w * 1.06, h * 0.20), w * 0.74, colors.blobs[1]);
    _blob(canvas, Offset(w * 0.08, h * 0.94), w * 0.86, colors.blobs[3]);
    _blob(canvas, Offset(w * 0.98, h * 0.86), w * 0.66, colors.blobs[2]);

    // 中部极淡的补光，避免中间发死。
    _blob(
      canvas,
      Offset(w * 0.5, h * 0.46),
      w * 0.62,
      colors.blobs[0].withValues(alpha: colors.blobs[0].a * 0.35),
    );

    // 暗角：让四周沉下去，玻璃更亮。
    final Paint vignette = Paint()
      ..shader = ui.Gradient.radial(
        Offset(w * 0.5, h * 0.42),
        math.max(w, h) * 0.82,
        <Color>[
          Colors.transparent,
          Colors.black.withValues(alpha: colors.isDark ? 0.52 : 0.06),
        ],
        const <double>[0.55, 1],
      );
    canvas.drawRect(Offset.zero & size, vignette);
  }

  void _blob(Canvas canvas, Offset center, double radius, Color color) {
    final Paint paint = Paint()
      ..shader = ui.Gradient.radial(
        center,
        radius,
        <Color>[color, color.withValues(alpha: 0)],
        const <double>[0, 1],
      );
    canvas.drawCircle(center, radius, paint);
  }

  @override
  bool shouldRepaint(_BlobPainter oldDelegate) => oldDelegate.colors != colors;
}

/// 极淡颗粒噪点：消除大面积渐变的"塑料感"，让玻璃更像真实磨砂材质。
class _GrainPainter extends CustomPainter {
  const _GrainPainter(this.colors);

  final GlassColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    final int count = (size.width * size.height / 1600).clamp(0, 2600).round();
    if (count == 0) return;
    final math.Random random = math.Random(7);
    final Paint paint = Paint()..color = colors.grain;
    for (int i = 0; i < count; i++) {
      final double x = random.nextDouble() * size.width;
      final double y = random.nextDouble() * size.height;
      canvas.drawRect(Rect.fromLTWH(x, y, 1.1, 1.1), paint);
    }
  }

  @override
  bool shouldRepaint(_GrainPainter oldDelegate) => oldDelegate.colors != colors;
}
