import 'package:flutter/material.dart';

import 'glass_tokens.dart';

/// 可切换的主题色方案。
///
/// 每套方案都提供深/浅两套独立校准过的 [GlassColors]：强调色、辅助色、
/// 语义色、玻璃 tint 与氛围光斑一起变化，避免只换 accent 造成"贴纸感"。
enum GlassPalette {
  pinkPurple('粉紫', '洋红 × 紫'),
  cyanBlue('青蓝', '天蓝 × 靛青'),
  mintGreen('薄荷绿', '薄荷 × 青碧'),
  amberOrange('琥珀橙', '琥珀 × 珊瑚'),
  roseRed('玫瑰红', '玫瑰 × 洋红'),
  graphite('石墨灰', '石墨 × 银灰');

  const GlassPalette(this.label, this.description);

  /// 设置页展示名。
  final String label;

  /// 设置页辅助说明。
  final String description;
}

/// 调色板注册表：`GlassPalette` → 深/浅 [GlassColors]。
abstract final class GlassPalettes {
  static GlassColors colorsOf(GlassPalette palette, Brightness brightness) =>
      (brightness == Brightness.dark ? _dark : _light)[palette]!;

  /// 深色模式：近黑底 + 低透明光斑，强调色保持高亮。
  static final Map<GlassPalette, GlassColors> _dark =
      <GlassPalette, GlassColors>{
        GlassPalette.pinkPurple: _darkColors(
          accent: const Color(0xFFFF3D7F),
          accentAlt: const Color(0xFFA855F7),
          cyan: const Color(0xFF3BDCF2),
          success: const Color(0xFF3DDC97),
          warning: const Color(0xFFFBBF24),
          danger: const Color(0xFFFF5C6C),
          glassTint: const Color(0xFF6D3BFF),
          canvasTop: const Color(0xFF05060B),
          canvasBottom: const Color(0xFF0A0C13),
          blobs: const <Color>[
            Color(0x7A6D3BFF),
            Color(0x52FF2E7E),
            Color(0x3812C2E9),
            Color(0x4D2B3BFF),
          ],
        ),
        GlassPalette.cyanBlue: _darkColors(
          accent: const Color(0xFF38BDF8),
          accentAlt: const Color(0xFF6366F1),
          cyan: const Color(0xFF22D3EE),
          success: const Color(0xFF34D399),
          warning: const Color(0xFFFBBF24),
          danger: const Color(0xFFFB7185),
          glassTint: const Color(0xFF2563EB),
          canvasTop: const Color(0xFF04070D),
          canvasBottom: const Color(0xFF080E18),
          blobs: const <Color>[
            Color(0x7A2563EB),
            Color(0x5238BDF8),
            Color(0x3822D3EE),
            Color(0x4D6366F1),
          ],
        ),
        GlassPalette.mintGreen: _darkColors(
          accent: const Color(0xFF34D399),
          accentAlt: const Color(0xFF22D3EE),
          cyan: const Color(0xFF5EEAD4),
          success: const Color(0xFF4ADE80),
          warning: const Color(0xFFFBBF24),
          danger: const Color(0xFFFB7185),
          glassTint: const Color(0xFF10B981),
          canvasTop: const Color(0xFF040B09),
          canvasBottom: const Color(0xFF081310),
          blobs: const <Color>[
            Color(0x7A10B981),
            Color(0x5234D399),
            Color(0x3822D3EE),
            Color(0x4D2DD4BF),
          ],
        ),
        GlassPalette.amberOrange: _darkColors(
          accent: const Color(0xFFF59E0B),
          accentAlt: const Color(0xFFFF6B4A),
          cyan: const Color(0xFF38BDF8),
          success: const Color(0xFF4ADE80),
          warning: const Color(0xFFFCD34D),
          danger: const Color(0xFFFB7185),
          glassTint: const Color(0xFFF59E0B),
          canvasTop: const Color(0xFF0B0704),
          canvasBottom: const Color(0xFF140D07),
          blobs: const <Color>[
            Color(0x7AF59E0B),
            Color(0x52FB923C),
            Color(0x38FACC15),
            Color(0x4DFB7185),
          ],
        ),
        GlassPalette.roseRed: _darkColors(
          accent: const Color(0xFFFB7185),
          accentAlt: const Color(0xFFD946EF),
          cyan: const Color(0xFF38BDF8),
          success: const Color(0xFF34D399),
          warning: const Color(0xFFFBBF24),
          danger: const Color(0xFFFF4D4D),
          glassTint: const Color(0xFFFB7185),
          canvasTop: const Color(0xFF0B0408),
          canvasBottom: const Color(0xFF150810),
          blobs: const <Color>[
            Color(0x7AFB7185),
            Color(0x52F472B6),
            Color(0x38D946EF),
            Color(0x4DEF4444),
          ],
        ),
        GlassPalette.graphite: _darkColors(
          accent: const Color(0xFF9CA3AF),
          accentAlt: const Color(0xFF6B7280),
          cyan: const Color(0xFF7DD3FC),
          success: const Color(0xFF86EFAC),
          warning: const Color(0xFFFDE68A),
          danger: const Color(0xFFF87171),
          glassTint: const Color(0xFF94A3B8),
          canvasTop: const Color(0xFF07080A),
          canvasBottom: const Color(0xFF0D0F12),
          blobs: const <Color>[
            Color(0x7A64748B),
            Color(0x5294A3B8),
            Color(0x38475569),
            Color(0x4DCBD5E1),
          ],
        ),
      };

