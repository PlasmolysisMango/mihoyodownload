import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import '../models/sophon_models.dart';
import 'download_job.dart';
import 'download_task.dart';
import 'rate_limiter.dart';
import 'sophon_download_task.dart';
import 'verified_file_index.dart';

/// Serial/concurrent download queue, the counterpart of Starward's
/// `GameInstallService` task scheduling (simplified to download-only).
/// The task list survives app restarts: metadata goes to SharedPreferences,
/// while the `_tmp` files on disk keep the resumable download progress.
class DownloadManager extends ChangeNotifier {
  DownloadManager({
    int maxConcurrent = 2,
    bool continueDownloadsDuringFinalization = false,
    SharedPreferences? prefs,
  }) : _maxConcurrent = maxConcurrent,
       _continueDownloadsDuringFinalization =
           continueDownloadsDuringFinalization,
       _prefs = prefs;

  static const _kTasksKey = 'download_tasks';
  static const portableTaskRecordFileName = '.hoyo_download_tasks.json';

  /// Max files downloading at the same time; adjustable at runtime.
  /// Lowering it never interrupts running tasks, they just drain naturally.
  int _maxConcurrent;
  bool _continueDownloadsDuringFinalization;
  int get maxConcurrent => _maxConcurrent;
  set maxConcurrent(int value) {
    _maxConcurrent = value.clamp(1, 8);
    notifyListeners();
    _pump();
  }

  /// When enabled, tasks in verification/copy phases no longer block queued downloads.
  bool get continueDownloadsDuringFinalization =>
      _continueDownloadsDuringFinalization;
  set continueDownloadsDuringFinalization(bool value) {
    _continueDownloadsDuringFinalization = value;
    notifyListeners();
    _pump();
  }

  /// Shared limiter for the aggregate speed of all tasks.
  final RateLimiter rateLimiter = RateLimiter();

  /// Sets the global speed limit in bytes/second; 0 = unlimited.
  void setSpeedLimit(int bytesPerSecond) {
    rateLimiter.setLimit(bytesPerSecond);
    notifyListeners();
  }

  final SharedPreferences? _prefs;

  final List<DownloadJob> _tasks = [];
  final Set<String> _portableRoots = {};
  List<DownloadJob> get tasks => List.unmodifiable(_tasks);

  @visibleForTesting
  void addJobForTesting(DownloadJob task) {
    _attachTask(task);
    _tasks.add(task);
    notifyListeners();
    _pump();
  }

  int get activeCount => _tasks.where(_occupiesQueueSlot).length;

  int get totalSize => _tasks.fold(0, (s, t) => s + t.totalSize);

  int get receivedBytes => _tasks.fold(0, (s, t) => s + t.receivedBytes);

  double get totalSpeed => _tasks.fold(0.0, (s, t) => s + t.speed);

  /// Adds all files of a package selection to the queue, skipping duplicates.
  void addPackageFiles({
    required String groupName,
    required String saveDir,
    required List<GamePackageFile> files,
    String? cacheDir,
  }) {
    for (final file in files) {
      final savePath = '$saveDir/${file.fileName}';
      if (_tasks.any(
        (t) => t.savePath == savePath && t.status != DownloadStatus.canceled,
      )) {
        continue;
      }
      final task = DownloadTask(
        url: file.url,
        savePath: savePath,
        totalSize: file.size,
        expectedMd5: file.md5,
        displayName: file.fileName,
        groupName: groupName,
        cacheDir: cacheDir,
        rateLimiter: rateLimiter,
      );
      _attachTask(task);
      _tasks.add(task);
    }
    _persist();
    notifyListeners();
    _pump();
  }

  /// Adds Sophon categories as chunk-based jobs.
  void addSophonManifests({
    required String groupName,
    required String saveDir,
    required String version,
    required Iterable<(SophonManifestMeta, SophonChunkManifest)> manifests,
    String? chunkCacheDir,
  }) {
    for (final (meta, manifest) in manifests) {
      final savePath = '$saveDir/${meta.matchingField}';
      if (_tasks.any(
        (t) => t.savePath == savePath && t.status != DownloadStatus.canceled,
      )) {
        continue;
      }
      final task = SophonDownloadTask(
        meta: meta,
        initialManifest: manifest,
        saveDir: saveDir,
        version: version,
        groupName: groupName,
        chunkCacheDir: chunkCacheDir,
        rateLimiter: rateLimiter,
      );
      _attachTask(task);
      _tasks.add(task);
    }
    _persist();
    notifyListeners();
    _pump();
  }

