import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hoyo_downloader/core/app_settings.dart';
import 'package:hoyo_downloader/download/download_job.dart';
import 'package:hoyo_downloader/download/download_manager.dart';
import 'package:hoyo_downloader/download/download_task.dart';
import 'package:hoyo_downloader/download/sophon_download_task.dart';
import 'package:hoyo_downloader/models/models.dart';
import 'package:hoyo_downloader/models/sophon_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _BlockingDownloadJob extends DownloadJob {
  _BlockingDownloadJob(this.displayName);

  final Completer<void> started = Completer<void>();
  final Completer<void> _released = Completer<void>();

  DownloadStatus _status = DownloadStatus.queued;
  bool _pauseRequested = false;

  @override
  String get savePath => displayName;

  @override
  int get totalSize => 1;

  @override
  int get receivedBytes => 0;

  @override
  double get progress => 0;

  @override
  double get speed => 0;

  @override
  String? get error => null;

  @override
  final String displayName;

  @override
  String get groupName => 'test';

  @override
  DownloadStatus get status => _status;

  @override
  Future<bool> run() async {
    _status = DownloadStatus.downloading;
    notifyListeners();
    if (!started.isCompleted) started.complete();
    await _released.future;
    if (_pauseRequested) {
      _status = DownloadStatus.paused;
      notifyListeners();
      return false;
    }
    _status = DownloadStatus.completed;
    notifyListeners();
    return true;
  }

  @override
  void pause() {
    if (!isActive) return;
    _pauseRequested = true;
    if (!_released.isCompleted) _released.complete();
  }

  @override
  Future<void> cancel() async {
    _status = DownloadStatus.canceled;
    if (!_released.isCompleted) _released.complete();
    notifyListeners();
  }

  @override
  void reset() {
    if (isActive) return;
    _pauseRequested = false;
    _status = DownloadStatus.queued;
    notifyListeners();
  }

  @override
  void restoreState(DownloadStatus status, int receivedBytes) {
    _status = status;
  }

  @override
  Map<String, dynamic> toPersistedJson() => {
    'type': 'test',
    'savePath': savePath,
    'displayName': displayName,
  };
}

class _FinalizingDownloadJob extends DownloadJob {
  _FinalizingDownloadJob(this.displayName);

  final Completer<void> started = Completer<void>();
  final Completer<void> enteredFinalization = Completer<void>();
  final Completer<void> _downloadFinished = Completer<void>();
  final Completer<void> _finalizationFinished = Completer<void>();

  DownloadStatus _status = DownloadStatus.queued;

  @override
  String get savePath => displayName;

  @override
  int get totalSize => 1;

  @override
  int get receivedBytes => _status == DownloadStatus.queued ? 0 : 1;

  @override
  double get progress => receivedBytes / totalSize;

  @override
  double get speed => 0;

  @override
  String? get error => null;

  @override
  final String displayName;

  @override
  String get groupName => 'test';

  @override
  DownloadStatus get status => _status;

  @override
  Future<bool> run() async {
    _status = DownloadStatus.downloading;
    notifyListeners();
    if (!started.isCompleted) started.complete();
    await _downloadFinished.future;
    if (_status == DownloadStatus.canceled ||
        _status == DownloadStatus.paused) {
      return false;
    }
    _status = DownloadStatus.verifying;
    notifyListeners();
    if (!enteredFinalization.isCompleted) enteredFinalization.complete();
    await _finalizationFinished.future;
    if (_status == DownloadStatus.canceled ||
        _status == DownloadStatus.paused) {
      return false;
    }
    _status = DownloadStatus.completed;
    notifyListeners();
    return true;
  }

  void finishDownload() {
    if (!_downloadFinished.isCompleted) _downloadFinished.complete();
  }

  void finishFinalization() {
    if (!_finalizationFinished.isCompleted) _finalizationFinished.complete();
  }

  @override
  void pause() {
    if (!isActive) return;
    _status = DownloadStatus.paused;
    finishDownload();
    finishFinalization();
    notifyListeners();
  }

  @override
  Future<void> cancel() async {
    _status = DownloadStatus.canceled;
    finishDownload();
    finishFinalization();
    notifyListeners();
  }