  /// 浅色模式：雾白底 + 同色系淡光斑，强调色下压保证可读性。
  static final Map<GlassPalette, GlassColors> _light =
      <GlassPalette, GlassColors>{
        GlassPalette.pinkPurple: _lightColors(
          accent: const Color(0xFFE11D63),
          accentAlt: const Color(0xFF7C3AED),
          cyan: const Color(0xFF0891B2),
          success: const Color(0xFF059669),
          warning: const Color(0xFFB45309),
          danger: const Color(0xFFDC2626),
          glassTint: const Color(0xFF7C5CFF),
          canvasTop: const Color(0xFFFBFBFF),
          canvasBottom: const Color(0xFFECEEF8),
          blobs: const <Color>[
            Color(0x427C5CFF),
            Color(0x33FF5C93),
            Color(0x2D35C7E0),
            Color(0x267B8CFF),
          ],
        ),
        GlassPalette.cyanBlue: _lightColors(
          accent: const Color(0xFF0369A1),
          accentAlt: const Color(0xFF4338CA),
          cyan: const Color(0xFF0E7490),
          success: const Color(0xFF047857),
          warning: const Color(0xFFB45309),
          danger: const Color(0xFFE11D48),
          glassTint: const Color(0xFF3B82F6),
          canvasTop: const Color(0xFFF8FCFF),
          canvasBottom: const Color(0xFFE7F1FA),
          blobs: const <Color>[
            Color(0x423B82F6),
            Color(0x330EA5E9),
            Color(0x2D22D3EE),
            Color(0x266366F1),
          ],
        ),
        GlassPalette.mintGreen: _lightColors(
          accent: const Color(0xFF047857),
          accentAlt: const Color(0xFF0F766E),
          cyan: const Color(0xFF0E7490),
          success: const Color(0xFF15803D),
          warning: const Color(0xFFB45309),
          danger: const Color(0xFFDC2626),
          glassTint: const Color(0xFF34D399),
          canvasTop: const Color(0xFFF7FFFB),
          canvasBottom: const Color(0xFFE7F4EE),
          blobs: const <Color>[
            Color(0x4234D399),
            Color(0x3322D3EE),
            Color(0x2D5EEAD4),
            Color(0x2610B981),
          ],
        ),
        GlassPalette.amberOrange: _lightColors(
          accent: const Color(0xFFB45309),
          accentAlt: const Color(0xFFC2410C),
          cyan: const Color(0xFF0369A1),
          success: const Color(0xFF047857),
          warning: const Color(0xFFA16207),
          danger: const Color(0xFFDC2626),
          glassTint: const Color(0xFFF59E0B),
          canvasTop: const Color(0xFFFFFCF5),
          canvasBottom: const Color(0xFFF7EEE2),
          blobs: const <Color>[
            Color(0x42F59E0B),
            Color(0x33FB923C),
            Color(0x2DFACC15),
            Color(0x26FB7185),
          ],
        ),
        GlassPalette.roseRed: _lightColors(
          accent: const Color(0xFFBE123C),
          accentAlt: const Color(0xFFA21CAF),
          cyan: const Color(0xFF0369A1),
          success: const Color(0xFF047857),
          warning: const Color(0xFFB45309),
          danger: const Color(0xFFDC2626),
          glassTint: const Color(0xFFFB7185),
          canvasTop: const Color(0xFFFFF8FA),
          canvasBottom: const Color(0xFFF8E9EE),
          blobs: const <Color>[
            Color(0x42FB7185),
            Color(0x33F472B6),
            Color(0x2DD946EF),
            Color(0x26EF4444),
          ],
        ),
        GlassPalette.graphite: _lightColors(
          accent: const Color(0xFF4B5563),
          accentAlt: const Color(0xFF1F2937),
          cyan: const Color(0xFF0369A1),
          success: const Color(0xFF047857),
          warning: const Color(0xFFB45309),
          danger: const Color(0xFFDC2626),
          glassTint: const Color(0xFF64748B),
          canvasTop: const Color(0xFFFAFAFC),
          canvasBottom: const Color(0xFFECEFF3),
          blobs: const <Color>[
            Color(0x425C6B7A),
            Color(0x3394A3B8),
            Color(0x2D64748B),
            Color(0x26CBD5E1),
          ],
        ),
      };

