import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/recording_manager.dart';
import '../theme/glass_tokens.dart';
import 'library/library_page.dart';
import 'settings/settings_page.dart';
import 'task/record_page.dart';
import 'widgets/glass_ambient_background.dart';
import 'widgets/glass_tab_bar.dart';

/// App 主壳：氛围背景 + 三页内容 + 悬浮玻璃 Tab 栏 + 页面切换过渡。
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;

  void _select(int index) {
    if (index == _index) return;
    setState(() => _index = index);
  }

  void _selectFromTab(int index) {
    HapticFeedback.selectionClick();
    _select(index);
  }

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final double keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final int activeCount = context.select<RecordingManager, int>(
      (RecordingManager m) => m.activeCount,
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
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
                    child: Stack(
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
    );
  }
}

/// 单页容器：切换时淡入 + 轻微位移；隐藏页停止 ticker、忽略点击。
class _TabPage extends StatelessWidget {
  const _TabPage({required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    final Duration duration = reduceMotion ? Duration.zero : GlassTokens.medium;
    return IgnorePointer(
      ignoring: !active,
      child: ExcludeSemantics(
        excluding: !active,
        child: AnimatedOpacity(
          opacity: active ? 1 : 0,
          duration: duration,
          curve: GlassTokens.easeOut,
          child: AnimatedSlide(
            offset: active ? Offset.zero : const Offset(0, 0.02),
            duration: duration,
            curve: GlassTokens.easeOut,
            child: TickerMode(
              enabled: active,
              // 每页单独一个 BackdropGroup：页内多块玻璃共享一次模糊，
              // 页面切换交叉淡入时不会出现相邻页互相"吞并"模糊的瑕疵。
              child: BackdropGroup(child: child),
            ),
          ),
        ),
      ),
    );
  }
}
