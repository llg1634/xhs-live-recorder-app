import 'package:flutter/material.dart';

import '../../theme/glass_tokens.dart';
import 'glass_button.dart';
import 'glass_surface.dart';
import 'pressable.dart';

/// 玻璃确认框（删除等破坏性操作二次确认）。
Future<bool> showGlassConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = '确定',
  String cancelLabel = '取消',
  IconData icon = Icons.delete_outline_rounded,
  bool destructive = false,
}) async {
  final GlassColors colors = GlassColors.of(context);
  final bool? result = await showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: cancelLabel,
    barrierColor: colors.scrim,
    transitionDuration: GlassTokens.medium,
    pageBuilder:
        (
          BuildContext dialogContext,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
        ) {
          return Material(
            type: MaterialType.transparency,
            child: _DialogShell(
              icon: icon,
              destructive: destructive,
              title: title,
              message: message,
              cancelLabel: cancelLabel,
              confirmLabel: confirmLabel,
            ),
          );
        },
    transitionBuilder:
        (
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
          Widget child,
        ) {
          final Animation<double> curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.94, end: 1).animate(curved),
              child: child,
            ),
          );
        },
  );
  return result ?? false;
}

class _DialogShell extends StatelessWidget {
  const _DialogShell({
    required this.icon,
    required this.destructive,
    required this.title,
    required this.message,
    required this.cancelLabel,
    required this.confirmLabel,
  });

  final IconData icon;
  final bool destructive;
  final String title;
  final String message;
  final String cancelLabel;
  final String confirmLabel;

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    final Color tone = destructive ? c.danger : c.accent;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: GlassSurface(
            radius: GlassTokens.radiusXl,
            blur: GlassTokens.blurLg,
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
            shadow: true,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  width: 46,
                  height: 46,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    color: tone.withValues(alpha: c.isDark ? 0.18 : 0.13),
                    border: Border.all(color: tone.withValues(alpha: 0.35)),
                  ),
                  child: Icon(icon, size: 23, color: tone),
                ),
                const SizedBox(height: GlassTokens.gapLg),
                Text(title, style: GlassText.title(c).copyWith(fontSize: 18)),
                const SizedBox(height: GlassTokens.gapSm),
                Text(
                  message,
                  style: GlassText.caption(
                    c,
                    color: c.textSecondary,
                  ).copyWith(fontSize: 13, height: 1.55),
                ),
                const SizedBox(height: GlassTokens.gapXl),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: GlassButton(
                        label: cancelLabel,
                        variant: GlassButtonVariant.glass,
                        height: 46,
                        fontSize: 14,
                        onPressed: () => Navigator.of(context).pop(false),
                      ),
                    ),
                    const SizedBox(width: GlassTokens.gap),
                    Expanded(
                      child: GlassButton(
                        label: confirmLabel,
                        height: 46,
                        fontSize: 14,
                        gradient: destructive
                            ? <Color>[c.danger, const Color(0xFFE11D63)]
                            : null,
                        onPressed: () => Navigator.of(context).pop(true),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 玻璃底部动作面板（长按录像卡片时出现）。
class GlassAction {
  const GlassAction({
    required this.value,
    required this.label,
    this.icon,
    this.destructive = false,
  });

  final String value;
  final String label;
  final IconData? icon;
  final bool destructive;
}

Future<String?> showGlassActionSheet(
  BuildContext context, {
  required String title,
  String? subtitle,
  required List<GlassAction> actions,
  String cancelLabel = '取消',
}) {
  final GlassColors colors = GlassColors.of(context);
  return showGeneralDialog<String>(
    context: context,
    barrierDismissible: true,
    barrierLabel: cancelLabel,
    barrierColor: colors.scrim,
    transitionDuration: GlassTokens.medium,
    pageBuilder:
        (
          BuildContext dialogContext,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
        ) {
          return Material(
            type: MaterialType.transparency,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  14,
                  0,
                  14,
                  14 + MediaQuery.paddingOf(dialogContext).bottom,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: GlassSurface(
                    radius: GlassTokens.radiusLg,
                    blur: GlassTokens.blurLg,
                    padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GlassText.title(
                                  GlassColors.of(dialogContext),
                                ).copyWith(fontSize: 15.5),
                              ),
                              if (subtitle != null) ...<Widget>[
                                const SizedBox(height: 4),
                                Text(
                                  subtitle,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: GlassText.caption(
                                    GlassColors.of(dialogContext),
                                    color: GlassColors.of(dialogContext)
                                        .textSecondary,
                                  ).copyWith(fontSize: 12),
                                ),
                              ],
                            ],
                          ),
                        ),
                        for (final GlassAction action in actions)
                          _ActionRow(action: action),
                        const SizedBox(height: 6),
                        GlassDivider(indent: 10, endIndent: 10),
                        const SizedBox(height: 4),
                        Pressable(
                          onTap: () => Navigator.of(dialogContext).pop(),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            child: Center(
                              child: Text(
                                cancelLabel,
                                style:
                                    GlassText.label(
                                      GlassColors.of(dialogContext),
                                    ).copyWith(
                                      fontSize: 14,
                                      color: GlassColors.of(dialogContext)
                                          .textSecondary,
                                    ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
    transitionBuilder:
        (
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
          Widget child,
        ) {
          final Animation<double> curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.12),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          );
        },
  );
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.action});

  final GlassAction action;

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    final Color tone = action.destructive ? c.danger : c.textPrimary;
    return Pressable(
      onTap: () => Navigator.of(context).pop(action.value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(GlassTokens.radiusMd),
            color: action.destructive
                ? c.danger.withValues(alpha: c.isDark ? 0.1 : 0.08)
                : Colors.transparent,
          ),
          child: Row(
            children: <Widget>[
              if (action.icon != null) ...<Widget>[
                Icon(action.icon, size: 19, color: tone),
                const SizedBox(width: 12),
              ],
              Text(
                action.label,
                style: GlassText.label(c, color: tone).copyWith(fontSize: 14.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
