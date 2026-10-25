import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:live_recorder/app.dart';
import 'package:live_recorder/theme/glass_palette.dart';
import 'package:live_recorder/ui/settings/app_settings.dart';

/// 验证主题色 / 深浅色 / 删除确认 / 排序 都能落盘并在下次启动恢复。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('主题色与深浅色持久化', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final ThemeController first = ThemeController();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    first.palette = GlassPalette.cyanBlue;
    first.mode = ThemeMode.dark;
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('theme_palette'), 'cyanBlue');
    expect(prefs.getString('theme_mode'), 'dark');

    final ThemeController second = ThemeController();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(second.palette, GlassPalette.cyanBlue);
    expect(second.mode, ThemeMode.dark);
  });

  test('删除确认与排序偏好持久化', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final AppSettingsController first = AppSettingsController();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(first.deleteConfirm, isTrue);
    expect(first.sortNewestFirst, isTrue);

    first.deleteConfirm = false;
    first.sortNewestFirst = false;
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('delete_confirm_before'), isFalse);
    expect(prefs.getBool('library_sort_newest'), isFalse);

    final AppSettingsController second = AppSettingsController();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(second.deleteConfirm, isFalse);
    expect(second.sortNewestFirst, isFalse);
  });
}
