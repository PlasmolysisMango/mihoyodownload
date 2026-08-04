import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-level settings persisted with SharedPreferences.
/// Currently only the download directory (supports external / USB storage).
class AppSettings extends ChangeNotifier {
  AppSettings(this._prefs);

  static const _kDownloadDir = 'download_dir';
  static const _kMaxConcurrent = 'max_concurrent';
  static const _kSpeedLimit = 'speed_limit_bps';

  final SharedPreferences _prefs;

  /// User-selected download directory; null means the app default.
  String? get customDownloadDir => _prefs.getString(_kDownloadDir);

  /// The effective download root: the custom directory when set,
  /// otherwise `<app documents>/downloads`.
  Future<String> resolveDownloadDir() async {
    final custom = customDownloadDir;
    if (custom != null && custom.isNotEmpty) {
      return custom;
    }
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/downloads';
  }

  /// Sets the download directory; pass null to restore the default.
  Future<void> setDownloadDir(String? path) async {
    if (path == null || path.isEmpty) {
      await _prefs.remove(_kDownloadDir);
    } else {
      await _prefs.setString(_kDownloadDir, path);
    }
    notifyListeners();
  }

  /// Max simultaneous download tasks (1-8).
  int get maxConcurrent => (_prefs.getInt(_kMaxConcurrent) ?? 2).clamp(1, 8);

  Future<void> setMaxConcurrent(int value) async {
    await _prefs.setInt(_kMaxConcurrent, value.clamp(1, 8));
    notifyListeners();
  }

  /// Global download speed limit in bytes/second; 0 = unlimited.
  int get speedLimitBytesPerSec => _prefs.getInt(_kSpeedLimit) ?? 0;

  Future<void> setSpeedLimit(int bytesPerSecond) async {
    await _prefs.setInt(_kSpeedLimit, bytesPerSecond < 0 ? 0 : bytesPerSecond);
    notifyListeners();
  }
}
