import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hoyo_downloader/download/download_manager.dart';
import 'package:hoyo_downloader/download/download_task.dart';
import 'package:hoyo_downloader/models/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  test('persists tasks and restores them as paused with tmp progress',
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
  });

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
}
