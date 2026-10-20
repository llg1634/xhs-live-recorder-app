import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/recording_manager.dart';
import '../theme/glass_tokens.dart';
import 'library/library_page.dart';
import 'settings/app_settings.dart';
import 'settings/settings_page.dart';
import 'task/record_page.dart';
import 'widgets/glass_ambient_background.dart';
import 'widgets/glass_scroll_activity.dart';
import 'widgets/glass_tab_bar.dart';

/// App 主壳：氛围背景 + 三页内容 + 悬浮玻璃 Tab 栏。
///
/// 三个 Tab 用 [IndexedStack] 常驻挂载：切换只改绘制索引，不重建页面、
/// 不丢滚动位置，也不会出现淡入淡出时两页玻璃同时参与合成的高开销帧。
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;

  /// 滚动状态只驱动玻璃面板内部的模糊子树，不 setState 重建整页。
  final ValueNotifier<bool> _scrolling = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _scrolling.dispose();
    super.dispose();
  }

  void _select(int index) {
    if (index == _index) return;
    setState(() => _index = index);
  }

  void _selectFromTab(int index) {
    HapticFeedback.selectionClick();
    _select(index);
  }

  bool _onScrollNotification(ScrollNotification notification) {
    // 只关心页面主滚动；嵌套滚动（例如输入框内部）不改变玻璃模糊。
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification) {
      if (!_scrolling.value) _scrolling.value = true;
    } else if (notification is ScrollEndNotification) {
      if (_scrolling.value) _scrolling.value = false;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final double keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final int activeCount = context.select<RecordingManager, int>(
      (RecordingManager m) => m.activeCount,
    );

    return ChangeNotifierProvider<AppSettingsController>(
      create: (_) => AppSettingsController(),
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: (isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
            .copyWith(
              statusBarColor: Colors.transparent,
              systemNavigationBarColor: Colors.transparent,
              systemNavigationBarDividerColor: Colors.transparent,
              statusBarIconBrightness: isDark
                  ? Brightness.light
                  : Brightness.dark,
              systemNavigationBarIconBrightness: isDark
                  ? Brightness.light
                  : Brightness.dark,
            ),
        child: PopScope(
          canPop: _index == 0,
          onPopInvokedWithResult: (bool didPop, Object? result) {
            if (didPop) return;
            if (_index != 0) _select(0);
          },
          child: Scaffold(
            backgroundColor: Colors.transparent,
            resizeToAvoidBottomInset: true,
            body: Stack(
              children: <Widget>[
                const Positioned.fill(child: GlassAmbientBackground()),
                Positioned.fill(
                  child: Material(
                    type: MaterialType.transparency,
                    child: SafeArea(
                      bottom: false,
                      child: NotificationListener<ScrollNotification>(
                        onNotification: _onScrollNotification,
                        child: GlassScrollActivity(
                          scrolling: _scrolling,
                          child: IndexedStack(
                            index: _index,
                            sizing: StackFit.expand,
                            children: <Widget>[
                              _TabPage(
                                active: _index == 0,
                                child: const RecordPage(),
                              ),
                              _TabPage(
                                active: _index == 1,
                                child: LibraryPage(active: _index == 1),
                              ),
                              _TabPage(
                                active: _index == 2,
                                child: SettingsPage(active: _index == 2),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: AnimatedSlide(
                    offset: keyboardInset > 0
                        ? const Offset(0, 1.6)
                        : Offset.zero,
                    duration: GlassTokens.medium,
                    curve: GlassTokens.easeOut,
                    child: IgnorePointer(
                      ignoring: keyboardInset > 0,
                      child: GlassTabBar(
                        index: _index,
                        onChanged: _selectFromTab,
                        recordingCount: activeCount,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 单页容器：只负责停掉隐藏页动画、屏蔽交互与语义。
///
/// 页面本体始终挂载在 [IndexedStack] 里，滚动位置、输入框内容、展开状态
/// 都随 State 保留；每页一个 [BackdropGroup]，页内多块玻璃共享一次模糊。
class _TabPage extends StatelessWidget {
  const _TabPage({required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TickerMode(
      enabled: active,
      child: ExcludeSemantics(
        excluding: !active,
        child: IgnorePointer(
          ignoring: !active,
          child: BackdropGroup(child: child),
        ),
      ),
    );
  }
}
