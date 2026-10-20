import 'package:flutter/material.dart';

/// 主题入口。UI 子代理可整体重写本文件与 `lib/ui/**`。
class AppTheme {
  static const brand = Color(0xFFFF2455);

  static ThemeData light() => ThemeData(
        brightness: Brightness.light,
        useMaterial3: true,
        colorSchemeSeed: brand,
        scaffoldBackgroundColor: const Color(0xFFF4F5F9),
      );

  static ThemeData dark() => ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        colorSchemeSeed: brand,
        scaffoldBackgroundColor: const Color(0xFF0B0D12),
      );
}