  static GlassColors _darkColors({
    required Color accent,
    required Color accentAlt,
    required Color cyan,
    required Color success,
    required Color warning,
    required Color danger,
    required Color glassTint,
    required Color canvasTop,
    required Color canvasBottom,
    required List<Color> blobs,
  }) {
    return GlassColors(
      brightness: Brightness.dark,
      canvasTop: canvasTop,
      canvasBottom: canvasBottom,
      blobs: List<Color>.unmodifiable(blobs),
      glassTint: glassTint,
      glassFillTop: _tintFill(const Color(0x42161A26), glassTint, 0.18),
      glassFillBottom: _tintFill(const Color(0x1F0C0E16), glassTint, 0.1),
      glassBorderTop: const Color(0x5CFFFFFF),
      glassBorderBottom: const Color(0x0FFFFFFF),
      glassShadow: const Color(0x66000000),
      cardShadow: const Color(0x66000000),
      textPrimary: const Color(0xFFF4F6FB),
      textSecondary: const Color(0xFFADB4C6),
      textTertiary: const Color(0xFF828B9E),
      accent: accent,
      accentAlt: accentAlt,
      cyan: cyan,
      success: success,
      warning: warning,
      danger: danger,
      fieldFill: const Color(0x2B000000),
      divider: const Color(0x1FFFFFFF),
      scrim: const Color(0xA605060B),
      grain: const Color(0x0DFFFFFF),
      sheen: const Color(0x1AFFFFFF),
    );
  }

  static GlassColors _lightColors({
    required Color accent,
    required Color accentAlt,
    required Color cyan,
    required Color success,
    required Color warning,
    required Color danger,
    required Color glassTint,
    required Color canvasTop,
    required Color canvasBottom,
    required List<Color> blobs,
  }) {
    return GlassColors(
      brightness: Brightness.light,
      canvasTop: canvasTop,
      canvasBottom: canvasBottom,
      blobs: List<Color>.unmodifiable(blobs),
      glassTint: glassTint,
      glassFillTop: _tintFill(const Color(0xC2FFFFFF), glassTint, 0.035),
      glassFillBottom: _tintFill(const Color(0x85FFFFFF), glassTint, 0.02),
      glassBorderTop: const Color(0xF2FFFFFF),
      glassBorderBottom: const Color(0x4DFFFFFF),
      glassShadow: const Color(0x14402F6B),
      cardShadow: const Color(0x1F3B2F66),
      textPrimary: const Color(0xFF12141C),
      textSecondary: const Color(0xFF4E5568),
      textTertiary: const Color(0xFF6B7284),
      accent: accent,
      accentAlt: accentAlt,
      cyan: cyan,
      success: success,
      warning: warning,
      danger: danger,
      fieldFill: const Color(0x8FFFFFFF),
      divider: const Color(0x1A000000),
      scrim: const Color(0x990B0918),
      grain: const Color(0x0A000000),
      sheen: const Color(0xB8FFFFFF),
    );
  }

  /// 保留原始透明度，只把玻璃基色往主题色方向偏一点。
  static Color _tintFill(Color base, Color tint, double amount) {
    final Color blended = Color.alphaBlend(
      tint.withValues(alpha: amount),
      base.withValues(alpha: 1),
    );
    return blended.withValues(alpha: base.a);
  }
}