  /// Reloads tasks saved by a previous session. Progress is re-derived from
  /// the files on disk; unfinished tasks come back as paused so the user
  /// decides when to spend bandwidth again.
  Future<void> restoreTasks() async {
    final raw = _prefs?.getString(_kTasksKey);
    if (raw == null || raw.isEmpty) return;
    List<dynamic> list;
    try {
      list = jsonDecode(raw) as List<dynamic>;
    } catch (_) {
      return;
    }
    for (final e in _jsonObjects(list)) {
      final task = await _taskFromJson(e);
      if (task == null || _hasDuplicate(task)) continue;
      _portableRoots.add(_portableRootForTask(task));
      _attachTask(task);
      _tasks.add(task);
    }
    notifyListeners();
  }

  /// Imports portable task records from a copied download directory.
  ///
  /// The directory is searched recursively for `.hoyo_download_tasks.json` files.
  /// Imported tasks are restored as paused/completed entries and are not started
  /// automatically, so loading a USB/PC copy never consumes bandwidth by itself.
  Future<int> importTaskRecordsFromDirectory(String dir) async {
    var added = 0;
    try {
      await for (final entity in Directory(
        dir,
      ).list(recursive: true, followLinks: false)) {
        if (entity is File &&
            _fileName(entity.path) == portableTaskRecordFileName) {
          added += await importTaskRecordFile(entity.path);
        }
      }
    } catch (_) {
      return added;
    }
    return added;
  }

  /// Imports one portable task record file.
  Future<int> importTaskRecordFile(String path) async {
    final root = File(path).parent.path;
    List<dynamic> list;
    try {
      final data = jsonDecode(await File(path).readAsString());
      if (data is Map<String, dynamic>) {
        list = data['tasks'] as List<dynamic>? ?? const [];
      } else if (data is List<dynamic>) {
        list = data;
      } else {
        return 0;
      }
    } catch (_) {
      return 0;
    }

    var added = 0;
    for (final e in _jsonObjects(list)) {
      final task = await _taskFromJson(e, portableRoot: root);
      if (task == null || _hasDuplicate(task)) continue;
      _portableRoots.add(root);
      _attachTask(task);
      _tasks.add(task);
      added++;
    }
    if (added > 0) {
      _persist();
      notifyListeners();
    }
    return added;
  }

  Future<DownloadJob?> _taskFromJson(
    Map<String, dynamic> e, {
    String? portableRoot,
  }) async {
    final type = e['type'] as String? ?? 'package';
    DownloadJob? task;
    if (type == 'sophon') {
      final metaJson = e['meta'];
      if (metaJson is! Map<String, dynamic>) return null;
      final saveDirRaw = e['saveDir'] as String? ?? '';
      task = SophonDownloadTask(
        meta: SophonManifestMeta.fromPersistedJson(metaJson),
        saveDir: portableRoot == null
            ? saveDirRaw
            : _resolvePath(portableRoot, saveDirRaw.isEmpty ? '.' : saveDirRaw),
        version: e['version'] as String? ?? '',
        groupName: e['groupName'] as String? ?? '',
        chunkCacheDir: e['chunkCacheDir'] as String?,
        rateLimiter: rateLimiter,
      );
    } else {
      final savePathRaw = e['savePath'] as String? ?? '';
      task = DownloadTask(
        url: e['url'] as String? ?? '',
        savePath: portableRoot == null
            ? savePathRaw
            : _resolvePath(portableRoot, savePathRaw),
        totalSize: e['totalSize'] as int? ?? 0,
        expectedMd5: e['expectedMd5'] as String? ?? '',
        displayName: e['displayName'] as String? ?? '',
        groupName: e['groupName'] as String? ?? '',
        cacheDir: portableRoot == null ? e['cacheDir'] as String? : null,
        rateLimiter: rateLimiter,
      );
    }
    if (task.savePath.isEmpty) return null;

    var status = DownloadStatus.paused;
    var received = 0;
    if ((e['status'] as String?) == 'completed') {
      status = DownloadStatus.completed;
      received = task.totalSize;
    } else if (task is DownloadTask) {
      final finalFile = File(task.savePath);
      if (await finalFile.exists() &&
          await finalFile.length() == task.totalSize) {
        status = DownloadStatus.completed;
        received = task.totalSize;
      } else {
        final tmpFile = File(task.tmpPath);
        if (await tmpFile.exists()) {
          received = await tmpFile.length();
        }
      }
    }
    task.restoreState(status, received);
    return task;
  }

  /// Saves task metadata; download progress itself lives in the tmp files.
  void _persist() {
    final list = _tasks
        .where((t) => t.status != DownloadStatus.canceled)
        .map((t) => t.toPersistedJson())
        .toList();
    _prefs?.setString(_kTasksKey, jsonEncode(list));
    _persistPortableRecords(list);
  }

