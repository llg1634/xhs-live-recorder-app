import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 液态玻璃（Liquid Glass）设计令牌：圆角、间距、模糊强度、动效时长。
///
/// 所有 UI 子模块统一从这里取值，避免各页面自己发明间距/圆角。
abstract final class GlassTokens {
  // 圆角
  static const double radiusSm = 12;
  static const double radiusMd = 18;
  static const double radiusCard = 22;
  static const double radiusLg = 26;
  static const double radiusXl = 30;
  static const double radiusPill = 999;

  // 间距
  static const double gapXs = 6;
  static const double gapSm = 8;
  static const double gap = 12;
  static const double gapLg = 16;
  static const double gapXl = 22;
  static const double gapXxl = 28;
  static const double pagePadding = 20;
  static const double maxContentWidth = 720;

  // 模糊
  static const double blurSm = 12;
  static const double blur = 18;
  static const double blurLg = 28;

  // 尺寸
  static const double navBarHeight = 66;
  static const double navBarMargin = 18;
  static const double buttonHeight = 54;
  static const double iconButtonSize = 38;

  // 动效
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration medium = Duration(milliseconds: 240);
  static const Duration slow = Duration(milliseconds: 380);
  static const Duration breathe = Duration(milliseconds: 1500);
  static const Duration pageTransition = Duration(milliseconds: 300);

  static const Curve easeOut = Curves.easeOutCubic;
  static const Curve easeInOut = Curves.easeInOutCubic;

  /// 中文排版回退链：Android 走系统 Noto Sans CJK，桌面端回退到平台中文字体。
  static const List<String> fontFallback = <String>[
    'Noto Sans CJK SC',
    'Noto Sans SC',
    'Source Han Sans SC',
    'PingFang SC',
    'Microsoft YaHei',
    'Heiti SC',
  ];

  /// 页面滚动区底部留白（给悬浮 Tab 栏让位）。
  static double pageBottomInset(BuildContext context) =>
      navBarHeight + navBarMargin + 26 + MediaQuery.paddingOf(context).bottom;
}

/// 主题相关配色。6 套主题色 × 深/浅色均按「真实可读」校准：
/// 次要文字对比度不低于 4.5:1，正文不低于 7:1。
@immutable
class GlassColors extends ThemeExtension<GlassColors> {
  const GlassColors({
    required this.brightness,
    required this.canvasTop,
    required this.canvasBottom,
    required this.blobs,
    required this.glassTint,
    required this.glassFillTop,
    required this.glassFillBottom,
    required this.glassBorderTop,
    required this.glassBorderBottom,
    required this.glassShadow,
    required this.cardShadow,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.accent,
    required this.accentAlt,
    required this.cyan,
    required this.success,
    required this.warning,
    required this.danger,
    required this.fieldFill,
    required this.divider,
    required this.scrim,
    required this.grain,
    required this.sheen,
  });

  final Brightness brightness;

  /// 背景渐变（上→下）。
  final Color canvasTop;
  final Color canvasBottom;

  /// 氛围光斑（主色 / 辅色 / 冷色 / 补光）。
  final List<Color> blobs;

  /// 玻璃填充的染色倾向（由当前配色方案决定，深浅模式各自校准）。
  final Color glassTint;

  final Color glassFillTop;
  final Color glassFillBottom;

  /// 1px 高光描边（左上 → 右下）。
  final Color glassBorderTop;
  final Color glassBorderBottom;

  /// 玻璃外阴影（贴画面用）。
  final Color glassShadow;

  /// 卡片外阴影。
  final Color cardShadow;

  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;

  final Color accent;
  final Color accentAlt;
  final Color cyan;
  final Color success;
  final Color warning;
  final Color danger;

  /// 输入框 / 内嵌小块的填充。
  final Color fieldFill;

  final Color divider;
  final Color scrim;

  /// 背景颗粒噪点。
  final Color grain;

  /// 玻璃高光。
  final Color sheen;

  bool get isDark => brightness == Brightness.dark;

  /// 读取当前主题注入的调色板。
  ///
  /// 由 [AppTheme] 通过 [ThemeData.extensions] 注入；缺少扩展时回退到默认
  /// 粉紫方案，保证单独 pump 某个页面时也不会崩。
  static GlassColors of(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return theme.extension<GlassColors>() ??
        (theme.brightness == Brightness.dark ? dark : light);
  }

  @override
  GlassColors copyWith() => this;

