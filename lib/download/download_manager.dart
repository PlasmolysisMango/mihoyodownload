import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import 'download_task.dart';

/// Serial/concurrent download queue, the counterpart of Starward's
/// `GameInstallService` task scheduling (simplified to download-only).
/// The task list survives app restarts: metadata goes to SharedPreferences,
/// while the `_tmp` files on disk keep the resumable download progress.
class DownloadManager extends ChangeNotifier {
  DownloadManager({this.maxConcurrent = 2, SharedPreferences? prefs})
      : _prefs = prefs;

  static const _kTasksKey = 'download_tasks';

  /// Max files downloading at the same time.
  final int maxConcurrent;

  final SharedPreferences? _prefs;

  final List<DownloadTask> _tasks = [];
  List<DownloadTask> get tasks => List.unmodifiable(_tasks);

  int get activeCount => _tasks.where((t) => t.isActive).length;

  int get totalSize => _tasks.fold(0, (s, t) => s + t.totalSize);

  int get receivedBytes => _tasks.fold(0, (s, t) => s + t.receivedBytes);

  double get totalSpeed => _tasks.fold(0.0, (s, t) => s + t.speed);

  /// Adds all files of a package selection to the queue, skipping duplicates.
  void addPackageFiles({
    required String groupName,
    required String saveDir,
    required List<GamePackageFile> files,
  }) {
    for (final file in files) {
      final savePath = '$saveDir/${file.fileName}';
      if (_tasks.any((t) => t.savePath == savePath &&
          t.status != DownloadStatus.canceled)) {
        continue;
      }
      final task = DownloadTask(
        url: file.url,
        savePath: savePath,
        totalSize: file.size,
        expectedMd5: file.md5,
        displayName: file.fileName,
        groupName: groupName,
      );
      task.addListener(notifyListeners);
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
    for (final e in list.whereType<Map<String, dynamic>>()) {
      final task = DownloadTask(
        url: e['url'] as String? ?? '',
        savePath: e['savePath'] as String? ?? '',
        totalSize: e['totalSize'] as int? ?? 0,
        expectedMd5: e['expectedMd5'] as String? ?? '',
        displayName: e['displayName'] as String? ?? '',
        groupName: e['groupName'] as String? ?? '',
      );
      if (task.url.isEmpty || task.savePath.isEmpty) continue;
      var status = DownloadStatus.paused;
      var received = 0;
      final finalFile = File(task.savePath);
      if (await finalFile.exists() &&
          await finalFile.length() == task.totalSize) {
        status = DownloadStatus.completed;
        received = task.totalSize;
      } else {
        final tmpFile = File('${task.savePath}_tmp');
        if (await tmpFile.exists()) {
          received = await tmpFile.length();
        }
      }
      task.restoreState(status, received);
      task.addListener(notifyListeners);
      _tasks.add(task);
    }
    notifyListeners();
  }

  /// Saves task metadata; download progress itself lives in the tmp files.
  void _persist() {
    final prefs = _prefs;
    if (prefs == null) return;
    final list = _tasks
        .where((t) => t.status != DownloadStatus.canceled)
        .map((t) => {
              'url': t.url,
              'savePath': t.savePath,
              'totalSize': t.totalSize,
              'expectedMd5': t.expectedMd5,
              'displayName': t.displayName,
              'groupName': t.groupName,
              'status': t.status == DownloadStatus.completed
                  ? 'completed'
                  : 'paused',
            })
        .toList();
    prefs.setString(_kTasksKey, jsonEncode(list));
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

  Future<void> _runTask(DownloadTask task) async {
    await task.run();
    _persist();
    _pump();
  }

  void pause(DownloadTask task) {
    task.pause();
  }

  void resume(DownloadTask task) {
    if (task.status == DownloadStatus.paused ||
        task.status == DownloadStatus.failed) {
      task.reset();
      _pump();
    }
  }

  Future<void> cancel(DownloadTask task) async {
    await task.cancel();
    _persist();
    _pump();
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
      final removable = t.status == DownloadStatus.completed ||
          t.status == DownloadStatus.canceled;
      if (removable) t.removeListener(notifyListeners);
      return removable;
    });
    _persist();
    notifyListeners();
  }
}