  void _persistPortableRecords(List<Map<String, dynamic>> _) {
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final task in _tasks.where(
      (t) => t.status != DownloadStatus.canceled,
    )) {
      final root = _portableRootForTask(task);
      if (root.isEmpty) continue;
      groups.putIfAbsent(root, () => []).add(_toPortableJson(task, root));
    }

    for (final root in _portableRoots.difference(groups.keys.toSet())) {
      try {
        final file = File(_portableRecordPath(root));
        if (file.existsSync()) file.deleteSync();
      } catch (_) {}
    }

    _portableRoots
      ..clear()
      ..addAll(groups.keys);
    for (final entry in groups.entries) {
      try {
        Directory(entry.key).createSync(recursive: true);
        File(
          _portableRecordPath(entry.key),
        ).writeAsStringSync(jsonEncode({'version': 1, 'tasks': entry.value}));
      } catch (_) {}
    }
  }

  bool _occupiesQueueSlot(DownloadJob task) {
    if (_continueDownloadsDuringFinalization) {
      return task.consumesDownloadSlot;
    }
    return task.isActive;
  }

  void _attachTask(DownloadJob task) {
    task.addListener(_onTaskChanged);
  }

  void _detachTask(DownloadJob task) {
    task.removeListener(_onTaskChanged);
  }

  void _onTaskChanged() {
    notifyListeners();
    if (_continueDownloadsDuringFinalization) {
      _pump();
    }
  }

  /// Starts queued tasks while below the concurrency limit.
  void _pump() {
    for (final task in _tasks) {
      if (activeCount >= maxConcurrent) break;
      if (task.status == DownloadStatus.queued) {
        _runTask(task);
      }
    }
  }

  Future<void> _runTask(DownloadJob task) async {
    await task.run();
    _persist();
    if (task.status != DownloadStatus.paused) {
      _pump();
    }
  }

  void pause(DownloadJob task) {
    task.pause();
  }

  void resume(DownloadJob task) {
    if (task.status == DownloadStatus.paused ||
        task.status == DownloadStatus.failed) {
      task.reset();
      _pump();
    }
  }

  Future<void> cancel(DownloadJob task) async {
    await task.cancel();
    _persist();
    _pump();
  }

  /// Removes a task from the list. When [deleteFiles] is true, already
  /// downloaded final files and temporary/cache files for that task are removed
  /// from disk as well; otherwise only the task record is removed.
  Future<void> removeTask(DownloadJob task, {bool deleteFiles = false}) async {
    if (!_tasks.contains(task)) return;
    if (deleteFiles) {
      await task.cancel();
      await _deleteTaskFiles(task);
    } else if (task.isActive) {
      task.pause();
    }
    _detachTask(task);
    _tasks.remove(task);
    _persist();
    notifyListeners();
    _pump();
  }

  Future<void> removeAllTasks({bool deleteFiles = false}) async {
    final tasks = List<DownloadJob>.from(_tasks);
    for (final task in tasks) {
      if (deleteFiles) {
        await task.cancel();
        await _deleteTaskFiles(task);
      } else if (task.isActive) {
        task.pause();
      }
      _detachTask(task);
    }
    _tasks.clear();
    _persist();
    notifyListeners();
  }

  void pauseAll() {
    for (final task in _tasks) {
      task.pause();
    }
  }

  void resumeAll() {
    for (final task in _tasks) {
      if (task.status == DownloadStatus.paused ||
          task.status == DownloadStatus.failed) {
        task.reset();
      }
    }
    _pump();
  }

  void removeFinished() {
    _tasks.removeWhere((t) {
      final removable =
          t.status == DownloadStatus.completed ||
          t.status == DownloadStatus.canceled;
      if (removable) _detachTask(t);
      return removable;
    });
    _persist();
    notifyListeners();
  }

  /// Deletes download cache entries that are safe to remove.
  ///
  /// In addition to caches owned by known inactive tasks, [extraRoots]
  /// lets callers clean orphan cache entries under configured cache roots.
  /// Active downloads keep their cache to avoid corrupting in-flight data.
  /// The downloaded final game files are not touched.
  Future<int> clearChunkCaches({Iterable<String> extraRoots = const []}) async {
    final activePaths = <String>{};
    final cachePaths = <String>{};
    for (final task in _tasks) {
      if (task is SophonDownloadTask) {
        if (task.isActive) {
          activePaths.add(_normalizedPath(task.cacheDir));
        } else {
          cachePaths.add(task.cacheDir);
        }
      } else if (task is DownloadTask &&
          task.cacheDir != null &&
          task.cacheDir!.isNotEmpty) {
        final markerPath = task.validatedCacheMarkerPath;
        if (task.isActive) {
          activePaths.add(_normalizedPath(task.tmpPath));
          if (markerPath != null) activePaths.add(_normalizedPath(markerPath));
        } else {
          cachePaths.add(task.tmpPath);
          if (markerPath != null) cachePaths.add(markerPath);
        }
      }
    }

    for (final rootPath in extraRoots) {
      try {
        final root = Directory(rootPath);
        if (!await root.exists()) continue;
        await for (final entity in root.list(followLinks: false)) {
          final path = _normalizedPath(entity.path);
          if (activePaths.contains(path)) continue;
          cachePaths.add(entity.path);
        }
      } catch (_) {}
    }

    var deleted = 0;
    for (final path in cachePaths) {
      if (activePaths.contains(_normalizedPath(path))) continue;
      try {
        final type = await FileSystemEntity.type(path, followLinks: false);
        if (type == FileSystemEntityType.directory) {
          await Directory(path).delete(recursive: true);
          deleted++;
        } else if (type == FileSystemEntityType.file ||
            type == FileSystemEntityType.link) {
          await File(path).delete();
          deleted++;
        }
      } catch (_) {}
    }
    return deleted;
  }

  String _normalizedPath(String path) {
    final absolute = FileSystemEntity.isDirectorySync(path)
        ? Directory(path).absolute.path
        : File(path).absolute.path;
    if (absolute.endsWith(Platform.pathSeparator)) {
      return absolute.substring(0, absolute.length - 1);
    }
    return absolute;
  }

  Future<void> _deleteTaskFiles(DownloadJob task) async {
    try {
      if (task is DownloadTask) {
        final finalFile = File(task.savePath);
        if (await finalFile.exists()) await finalFile.delete();
        await VerifiedFileIndex.remove(
          task.finalVerifiedIndexRoot,
          task.finalVerifiedIndexKey,
        );
        final legacyFinalMarker = File('${task.savePath}.verified');
        if (await legacyFinalMarker.exists()) await legacyFinalMarker.delete();
        final tmpFile = File(task.tmpPath);
        if (await tmpFile.exists()) await tmpFile.delete();
        final markerPath = task.validatedCacheMarkerPath;
        if (markerPath != null) {
          final marker = File(markerPath);
          if (await marker.exists()) await marker.delete();
        }
      } else if (task is SophonDownloadTask) {
        final target = Directory(task.savePath);
        if (await target.exists()) await target.delete(recursive: true);
        final cache = Directory(task.cacheDir);
        if (await cache.exists()) await cache.delete(recursive: true);
      } else {
        final target = File(task.savePath);
        if (await target.exists()) await target.delete();
      }
    } catch (_) {}
  }

  bool _hasDuplicate(DownloadJob task) => _tasks.any(
    (t) => t.savePath == task.savePath && t.status != DownloadStatus.canceled,
  );

  Iterable<Map<String, dynamic>> _jsonObjects(List<dynamic> list) sync* {
    for (final e in list) {
      if (e is Map<String, dynamic>) yield e;
    }
  }

  String _portableRootForTask(DownloadJob task) {
    if (task is SophonDownloadTask) return task.saveDir;
    if (task is DownloadTask) return File(task.savePath).parent.path;
    return File(task.savePath).parent.path;
  }

  Map<String, dynamic> _toPortableJson(DownloadJob task, String root) {
    final json = Map<String, dynamic>.from(task.toPersistedJson());
    if (task is SophonDownloadTask) {
      json['saveDir'] = '.';
      json.remove('chunkCacheDir');
    } else if (task is DownloadTask) {
      json['savePath'] = _relativePath(task.savePath, root);
      json.remove('cacheDir');
    }
    return json;
  }

  String _portableRecordPath(String root) =>
      '$root${Platform.pathSeparator}$portableTaskRecordFileName';

  String _relativePath(String path, String root) {
    final p = _normalizePath(path);
    final r = _normalizePath(root);
    if (p == r) return '.';
    if (p.startsWith('$r/')) return p.substring(r.length + 1);
    return _fileName(path);
  }

  String _resolvePath(String root, String path) {
    if (path.isEmpty || path == '.') return root;
    if (_isAbsolutePath(path)) return path;
    final parts = _normalizePath(
      path,
    ).split('/').where((p) => p.isNotEmpty && p != '.' && p != '..');
    var result = root;
    for (final part in parts) {
      result = '$result${Platform.pathSeparator}$part';
    }
    return result;
  }

  bool _isAbsolutePath(String path) {
    final p = _normalizePath(path);
    return p.startsWith('/') || RegExp(r'^[A-Za-z]:/').hasMatch(p);
  }

  String _normalizePath(String path) =>
      path.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');

  String _fileName(String path) => _normalizePath(path).split('/').last;
}
