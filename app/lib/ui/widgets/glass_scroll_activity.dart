import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// 向页面内所有 [GlassSurface] 广播"正在滚动"。
///
/// 滚动期间玻璃模糊是持续重算的大头：滚动时把 sigma 降到约 38%，停止后恢复。
/// 这里用 [InheritedNotifier] 而不是 `setState` 重建整页，只有各玻璃面板内部的
/// `BackdropFilter` 子树会重建，页面/列表本身不重建。
class GlassScrollActivity extends InheritedNotifier<ValueNotifier<bool>> {
  const GlassScrollActivity({
    super.key,
    required ValueNotifier<bool> scrolling,
    required super.child,
  }) : super(notifier: scrolling);

  /// 不建立依赖地取出滚动状态：订阅交给各面板内部的 ValueListenableBuilder，
  /// 避免一次滚动开始导致整棵页面树 rebuild。
  static ValueListenable<bool>? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<GlassScrollActivity>()?.notifier;
}
