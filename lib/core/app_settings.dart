import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-level settings persisted with SharedPreferences.
/// Stores download parameters such as download and cache directories.
class AppSettings extends ChangeNotifier {
  AppSettings(this._prefs);

  static const _kDownloadDir = 'download_dir';
  // Keep the old key name for backward compatibility with existing settings.
  static const _kCacheDir = 'chunk_cache_dir';
  static const _kExperimentalChunk = 'experimental_chunk_enabled';
  static const _kPackageCacheEnabled = 'package_cache_enabled';
  static const _kContinueDownloadsDuringFinalization =
      'continue_downloads_during_finalization';
  static const _kSophonPrefetchDuringVerification =
      'sophon_prefetch_during_verification';
  static const _kMaxConcurrent = 'max_concurrent';
  static const _kSpeedLimit = 'speed_limit_bps';

  final SharedPreferences _prefs;

  /// User-selected download directory; null means the app default.
  String? get customDownloadDir => _prefs.getString(_kDownloadDir);

  /// User-selected high-speed cache directory; null means mode-specific default.
  String? get customCacheDir => _prefs.getString(_kCacheDir);

  /// Backward-compatible name for the Sophon cache directory setting.
  String? get customChunkCacheDir => customCacheDir;

  /// Sophon/chunk mode is experimental and disabled by default.
  bool get experimentalChunkEnabled =>
      _prefs.getBool(_kExperimentalChunk) ?? false;

  /// Package cache downloading is disabled by default.
  bool get packageCacheEnabled =>
      _prefs.getBool(_kPackageCacheEnabled) ?? false;

  /// Whether verification/copy phases should free the download queue slot.
  bool get continueDownloadsDuringFinalization =>
      _prefs.getBool(_kContinueDownloadsDuringFinalization) ?? false;

  /// Whether a Sophon task should keep downloading the next file's chunks
  /// while the current file is being verified, published, and cleaned up.
  bool get sophonPrefetchDuringVerification =>
      _prefs.getBool(_kSophonPrefetchDuringVerification) ?? false;

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

  /// The effective Sophon chunk cache root.
  ///
  /// By default, chunk caches stay inside [downloadDir] to keep existing
  /// behavior. A custom directory can point to faster internal storage while
  /// downloaded game files still go to an external drive.
  String resolveChunkCacheDir(String downloadDir) {
    return resolveIndependentChunkCacheDir() ?? '$downloadDir/.sophon/chunks';
  }

  /// The independently configured Sophon cache root, or null when Chunk mode
  /// should use its default cache under the download directory.
  String? resolveIndependentChunkCacheDir() {
    final custom = customCacheDir;
    if (custom != null && custom.isNotEmpty) return custom;
    return null;
  }

  /// The effective package cache root; null keeps the legacy direct tmp path.
  String? resolvePackageCacheDir() {
    if (!packageCacheEnabled) return null;
    final custom = customCacheDir;
    if (custom != null && custom.isNotEmpty) return custom;
    return null;
  }

  /// Sets the high-speed cache directory; pass null to restore the default.
  Future<void> setCacheDir(String? path) async {
    if (path == null || path.isEmpty) {
      await _prefs.remove(_kCacheDir);
    } else {
      await _prefs.setString(_kCacheDir, path);
    }
    notifyListeners();
  }

  /// Backward-compatible setter for the Sophon cache directory setting.
  Future<void> setChunkCacheDir(String? path) => setCacheDir(path);

  Future<void> setExperimentalChunkEnabled(bool value) async {
    await _prefs.setBool(_kExperimentalChunk, value);
    notifyListeners();
  }

  Future<void> setPackageCacheEnabled(bool value) async {
    await _prefs.setBool(_kPackageCacheEnabled, value);
    notifyListeners();
  }

  Future<void> setContinueDownloadsDuringFinalization(bool value) async {
    await _prefs.setBool(_kContinueDownloadsDuringFinalization, value);
    notifyListeners();
  }

  Future<void> setSophonPrefetchDuringVerification(bool value) async {
    await _prefs.setBool(_kSophonPrefetchDuringVerification, value);
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