  @override
  void reset() {
    if (isActive) return;
    _status = DownloadStatus.queued;
    notifyListeners();
  }

  @override
  void restoreState(DownloadStatus status, int receivedBytes) {
    _status = status;
  }

  @override
  Map<String, dynamic> toPersistedJson() => {
    'type': 'test',
    'savePath': savePath,
    'displayName': displayName,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dm_test_');
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  GamePackageFile file(String name, {int size = 100}) => GamePackageFile(
    url: 'http://127.0.0.1:1/$name',
    md5: 'abc',
    size: size,
    decompressedSize: size,
  );

  SophonManifestMeta sophonMeta() => const SophonManifestMeta(
    categoryId: 'game',
    categoryName: 'Game Resource',
    matchingField: 'game',
    manifestId: 'manifest',
    manifestChecksum: '',
    manifestCompressedSize: 0,
    manifestUncompressedSize: 0,
    manifestUrlPrefix: 'http://127.0.0.1:1/manifests',
    manifestUrlSuffix: '',
    chunkUrlPrefix: 'http://127.0.0.1:1/chunks',
    chunkUrlSuffix: '',
    compressedSize: 10,
    uncompressedSize: 20,
    fileCount: 0,
    chunkCount: 0,
  );

  test(
    'persists tasks and restores them as paused with tmp progress',
    () async {
      final prefs = await SharedPreferences.getInstance();
      // maxConcurrent 0 keeps tasks queued so nothing actually downloads.
      final m1 = DownloadManager(maxConcurrent: 0, prefs: prefs);
      m1.addPackageFiles(
        groupName: 'Game 1.0',
        saveDir: tempDir.path,
        files: [file('a.zip'), file('b.zip')],
      );
      expect(m1.tasks, hasLength(2));

      // Simulate progress from an interrupted download of a.zip.
      await File('${tempDir.path}/a.zip_tmp').writeAsBytes(List.filled(40, 0));
      // b.zip finished completely in the previous session.
      await File('${tempDir.path}/b.zip').writeAsBytes(List.filled(100, 0));

      // A "new session" restores from the same prefs storage.
      final m2 = DownloadManager(prefs: prefs);
      await m2.restoreTasks();

      expect(m2.tasks, hasLength(2));
      final a = m2.tasks.firstWhere((t) => t.displayName == 'a.zip');
      final b = m2.tasks.firstWhere((t) => t.displayName == 'b.zip');
      expect(a.status, DownloadStatus.paused);
      expect(a.receivedBytes, 40);
      expect(b.status, DownloadStatus.completed);
      expect(b.receivedBytes, 100);
    },
  );

  test('canceled tasks are not persisted', () async {
    final prefs = await SharedPreferences.getInstance();
    final m1 = DownloadManager(maxConcurrent: 0, prefs: prefs);
    m1.addPackageFiles(
      groupName: 'Game 1.0',
      saveDir: tempDir.path,
      files: [file('a.zip'), file('b.zip')],
    );
    await m1.cancel(m1.tasks.first);

    final m2 = DownloadManager(prefs: prefs);
    await m2.restoreTasks();
    expect(m2.tasks, hasLength(1));
    expect(m2.tasks.single.displayName, 'b.zip');
  });

  test('pausing active task does not start queued task', () async {
    final manager = DownloadManager(maxConcurrent: 1);
    final first = _BlockingDownloadJob('${tempDir.path}/a.zip');
    final second = _BlockingDownloadJob('${tempDir.path}/b.zip');

    manager.addJobForTesting(first);
    manager.addJobForTesting(second);
    await first.started.future;

    expect(first.status, DownloadStatus.downloading);
    expect(second.status, DownloadStatus.queued);

    manager.pause(first);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (first.status != DownloadStatus.paused &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(first.status, DownloadStatus.paused);
    expect(second.status, DownloadStatus.queued);
    expect(second.started.isCompleted, isFalse);
  });

  test(
    'finalizing task keeps queue slot when the setting is disabled',
    () async {
      final manager = DownloadManager(maxConcurrent: 1);
      final first = _FinalizingDownloadJob('${tempDir.path}/a.zip');
      final second = _BlockingDownloadJob('${tempDir.path}/b.zip');

      manager.addJobForTesting(first);
      manager.addJobForTesting(second);
      await first.started.future;
      first.finishDownload();
      await first.enteredFinalization.future;
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(first.status, DownloadStatus.verifying);
      expect(second.status, DownloadStatus.queued);
      expect(second.started.isCompleted, isFalse);

      first.finishFinalization();
      await second.started.future;
      await manager.cancel(second);
    },
  );

  test(
    'finalizing task releases queue slot when the setting is enabled',
    () async {
      final manager = DownloadManager(
        maxConcurrent: 1,
        continueDownloadsDuringFinalization: true,
      );
      final first = _FinalizingDownloadJob('${tempDir.path}/a.zip');
      final second = _BlockingDownloadJob('${tempDir.path}/b.zip');

      manager.addJobForTesting(first);
      manager.addJobForTesting(second);
      await first.started.future;
      first.finishDownload();
      await first.enteredFinalization.future;
      await second.started.future;

      expect(first.status, DownloadStatus.verifying);
      expect(second.status, DownloadStatus.downloading);
      expect(manager.activeCount, 1);

      await manager.cancel(first);
      await manager.cancel(second);
    },
  );

  test('persists and restores mixed package and Sophon tasks', () async {
    final prefs = await SharedPreferences.getInstance();
    final cacheDir = '${tempDir.path}/fast_cache';
    final m1 = DownloadManager(maxConcurrent: 0, prefs: prefs);
    m1.addPackageFiles(
      groupName: 'Game 1.0',
      saveDir: tempDir.path,
      cacheDir: cacheDir,
      files: [file('a.zip')],
    );
    m1.addSophonManifests(
      groupName: 'Game 1.0',
      saveDir: tempDir.path,
      version: '1.0',
      chunkCacheDir: cacheDir,
      manifests: [(sophonMeta(), const SophonChunkManifest(files: []))],
    );

    final m2 = DownloadManager(prefs: prefs);
    await m2.restoreTasks();

    expect(m2.tasks, hasLength(2));
    final packageTask = m2.tasks.firstWhere((t) => t.displayName == 'a.zip');
    final sophonTask = m2.tasks.firstWhere((t) => t.displayName == '游戏资源');
    expect(packageTask.status, DownloadStatus.paused);
    expect((packageTask as DownloadTask).cacheDir, cacheDir);
    expect(sophonTask.status, DownloadStatus.paused);
    expect(sophonTask.totalSize, 10);
    expect(sophonTask.savePath, '${tempDir.path}/game');
    expect((sophonTask as SophonDownloadTask).cacheDir, '$cacheDir/game');
  });

  test(
    'AppSettings stores cache directory and experimental chunk flag',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final settings = AppSettings(prefs);
      final cacheDir = '${tempDir.path}/internal_cache';

      expect(settings.experimentalChunkEnabled, isFalse);
      expect(settings.packageCacheEnabled, isFalse);
      expect(settings.continueDownloadsDuringFinalization, isFalse);
      expect(settings.resolvePackageCacheDir(), isNull);
      expect(
        settings.resolveChunkCacheDir('${tempDir.path}/download'),
        '${tempDir.path}/download/.sophon/chunks',
      );

      await settings.setExperimentalChunkEnabled(true);
      expect(settings.experimentalChunkEnabled, isTrue);

      await settings.setCacheDir(cacheDir);
      expect(settings.customCacheDir, cacheDir);
      expect(settings.customChunkCacheDir, cacheDir);
      expect(settings.resolvePackageCacheDir(), isNull);
      expect(
        settings.resolveChunkCacheDir('${tempDir.path}/download'),
        cacheDir,
      );

      await settings.setPackageCacheEnabled(true);
      expect(settings.packageCacheEnabled, isTrue);
      expect(settings.resolvePackageCacheDir(), cacheDir);

      await settings.setContinueDownloadsDuringFinalization(true);
      expect(settings.continueDownloadsDuringFinalization, isTrue);

      await settings.setCacheDir(null);
      expect(settings.customCacheDir, isNull);
      expect(settings.resolvePackageCacheDir(), isNull);
    },
  );

  test('portable Sophon records omit local chunk cache directory', () async {
    final mobileDir = '${tempDir.path}/mobile/Game_1.0';
    final cacheDir = '${tempDir.path}/internal_cache';
    final manager = DownloadManager(maxConcurrent: 0);
    manager.addSophonManifests(
      groupName: 'Game 1.0',
      saveDir: mobileDir,
      version: '1.0',
      chunkCacheDir: cacheDir,
      manifests: [(sophonMeta(), const SophonChunkManifest(files: []))],
    );

    final record = File(
      '$mobileDir/${DownloadManager.portableTaskRecordFileName}',
    );
    final exported =
        jsonDecode(await record.readAsString()) as Map<String, dynamic>;
    final task =
        (exported['tasks'] as List<dynamic>).single as Map<String, dynamic>;

    expect(task['saveDir'], '.');
    expect(task.containsKey('chunkCacheDir'), isFalse);
  });

  test(
    'clearChunkCaches deletes inactive and orphan download caches only',
    () async {
      final cacheDir = '${tempDir.path}/internal_cache';
      final saveDir = '${tempDir.path}/download';
      final manager = DownloadManager(maxConcurrent: 0);
      manager.addPackageFiles(
        groupName: 'Game 1.0',
        saveDir: saveDir,
        cacheDir: cacheDir,
        files: [file('a.zip')],
      );
      manager.addSophonManifests(
        groupName: 'Game 1.0',
        saveDir: saveDir,
        version: '1.0',
        chunkCacheDir: cacheDir,
        manifests: [(sophonMeta(), const SophonChunkManifest(files: []))],
      );
      final packageTask = manager.tasks.first as DownloadTask;
      final sophonTask = manager.tasks.last as SophonDownloadTask;
      final packageCache = File(packageTask.tmpPath);
      final chunkCache = Directory(sophonTask.cacheDir);
      final orphanCache = Directory('$cacheDir/orphan');
      final finalDir = Directory(sophonTask.savePath);
      await packageCache.parent.create(recursive: true);
      await packageCache.writeAsBytes([1, 2, 3]);
      await chunkCache.create(recursive: true);
      await File('${chunkCache.path}/chunk').writeAsBytes([1, 2, 3]);
      await orphanCache.create(recursive: true);
      await File('${orphanCache.path}/chunk').writeAsBytes([7, 8, 9]);
      await finalDir.create(recursive: true);
      await File('${finalDir.path}/file.bin').writeAsBytes([4, 5, 6]);

      final count = await manager.clearChunkCaches(extraRoots: [cacheDir]);

      expect(count, 3);
      expect(await packageCache.exists(), isFalse);
      expect(await chunkCache.exists(), isFalse);
      expect(await orphanCache.exists(), isFalse);
      expect(await finalDir.exists(), isTrue);
    },
  );

  test(
    'writes portable task records and imports them from copied directory',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final mobileDir = '${tempDir.path}/mobile/Game_1.0';
      final m1 = DownloadManager(maxConcurrent: 0, prefs: prefs);
      m1.addPackageFiles(
        groupName: 'Game 1.0',
        saveDir: mobileDir,
        cacheDir: '${tempDir.path}/internal_cache',
        files: [file('a.zip')],
      );

      final record = File(
        '$mobileDir/${DownloadManager.portableTaskRecordFileName}',
      );
      expect(await record.exists(), isTrue);
      final exported =
          jsonDecode(await record.readAsString()) as Map<String, dynamic>;
      final tasks = exported['tasks'] as List<dynamic>;
      final task = tasks.single as Map<String, dynamic>;
      expect(task['savePath'], 'a.zip');
      expect(task.containsKey('cacheDir'), isFalse);

      final pcDir = '${tempDir.path}/pc/Game_1.0';
      await Directory(pcDir).create(recursive: true);
      await File(
        '$pcDir/${DownloadManager.portableTaskRecordFileName}',
      ).writeAsString(await record.readAsString());

      final m2 = DownloadManager(maxConcurrent: 0);
      final added = await m2.importTaskRecordsFromDirectory(
        '${tempDir.path}/pc',
      );

      expect(added, 1);
      expect(m2.tasks.single.displayName, 'a.zip');
      expect(m2.tasks.single.savePath, '$pcDir/a.zip');
      expect(m2.tasks.single.status, DownloadStatus.paused);
    },
  );

