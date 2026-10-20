import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/glass_tokens.dart';

/// 细信号条：录制中有一条光带在轨道上循环滑动；停止后变为静态暗轨。
class SignalBar extends StatefulWidget {
  const SignalBar({
    super.key,
    required this.color,
    this.active = true,
    this.height = 3,
    this.radius = 99,
  });

  final Color color;
  final bool active;
  final double height;
  final double radius;

  @override
  State<SignalBar> createState() => _SignalBarState();
}

class _SignalBarState extends State<SignalBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(SignalBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final bool shouldAnimate =
        widget.active && !MediaQuery.disableAnimationsOf(context);
    if (shouldAnimate) {
      if (!_controller.isAnimating) {
        _controller.repeat();
      }
    } else {
      if (_controller.isAnimating) {
        _controller.stop();
      }
      _controller.value = 0;
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
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) {
        return SizedBox(
          height: widget.height,
          child: CustomPaint(
            painter: _SignalPainter(
              track: c.divider,
              color: widget.color,
              progress: _controller.value,
              active: widget.active,
            ),
          ),
        );
      },
    );
  }
}

class _SignalPainter extends CustomPainter {
  const _SignalPainter({
    required this.track,
    required this.color,
    required this.progress,
    required this.active,
  });

  final Color track;
  final Color color;
  final double progress;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final RRect trackRect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(size.height),
    );
    canvas.drawRRect(trackRect, Paint()..color = track);

    if (!active) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 0, size.width * 0.32, size.height),
          Radius.circular(size.height),
        ),
        Paint()..color = color.withValues(alpha: 0.5),
      );
      return;
    }

    final double bandWidth = math.max(size.width * 0.3, 28);
    final double travel = size.width + bandWidth;
    final double start = progress * travel - bandWidth;
    final Rect band = Rect.fromLTWH(start, 0, bandWidth, size.height);
    final Paint paint = Paint()
      ..shader = LinearGradient(
        colors: <Color>[
          color.withValues(alpha: 0),
          color.withValues(alpha: 0.85),
          color.withValues(alpha: 0),
        ],
      ).createShader(band);
    canvas.save();
    canvas.clipRRect(trackRect);
    canvas.drawRect(band, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SignalPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.color != color ||
      oldDelegate.active != active ||
      oldDelegate.track != track;
}
