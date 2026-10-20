import 'package:flutter/material.dart';

import '../../theme/glass_tokens.dart';

/// 页面过渡：淡入 + 轻微上移，配合玻璃界面的"浮起"感。
Route<T> glassPageRoute<T>(
  BuildContext context, {
  required Widget page,
  RouteSettings? settings,
  bool fullscreenDialog = false,
}) {
  final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
  final Duration duration = reduceMotion
      ? Duration.zero
      : const Duration(milliseconds: 320);
  return PageRouteBuilder<T>(
    settings: settings,
    fullscreenDialog: fullscreenDialog,
    transitionDuration: duration,
    reverseTransitionDuration: reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 240),
    pageBuilder:
        (
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
        ) {
          return page;
        },
    transitionsBuilder:
        (
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
          Widget child,
        ) {
          if (reduceMotion) return child;
          final Animation<double> curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.025),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          );
        },
  );
}

/// 便捷打开方式。
Future<T?> pushGlassPage<T>(BuildContext context, Widget page) {
  return Navigator.of(context).push<T>(glassPageRoute<T>(context, page: page));
}

/// 大标题区块：标题 + 副标题 + 右侧附加组件。
class GlassPageHeader extends StatelessWidget {
  const GlassPageHeader({
    super.key,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.leading,
    this.compact = false,
  });

  final String title;
  final String subtitle;
  final Widget? trailing;
  final Widget? leading;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    final Widget text = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GlassText.display(c)
              .copyWith(fontSize: compact ? 26 : 30, height: 1.15),
        ),
        const SizedBox(height: 5),
        Text(
          subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: GlassText.caption(
            c,
            color: c.textSecondary,
          ).copyWith(fontSize: 12.5),
        ),
      ],
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        if (leading != null) ...<Widget>[
          leading!,
          const SizedBox(width: GlassTokens.gap),
        ],
        Expanded(child: text),
        if (trailing != null) ...<Widget>[
          const SizedBox(width: GlassTokens.gapSm),
          trailing!,
        ],
      ],
    );
  }
}

/// 小标题 + 右侧操作。
class GlassSectionHeader extends StatelessWidget {
  const GlassSectionHeader({
    super.key,
    required this.title,
    this.trailing,
    this.padding = EdgeInsets.zero,
  });

  final String title;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    return Padding(
      padding: padding,
      child: Row(
        children: <Widget>[
          Container(
            width: 3,
            height: 13,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(2),
              gradient: c.brandGradient,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GlassText.label(
                c,
                color: c.textSecondary,
              ).copyWith(fontSize: 12.5, letterSpacing: 0.3),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