  /// 主题切换时由 MaterialApp 的主题动画调用；逐字段插值，避免深浅切换时
  /// 玻璃层出现突兀的"半套颜色"。
  @override
  GlassColors lerp(covariant GlassColors? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    List<Color> mixList(List<Color> a, List<Color> b) {
      if (a.length != b.length) return t < 0.5 ? a : b;
      return <Color>[for (int i = 0; i < a.length; i++) mix(a[i], b[i])];
    }

    return GlassColors(
      brightness: t < 0.5 ? brightness : other.brightness,
      canvasTop: mix(canvasTop, other.canvasTop),
      canvasBottom: mix(canvasBottom, other.canvasBottom),
      blobs: mixList(blobs, other.blobs),
      glassTint: mix(glassTint, other.glassTint),
      glassFillTop: mix(glassFillTop, other.glassFillTop),
      glassFillBottom: mix(glassFillBottom, other.glassFillBottom),
      glassBorderTop: mix(glassBorderTop, other.glassBorderTop),
      glassBorderBottom: mix(glassBorderBottom, other.glassBorderBottom),
      glassShadow: mix(glassShadow, other.glassShadow),
      cardShadow: mix(cardShadow, other.cardShadow),
      textPrimary: mix(textPrimary, other.textPrimary),
      textSecondary: mix(textSecondary, other.textSecondary),
      textTertiary: mix(textTertiary, other.textTertiary),
      accent: mix(accent, other.accent),
      accentAlt: mix(accentAlt, other.accentAlt),
      cyan: mix(cyan, other.cyan),
      success: mix(success, other.success),
      warning: mix(warning, other.warning),
      danger: mix(danger, other.danger),
      fieldFill: mix(fieldFill, other.fieldFill),
      divider: mix(divider, other.divider),
      scrim: mix(scrim, other.scrim),
      grain: mix(grain, other.grain),
      sheen: mix(sheen, other.sheen),
    );
  }

  /// 深色默认（粉紫）：近黑底 + 主题色低透明光斑。
  static const GlassColors dark = GlassColors(
    brightness: Brightness.dark,
    canvasTop: Color(0xFF05060B),
    canvasBottom: Color(0xFF0A0C13),
    blobs: <Color>[
      Color(0x7A6D3BFF), // 紫
      Color(0x52FF2E7E), // 洋红
      Color(0x3812C2E9), // 青
      Color(0x4D2B3BFF), // 蓝紫
    ],
    glassTint: Color(0xFF6D3BFF),
    glassFillTop: Color(0x42161A26),
    glassFillBottom: Color(0x1F0C0E16),
    glassBorderTop: Color(0x5CFFFFFF),
    glassBorderBottom: Color(0x0FFFFFFF),
    glassShadow: Color(0x66000000),
    cardShadow: Color(0x66000000),
    textPrimary: Color(0xFFF4F6FB),
    textSecondary: Color(0xFFADB4C6),
    textTertiary: Color(0xFF828B9E),
    accent: Color(0xFFFF3D7F),
    accentAlt: Color(0xFFA855F7),
    cyan: Color(0xFF3BDCF2),
    success: Color(0xFF3DDC97),
    warning: Color(0xFFFBBF24),
    danger: Color(0xFFFF5C6C),
    fieldFill: Color(0x2B000000),
    divider: Color(0x1FFFFFFF),
    scrim: Color(0xA605060B),
    grain: Color(0x0DFFFFFF),
    sheen: Color(0x1AFFFFFF),
  );

  /// 浅色默认（粉紫）：雾白底 + 同色系淡光斑。
  static const GlassColors light = GlassColors(
    brightness: Brightness.light,
    canvasTop: Color(0xFFFBFBFF),
    canvasBottom: Color(0xFFECEEF8),
    blobs: <Color>[
      Color(0x427C5CFF),
      Color(0x33FF5C93),
      Color(0x2D35C7E0),
      Color(0x267B8CFF),
    ],
    glassTint: Color(0xFF7C5CFF),
    glassFillTop: Color(0xC2FFFFFF),
    glassFillBottom: Color(0x85FFFFFF),
    glassBorderTop: Color(0xF2FFFFFF),
    glassBorderBottom: Color(0x4DFFFFFF),
    glassShadow: Color(0x14402F6B),
    cardShadow: Color(0x1F3B2F66),
    textPrimary: Color(0xFF12141C),
    textSecondary: Color(0xFF4E5568),
    textTertiary: Color(0xFF6B7284),
    accent: Color(0xFFE11D63),
    accentAlt: Color(0xFF7C3AED),
    cyan: Color(0xFF0891B2),
    success: Color(0xFF059669),
    warning: Color(0xFFB45309),
    danger: Color(0xFFDC2626),
    fieldFill: Color(0x8FFFFFFF),
    divider: Color(0x1A000000),
    scrim: Color(0x990B0918),
    grain: Color(0x0A000000),
    sheen: Color(0xB8FFFFFF),
  );

