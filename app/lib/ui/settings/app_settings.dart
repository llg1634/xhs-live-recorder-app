import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 应用级交互偏好（不放主题控制器里，避免主题与行为耦合）。
///
/// 目前只有「删除前二次确认」：默认开启，关闭后左滑 / 长按删除录像会直接执行。
class AppSettingsController extends ChangeNotifier {
  AppSettingsController() {
    _restore();
  }

  static const String _deleteConfirmKey = 'delete_confirm_before';
  static const String _sortNewestKey = 'library_sort_newest';

  bool _deleteConfirm = true;
  bool _sortNewestFirst = true;
  bool _touched = false;

  /// 默认 `true`：破坏性操作保留二次确认。
  bool get deleteConfirm => _deleteConfirm;

  set deleteConfirm(bool value) {
    if (_deleteConfirm == value) return;
    _touched = true;
    _deleteConfirm = value;
    notifyListeners();
    _persist(_deleteConfirmKey, value);
  }

  /// 录像列表默认排序：`true` = 最新在前。
  bool get sortNewestFirst => _sortNewestFirst;

  set sortNewestFirst(bool value) {
    if (_sortNewestFirst == value) return;
    _touched = true;
    _sortNewestFirst = value;
    notifyListeners();
    _persist(_sortNewestKey, value);
  }

  Future<void> _restore() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      if (_touched) return;
      bool changed = false;
      final bool? stored = prefs.getBool(_deleteConfirmKey);
      if (stored != null && stored != _deleteConfirm) {
        _deleteConfirm = stored;
        changed = true;
      }
      final bool? sort = prefs.getBool(_sortNewestKey);
      if (sort != null && sort != _sortNewestFirst) {
        _sortNewestFirst = sort;
        changed = true;
      }
      if (changed) notifyListeners();
    } catch (_) {
      // 偏好读取失败时保持默认值。
    }
  }

  Future<void> _persist(String key, bool value) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, value);
    } catch (_) {
      // 持久化失败不阻塞本次操作。
    }
  }
}