  test(
    'removeTask can keep downloaded files while deleting only the record',
    () async {
      final manager = DownloadManager(maxConcurrent: 0);
      manager.addPackageFiles(
        groupName: 'Game 1.0',
        saveDir: tempDir.path,
        files: [file('a.zip')],
      );
      final finalFile = File('${tempDir.path}/a.zip');
      final tmpFile = File('${tempDir.path}/a.zip_tmp');
      await finalFile.writeAsBytes([1, 2, 3]);
      await tmpFile.writeAsBytes([4, 5, 6]);

      await manager.removeTask(manager.tasks.single);

      expect(manager.tasks, isEmpty);
      expect(await finalFile.exists(), isTrue);
      expect(await tmpFile.exists(), isTrue);
      expect(
        await File(
          '${tempDir.path}/${DownloadManager.portableTaskRecordFileName}',
        ).exists(),
        isFalse,
      );
    },
  );

  test('removeAllTasks can keep records files or delete everything', () async {
    final manager = DownloadManager(maxConcurrent: 0);
    final cacheDir = '${tempDir.path}/internal_cache';
    manager.addPackageFiles(
      groupName: 'Game 1.0',
      saveDir: tempDir.path,
      cacheDir: cacheDir,
      files: [file('a.zip'), file('b.zip')],
    );
    final firstTask = manager.tasks.first as DownloadTask;
    final finalFile = File('${tempDir.path}/a.zip');
    final cacheFile = File(firstTask.tmpPath);
    await finalFile.writeAsBytes([1, 2, 3]);
    await cacheFile.parent.create(recursive: true);
    await cacheFile.writeAsBytes([4, 5, 6]);

    await manager.removeAllTasks();

    expect(manager.tasks, isEmpty);
    expect(await finalFile.exists(), isTrue);
    expect(await cacheFile.exists(), isTrue);

    manager.addPackageFiles(
      groupName: 'Game 1.0',
      saveDir: tempDir.path,
      cacheDir: cacheDir,
      files: [file('a.zip')],
    );
    await manager.removeAllTasks(deleteFiles: true);

    expect(manager.tasks, isEmpty);
    expect(await finalFile.exists(), isFalse);
    expect(await cacheFile.exists(), isFalse);
  });

