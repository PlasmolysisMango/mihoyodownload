import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'download_task.dart';

/// Serial/concurrent download queue, the counterpart of Starward's
/// `GameInstallService` task scheduling (simplified to download-only).
class DownloadManager extends ChangeNotifier {
  DownloadManager({this.maxConcurrent = 2});

  /// Max files downloading at the same time.
  final int maxConcurrent;

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
    notifyListeners();
    _pump();
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
    notifyListeners();
  }
}
