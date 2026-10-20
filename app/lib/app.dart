import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme/app_theme.dart';
import 'theme/glass_palette.dart';
import 'ui/home_screen.dart';
import 'ui/widgets/comment_capture_layer.dart';

/// 主题偏好：明暗模式 + 主题色方案，均写入 SharedPreferences。
///
/// 构造后异步恢复偏好；恢复完成前先使用「跟随系统 + 粉紫」，不会阻塞首帧。
class ThemeController extends ChangeNotifier {
  ThemeController() {
    _restore();
  }

  static const String _modeKey = 'theme_mode';
  static const String _paletteKey = 'theme_palette';

  ThemeMode _mode = ThemeMode.system;
  GlassPalette _palette = GlassPalette.pinkPurple;
  bool _touched = false;

  ThemeMode get mode => _mode;

  GlassPalette get palette => _palette;

  set mode(ThemeMode value) {
    if (_mode == value) return;
    _touched = true;
    _mode = value;
    notifyListeners();
    _persistMode(value);
  }

  set palette(GlassPalette value) {
    if (_palette == value) return;
    _touched = true;
    _palette = value;
    notifyListeners();
    _persistPalette(value);
  }

  Future<void> _restore() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      if (_touched) return; // 用户已在恢复完成前改过，以用户操作为准。
      bool changed = false;
      final String? modeName = prefs.getString(_modeKey);
      if (modeName != null) {
        for (final ThemeMode option in ThemeMode.values) {
          if (option.name == modeName) {
            _mode = option;
            changed = true;
            break;
          }
        }
      }
      final String? paletteName = prefs.getString(_paletteKey);
      if (paletteName != null) {
        for (final GlassPalette option in GlassPalette.values) {
          if (option.name == paletteName) {
            _palette = option;
            changed = true;
            break;
          }
        }
      }
      if (changed) notifyListeners();
    } catch (_) {
      // 偏好读取失败（例如平台插件未注册）时保持默认值。
    }
  }

  Future<void> _persistMode(ThemeMode value) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(_modeKey, value.name);
    } catch (_) {
      // 持久化失败不影响本次主题切换。
    }
  }

  Future<void> _persistPalette(GlassPalette value) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(_paletteKey, value.name);
    } catch (_) {
      // 持久化失败不影响本次主题切换。
    }
  }
}

class LiveRecorderApp extends StatelessWidget {
  const LiveRecorderApp({super.key});

  /// 供入口（intent / 深链）在 App 起来后 push 调试页面。
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ThemeController>();
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: '直播录制',
      debugShowCheckedModeBanner: false,
      // 弹幕采集层挂在 App 内容**下面**：真实渲染但用户不可见。
      builder: (context, child) => Stack(
        children: [
          const Positioned(left: 0, top: 0, child: CommentCaptureLayer()),
          Positioned.fill(child: child ?? const SizedBox.shrink()),
        ],
      ),
      theme: AppTheme.light(controller.palette),
      darkTheme: AppTheme.dark(controller.palette),
      themeMode: controller.mode,
      // 主题色切换即时生效；跳过 200ms 的主题插值，避免玻璃层逐帧重算模糊。
      themeAnimationDuration: Duration.zero,
      home: const HomeScreen(),
    );
  }
}
