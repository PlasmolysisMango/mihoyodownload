import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-level settings persisted with SharedPreferences.
/// Currently only the download directory (supports external / USB storage).
class AppSettings extends ChangeNotifier {
  AppSettings(this._prefs);

  static const _kDownloadDir = 'download_dir';

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
}
