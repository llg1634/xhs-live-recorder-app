import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/glass_tokens.dart';

/// 可点击区域的统一反馈：轻微缩放 + 触感反馈（水波被缩放替代，避免在玻璃上出现白色墨迹）。
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.pressedScale = 0.985,
    this.haptic = true,
    this.behavior = HitTestBehavior.opaque,
    this.cursor = SystemMouseCursors.click,
    this.semanticLabel,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double pressedScale;
  final bool haptic;
  final HitTestBehavior behavior;
  final MouseCursor cursor;
  final String? semanticLabel;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _pressed = false;

  bool get _enabled => widget.onTap != null || widget.onLongPress != null;

  void _setPressed(bool value) {
    if (!_enabled || _pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    Widget content = AnimatedScale(
      scale: _pressed && !reduceMotion ? widget.pressedScale : 1,
      duration: GlassTokens.fast,
      curve: GlassTokens.easeOut,
      child: widget.child,
    );

    if (widget.semanticLabel != null) {
      content = Semantics(
        label: widget.semanticLabel,
        button: true,
        child: content,
      );
    }

    return MouseRegion(
      cursor: _enabled ? widget.cursor : MouseCursor.defer,
      child: GestureDetector(
        behavior: widget.behavior,
        onTapDown: _enabled ? (_) => _setPressed(true) : null,
        onTapUp: _enabled ? (_) => _setPressed(false) : null,
        onTapCancel: _enabled ? () => _setPressed(false) : null,
        onTap: widget.onTap == null
            ? null
            : () {
                if (widget.haptic) {
                  HapticFeedback.selectionClick();
                }
                widget.onTap!();
              },
        onLongPress: widget.onLongPress == null
            ? null
            : () {
                if (widget.haptic) {
                  HapticFeedback.mediumImpact();
                }
                widget.onLongPress!();
              },
        child: content,
      ),
    );
  }
}
