import 'package:flutter/foundation.dart';

/// Lifecycle states shared by package-file and Sophon/chunk download jobs.
enum DownloadStatus {
  queued,
  downloading,
  paused,
  verifying,
  publishing,
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

  /// Bytes processed by the current verification phase.
  int get verificationBytes => 0;

  /// Current verification progress, independent from download progress.
  double get verificationProgress => 0;

  /// Bytes copied/published into the final destination during publish phase.
  int get publishingBytes => 0;

  /// Current publish/copy progress, independent from download progress.
  double get publishingProgress => 0;

  /// Whether all bytes have been written but flush/close and metadata cleanup
  /// are still in progress.
  bool get isPublishingFinalizing => false;

  double get speed;
  String? get error;
  String get displayName;
  String get groupName;
  DownloadStatus get status;

  bool get isActive =>
      status == DownloadStatus.downloading ||
      status == DownloadStatus.verifying ||
      status == DownloadStatus.publishing;

  /// Whether this task is still consuming a network download concurrency slot.
  bool get consumesDownloadSlot => status == DownloadStatus.downloading;

  /// Whether this task's verification/publish phase reads and writes an
  /// independent high-speed cache directory rather than the (possibly slow,
  /// e.g. USB) final destination. Defaults to true so simple test doubles
  /// keep their previous behavior; real tasks override this to reflect
  /// whether a dedicated cache directory is actually configured.
  bool get hasFastCache => true;

  Future<bool> run();
  void pause();
  Future<void> cancel();
  void reset();
  void restoreState(DownloadStatus status, int receivedBytes);

  Map<String, dynamic> toPersistedJson();
}
