import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/quality.dart';

/// 应用级交互偏好（不放主题控制器里，避免主题与行为耦合）。
///
/// 「删除前二次确认」默认开启；「画质」默认最高。
class AppSettingsController extends ChangeNotifier {
  AppSettingsController() {
    _restore();
  }

  static const String _deleteConfirmKey = 'delete_confirm_before';
  static const String _sortNewestKey = 'library_sort_newest';
  static const String _qualityKey = 'record_quality';

  bool _deleteConfirm = true;
  bool _sortNewestFirst = true;
  RecordQuality _quality = RecordQuality.highest;
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

  /// 录制画质，默认最高。
  RecordQuality get quality => _quality;

  set quality(RecordQuality value) {
    if (_quality == value) return;
    _touched = true;
    _quality = value;
    notifyListeners();
    _persistString(_qualityKey, value.name);
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
      final String? qualityName = prefs.getString(_qualityKey);
      if (qualityName != null) {
        for (final RecordQuality option in RecordQuality.values) {
          if (option.name == qualityName) {
            _quality = option;
            changed = true;
            break;
          }
        }
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

  Future<void> _persistString(String key, String value) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    } catch (_) {
      // 持久化失败不阻塞本次操作。
    }
  }
}
