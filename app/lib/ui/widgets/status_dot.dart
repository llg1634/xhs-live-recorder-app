import 'package:flutter/material.dart';

import '../../theme/glass_tokens.dart';

/// 状态呼吸点：录制中 / 重连中会持续"呼吸"，其余状态为静态圆点。
class BreathingDot extends StatefulWidget {
  const BreathingDot({
    super.key,
    required this.color,
    this.size = 8,
    this.active = true,
    this.glow = true,
  });

  final Color color;
  final double size;

  /// 是否呼吸（非活动状态 / 系统关闭动画时静态显示）。
  final bool active;
  final bool glow;

  @override
  State<BreathingDot> createState() => _BreathingDotState();
}

class _BreathingDotState extends State<BreathingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: GlassTokens.breathe,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(BreathingDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final bool shouldAnimate =
        widget.active && !MediaQuery.disableAnimationsOf(context);
    if (shouldAnimate) {
      if (!_controller.isAnimating) {
        _controller.repeat(reverse: true);
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
    final double side = widget.size * 2.1;
    return SizedBox(
      width: side,
      height: side,
      child: Center(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (BuildContext context, Widget? child) {
            final double t = Curves.easeInOut.transform(_controller.value);
            return Stack(
              alignment: Alignment.center,
              children: <Widget>[
                Transform.scale(
                  scale: 1 + t * 1.05,
                  child: Container(
                    width: widget.size,
                    height: widget.size,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: widget.color.withValues(alpha: (1 - t) * 0.45),
                    ),
                  ),
                ),
                Container(
                  width: widget.size,
                  height: widget.size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.color,
                    boxShadow: widget.glow
                        ? <BoxShadow>[
                            BoxShadow(
                              color: widget.color.withValues(alpha: 0.65),
                              blurRadius: 7,
                              spreadRadius: 0.5,
                            ),
                          ]
                        : null,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
