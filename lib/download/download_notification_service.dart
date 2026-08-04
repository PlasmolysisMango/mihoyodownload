import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../ui/format.dart';
import 'download_job.dart';
import 'download_manager.dart';

/// Shows download progress in the system notification tray.
///
/// On Android the progress notification is attached to a foreground service
/// (`startForegroundService`), which keeps the process — and therefore the
/// Dart download loops — alive while the app is in the background or the
/// screen is off. Other platforms only get a completion notification.
class DownloadNotificationService {
  DownloadNotificationService(this._manager);

  static const _progressId = 1001;
  static const _doneId = 1002;

  final DownloadManager _manager;
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  Timer? _timer;
  bool _wasBusy = false;
  bool _initialized = false;

  static bool get _supported => !kIsWeb && Platform.isAndroid;

  Future<void> init() async {
    if (!_supported || _initialized) return;
    await _plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    // Android 13+ runtime permission for posting notifications.
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
    _initialized = true;
    _manager.addListener(_onManagerChanged);
    _onManagerChanged();
  }

  void _onManagerChanged() {
    final busy = _manager.tasks.any(
      (t) => t.isActive || t.status == DownloadStatus.queued,
    );
    if (busy) {
      _wasBusy = true;
      // Progress ticks only on Android where the foreground service lives.
      if (Platform.isAndroid && _timer == null) {
        _timer = Timer.periodic(
          const Duration(seconds: 1),
          (_) => _updateProgress(),
        );
        _updateProgress();
      }
    } else if (_wasBusy) {
      _wasBusy = false;
      _timer?.cancel();
      _timer = null;
      _stopProgress();
      _notifyFinished();
    }
  }

  /// Updates the ongoing foreground-service notification (Android only).
  /// Repeated `startForegroundService` calls with the same id just update it.
  Future<void> _updateProgress() async {
    final total = _manager.totalSize;
    final received = _manager.receivedBytes;
    final percent = total <= 0 ? 0 : (received * 100 ~/ total).clamp(0, 100);
    final details = AndroidNotificationDetails(
      'downloads_progress',
      '下载进度',
      channelDescription: '游戏包下载进度',
      importance: Importance.low,
      priority: Priority.low,
      onlyAlertOnce: true,
      ongoing: true,
      autoCancel: false,
      showProgress: true,
      maxProgress: 100,
      progress: percent,
      category: AndroidNotificationCategory.progress,
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.startForegroundService(
          _progressId,
          '正在下载（$percent%）',
          '${formatBytes(received)} / ${formatBytes(total)}'
              ' · ${formatSpeed(_manager.totalSpeed)}'
              ' · 剩余 ${formatEta(total - received, _manager.totalSpeed)}',
          notificationDetails: details,
          foregroundServiceTypes: {
            AndroidServiceForegroundType.foregroundServiceTypeDataSync,
          },
        );
  }

  Future<void> _stopProgress() async {
    if (Platform.isAndroid) {
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.stopForegroundService();
    }
  }

  /// Posts a one-shot notification when the queue drains. Only celebrates
  /// when everything completed; a pause/cancel drain stays silent.
  Future<void> _notifyFinished() async {
    final tasks = _manager.tasks;
    if (tasks.isEmpty ||
        !tasks.every((t) => t.status == DownloadStatus.completed)) {
      return;
    }
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'downloads_done',
        '下载完成',
        channelDescription: '游戏包下载完成提醒',
        importance: Importance.high,
        priority: Priority.high,
      ),
    );
    await _plugin.show(
      _doneId,
      '下载完成',
      '共 ${tasks.length} 个文件（${formatBytes(_manager.totalSize)}）已全部下载完成',
      details,
    );
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    if (_initialized) {
      _manager.removeListener(_onManagerChanged);
    }
  }
}