  /// 玻璃填充渐变。
  LinearGradient get glassFill => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[glassFillTop, glassFillBottom],
  );

  /// 1px 高光描边渐变。
  LinearGradient get glassBorder => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[glassBorderTop, glassBorderBottom],
    stops: const <double>[0, 1],
  );

  /// 玻璃内部高光（顶部白 + 右下极淡）。
  LinearGradient get glassSheen => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[
      sheen,
      sheen.withValues(alpha: 0),
      sheen.withValues(alpha: sheen.a * 0.35),
    ],
    stops: const <double>[0, 0.55, 1],
  );

  /// 卡片外阴影：深色靠黑色投影造悬浮感，浅色极轻。
  List<BoxShadow> cardShadows({double blur = 30, double dy = 16}) =>
      <BoxShadow>[
        BoxShadow(
          color: cardShadow,
          blurRadius: blur,
          offset: Offset(0, dy),
          spreadRadius: -8,
        ),
      ];

  /// 品牌渐变：当前主题色 → 辅助色。
  LinearGradient get brandGradient => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[accent, accentAlt],
  );
}

/// 排版：标题字重 700–800，正文 13–14，次要信息用 60% 透明度。
abstract final class GlassText {
  /// Android 系统自带 Roboto（拉丁字母），中文走 [GlassTokens.fontFallback]。
  static const String _fontFamily = 'Roboto';
  static const List<String> _fallback = GlassTokens.fontFallback;

  static TextStyle display(GlassColors c, {Color? color}) => TextStyle(
    fontSize: 32,
    height: 1.16,
    fontWeight: FontWeight.w800,
    letterSpacing: -0.5,
    color: color ?? c.textPrimary,
    fontFamily: _fontFamily,
    fontFamilyFallback: _fallback,
  );

  static TextStyle headline(GlassColors c, {Color? color}) => TextStyle(
    fontSize: 24,
    height: 1.22,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.3,
    color: color ?? c.textPrimary,
    fontFamily: _fontFamily,
    fontFamilyFallback: _fallback,
  );

  static TextStyle title(GlassColors c, {Color? color}) => TextStyle(
    fontSize: 17,
    height: 1.3,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.1,
    color: color ?? c.textPrimary,
    fontFamily: _fontFamily,
    fontFamilyFallback: _fallback,
  );

  static TextStyle body(GlassColors c, {Color? color}) => TextStyle(
    fontSize: 14,
    height: 1.45,
    fontWeight: FontWeight.w500,
    color: color ?? c.textPrimary,
    fontFamily: _fontFamily,
    fontFamilyFallback: _fallback,
  );

  static TextStyle label(GlassColors c, {Color? color}) => TextStyle(
    fontSize: 13,
    height: 1.3,
    fontWeight: FontWeight.w600,
    color: color ?? c.textPrimary,
    fontFamily: _fontFamily,
    fontFamilyFallback: _fallback,
  );

  static TextStyle caption(GlassColors c, {Color? color}) => TextStyle(
    fontSize: 12.5,
    height: 1.4,
    fontWeight: FontWeight.w500,
    color: color ?? c.textSecondary,
    fontFamily: _fontFamily,
    fontFamilyFallback: _fallback,
  );

  static TextStyle micro(GlassColors c, {Color? color}) => TextStyle(
    fontSize: 11,
    height: 1.25,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.2,
    color: color ?? c.textTertiary,
    fontFamily: _fontFamily,
    fontFamilyFallback: _fallback,
  );

  /// 数字（体积 / 速率 / 时长）等宽，避免跳动。
  static TextStyle numeric(GlassColors c, {double size = 14, Color? color}) =>
      TextStyle(
        fontSize: size,
        height: 1.2,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
        color: color ?? c.textPrimary,
        fontFeatures: const <ui.FontFeature>[ui.FontFeature.tabularFigures()],
        fontFamily: _fontFamily,
        fontFamilyFallback: _fallback,
      );
}
