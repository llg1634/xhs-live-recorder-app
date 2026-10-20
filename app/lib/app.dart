import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'theme/app_theme.dart';
import 'ui/home_screen.dart';
import 'ui/widgets/comment_capture_layer.dart';

class ThemeController extends ChangeNotifier {
  ThemeMode _mode = ThemeMode.system;

  ThemeMode get mode => _mode;

  set mode(ThemeMode value) {
    if (_mode == value) return;
    _mode = value;
    notifyListeners();
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
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: controller.mode,
      home: const HomeScreen(),
    );
  }
}
