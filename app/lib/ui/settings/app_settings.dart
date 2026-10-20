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

  bool _deleteConfirm = true;
  bool _touched = false;

  /// 默认 `true`：破坏性操作保留二次确认。
  bool get deleteConfirm => _deleteConfirm;

  set deleteConfirm(bool value) {
    if (_deleteConfirm == value) return;
    _touched = true;
    _deleteConfirm = value;
    notifyListeners();
    _persist(value);
  }

  Future<void> _restore() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      if (_touched) return;
      final bool? stored = prefs.getBool(_deleteConfirmKey);
      if (stored != null && stored != _deleteConfirm) {
        _deleteConfirm = stored;
        notifyListeners();
      }
    } catch (_) {
      // 偏好读取失败时保持默认值。
    }
  }

  Future<void> _persist(bool value) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_deleteConfirmKey, value);
    } catch (_) {
      // 持久化失败不阻塞本次操作。
    }
  }
}
