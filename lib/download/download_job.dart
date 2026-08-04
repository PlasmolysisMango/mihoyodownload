import 'package:flutter/foundation.dart';

/// Lifecycle states shared by package-file and Sophon/chunk download jobs.
enum DownloadStatus {
  queued,
  downloading,
  paused,
  verifying,
  completed,
  failed,
  canceled,
}

/// Common interface of all downloadable jobs.
abstract class DownloadJob extends ChangeNotifier {
  String get savePath;
  int get totalSize;
  int get receivedBytes;
  double get progress;
  double get speed;
  String? get error;
  String get displayName;
  String get groupName;
  DownloadStatus get status;

  bool get isActive =>
      status == DownloadStatus.downloading || status == DownloadStatus.verifying;

  Future<bool> run();
  void pause();
  Future<void> cancel();
  void reset();
  void restoreState(DownloadStatus status, int receivedBytes);

  Map<String, dynamic> toPersistedJson();
}
