import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../services/comment_capture.dart';

/// 弹幕采集层：**挂在 App 内容下面**的隐藏 WebView 层。
///
/// 为什么必须真实渲染：实测把 WebView 缩成 1×1 或者移出屏幕，
/// 小红书页面就不会挂载评论区，也就不会订阅评论 topic，收不到弹幕；
/// 只有"真实视口 + 被遮挡"才稳定。详见 docs/comments.md。
///
/// 因此这里让所有采集 WebView **共用同一个位置**（0,0,420×900）叠放，
/// 最上面再盖一层与背景同色的挡板；整层又位于 App UI 之下，用户不可见。
class CommentCaptureLayer extends StatelessWidget {
  const CommentCaptureLayer({super.key});

  static const double width = 420;
  static const double height = 900;

  @override
  Widget build(BuildContext context) {
    final manager = context.watch<CommentCaptureManager>();
    final controllers = manager.captures
        .map((c) => c.controller)
        .whereType<WebViewController>()
        .toList();
    if (controllers.isEmpty) return const SizedBox.shrink();

    // 盖板颜色用页面背景深色，万一上层有半透明区域也不会漏出网页内容。
    const cover = ColoredBox(color: Color(0xFF121216));

    return IgnorePointer(
      child: ExcludeSemantics(
        child: ClipRect(
          child: SizedBox(
            width: width,
            height: height,
            child: Stack(
              children: [
                for (final controller in controllers)
                  Positioned.fill(
                    child: WebViewWidget(controller: controller),
                  ),
                const Positioned.fill(child: cover),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
