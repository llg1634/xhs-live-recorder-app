import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'glass_palette.dart';
import 'glass_tokens.dart';

/// 主题入口：液态玻璃的深/浅两套主题 × 6 套主题色。
///
/// 玻璃质感本身由 `lib/ui/widgets/glass_*` 实现，这里只提供：
/// Material 组件兜底配色、中文排版、路由过渡、SnackBar / 输入框等基础样式。
class AppTheme {
  static const brand = Color(0xFFFF2455);

  static ThemeData light([GlassPalette palette = GlassPalette.pinkPurple]) =>
      _build(GlassPalettes.colorsOf(palette, Brightness.light));

  static ThemeData dark([GlassPalette palette = GlassPalette.pinkPurple]) =>
      _build(GlassPalettes.colorsOf(palette, Brightness.dark));

  static ThemeData _build(GlassColors c) {
    final bool dark = c.isDark;
    final ColorScheme scheme =
        ColorScheme.fromSeed(
          seedColor: c.accent,
          brightness: c.brightness,
        ).copyWith(
          primary: c.accent,
          onPrimary: Colors.white,
          secondary: c.accentAlt,
          onSecondary: Colors.white,
          surface: c.canvasBottom,
          onSurface: c.textPrimary,
          surfaceContainerHighest: c.fieldFill,
          error: c.danger,
          onError: Colors.white,
          outline: c.divider,
          outlineVariant: c.divider,
          surfaceTint: Colors.transparent,
          shadow: Colors.black,
        );

    final TextTheme text = TextTheme(
      displayLarge: GlassText.display(c, color: c.textPrimary),
      displayMedium: GlassText.display(c, color: c.textPrimary),
      displaySmall: GlassText.headline(c, color: c.textPrimary),
      headlineLarge: GlassText.headline(c, color: c.textPrimary),
      headlineMedium: GlassText.headline(c, color: c.textPrimary),
      headlineSmall: GlassText.title(c, color: c.textPrimary),
      titleLarge: GlassText.title(c, color: c.textPrimary),
      titleMedium: GlassText.label(c, color: c.textPrimary),
      titleSmall: GlassText.label(c, color: c.textSecondary),
      bodyLarge: GlassText.body(c, color: c.textPrimary),
      bodyMedium: GlassText.body(c, color: c.textPrimary),
      bodySmall: GlassText.caption(c, color: c.textSecondary),
      labelLarge: GlassText.label(c, color: c.textPrimary),
      labelMedium: GlassText.caption(c, color: c.textSecondary),
      labelSmall: GlassText.micro(c, color: c.textTertiary),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: c.brightness,
      colorScheme: scheme,
      extensions: <ThemeExtension<dynamic>>[c],
      textTheme: text,
      primaryTextTheme: text,
      scaffoldBackgroundColor: c.canvasBottom,
      canvasColor: c.canvasBottom,
      shadowColor: Colors.black,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      hoverColor: Colors.white.withValues(alpha: 0.04),
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      splashColor: Colors.transparent,
      dividerColor: c.divider,
      dividerTheme: DividerThemeData(color: c.divider, thickness: 1, space: 1),
      iconTheme: IconThemeData(color: c.textSecondary, size: 22),
      primaryIconTheme: IconThemeData(color: c.textPrimary),
      appBarTheme: AppBarThemeData(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: GlassText.title(c),
        iconTheme: IconThemeData(color: c.textPrimary),
        systemOverlayStyle: dark
            ? SystemUiOverlayStyle.light.copyWith(
                statusBarColor: Colors.transparent,
                systemNavigationBarColor: Colors.transparent,
              )
            : SystemUiOverlayStyle.dark.copyWith(
                statusBarColor: Colors.transparent,
                systemNavigationBarColor: Colors.transparent,
              ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: dark
            ? const Color(0xFF1A1D29).withValues(alpha: 0.97)
            : const Color(0xFF232637).withValues(alpha: 0.97),
        contentTextStyle: GlassText.body(c, color: Colors.white),
        actionTextColor: c.isDark ? c.cyan : const Color(0xFF9BE7FF),
        elevation: 0,
        insetPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(GlassTokens.radiusMd),
        ),
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        modalBarrierColor: Colors.transparent,
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: c.accent,
        selectionColor: c.accent.withValues(alpha: 0.28),
        selectionHandleColor: c.accent,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.fieldFill,
        hintStyle: GlassText.body(c, color: c.textTertiary),
        labelStyle: GlassText.body(c, color: c.textSecondary),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 13,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(GlassTokens.radiusMd),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(GlassTokens.radiusMd),
          borderSide: BorderSide(color: c.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(GlassTokens.radiusMd),
          borderSide: BorderSide(color: c.accent.withValues(alpha: 0.55)),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: c.accent,
        linearTrackColor: c.divider,
        circularTrackColor: Colors.transparent,
      ),
      pageTransitionsTheme: PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          for (final TargetPlatform platform in TargetPlatform.values)
            platform: const FadeForwardsPageTransitionsBuilder(),
        },
      ),
    );
  }
}