  test('removeTask can delete both task record and files', () async {
    final manager = DownloadManager(maxConcurrent: 0);
    manager.addPackageFiles(
      groupName: 'Game 1.0',
      saveDir: tempDir.path,
      files: [file('a.zip')],
    );
    final finalFile = File('${tempDir.path}/a.zip');
    final tmpFile = File('${tempDir.path}/a.zip_tmp');
    await finalFile.writeAsBytes([1, 2, 3]);
    await tmpFile.writeAsBytes([4, 5, 6]);

    await manager.removeTask(manager.tasks.single, deleteFiles: true);

    expect(manager.tasks, isEmpty);
    expect(await finalFile.exists(), isFalse);
    expect(await tmpFile.exists(), isFalse);
  });

  test('maxConcurrent is adjustable at runtime and clamped', () {
    final manager = DownloadManager(maxConcurrent: 0);
    manager.addPackageFiles(
      groupName: 'Game 1.0',
      saveDir: tempDir.path,
      files: [file('a.zip')],
    );
    // Tasks stay queued while the limit is 0.
    expect(manager.tasks.single.status, DownloadStatus.queued);

    manager.maxConcurrent = 3;
    expect(manager.maxConcurrent, 3);
    // Raising the limit pumps the queue (the fake url fails, but the task
    // must have left the queued state).
    expect(manager.tasks.single.status, isNot(DownloadStatus.queued));

    manager.maxConcurrent = 99;
    expect(manager.maxConcurrent, 8);
    manager.maxConcurrent = -1;
    expect(manager.maxConcurrent, 1);
  });

  test('setSpeedLimit forwards to the shared rate limiter', () {
    final manager = DownloadManager(maxConcurrent: 0);
    manager.setSpeedLimit(2 * 1024 * 1024);
    expect(manager.rateLimiter.bytesPerSecond, 2 * 1024 * 1024);
    manager.setSpeedLimit(0);
    expect(manager.rateLimiter.bytesPerSecond, 0);
  });
}
