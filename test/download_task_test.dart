import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hoyo_downloader/download/download_job.dart';
import 'package:hoyo_downloader/download/download_task.dart';
import 'package:hoyo_downloader/download/rate_limiter.dart';

/// A tiny local HTTP server supporting Range requests, used to verify the
/// download engine's resume and md5 logic without touching the real CDN.
/// [throttle] delays each chunk so tests can pause mid-transfer reliably.
class _RangeServer {
  _RangeServer(this.data, {this.throttle});

  static const chunkSize = 64 * 1024;

  final Uint8List data;
  final Duration? throttle;
  late HttpServer _server;
  int requestCount = 0;

  Future<Uri> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      requestCount++;
      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      int start = 0;
      if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
        start = int.parse(rangeHeader.substring(6).split('-').first);
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${data.length - 1}/${data.length}',
        );
      }
      request.response.headers.contentLength = data.length - start;
      try {
        if (throttle == null) {
          request.response.add(data.sublist(start));
        } else {
          for (int i = start; i < data.length; i += chunkSize) {
            request.response.add(
              data.sublist(i, min(i + chunkSize, data.length)),
            );
            await request.response.flush();
            await Future<void>.delayed(throttle!);
          }
        }
        await request.response.close();
      } catch (_) {
        // Client aborted mid-transfer (pause/cancel), nothing to do.
      }
    });
    return Uri.parse('http://127.0.0.1:${_server.port}/file.bin');
  }

  Future<void> stop() => _server.close(force: true);
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dl_test_');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  Uint8List randomBytes(int length) {
    final rng = Random(42);
    return Uint8List.fromList(List.generate(length, (_) => rng.nextInt(256)));
  }

  test('downloads a file and verifies md5', () async {
    final data = randomBytes(256 * 1024);
    final server = _RangeServer(data);
    final uri = await server.start();

    final savePath = '${tempDir.path}/file.bin';
    final task = DownloadTask(
      url: uri.toString(),
      savePath: savePath,
      totalSize: data.length,
      expectedMd5: hex.encode(md5.convert(data).bytes),
      displayName: 'file.bin',
    );
    final ok = await task.run();

    expect(ok, isTrue);
    expect(task.status, DownloadStatus.completed);
    expect(task.receivedBytes, data.length);
    expect(await File(savePath).length(), data.length);
    expect(File('${savePath}_tmp').existsSync(), isFalse);
    await server.stop();
  });

  test('reports progress while verifying package md5', () async {
    final data = randomBytes(2 * 1024 * 1024);
    final server = _RangeServer(data);
    final uri = await server.start();

    final savePath = '${tempDir.path}/file.bin';
    final task = DownloadTask(
      url: uri.toString(),
      savePath: savePath,
      totalSize: data.length,
      expectedMd5: hex.encode(md5.convert(data).bytes),
      displayName: 'file.bin',
    );
    final verifyingProgress = <int>[];
    final downloadProgressDuringVerify = <int>[];
    task.addListener(() {
      if (task.status == DownloadStatus.verifying) {
        verifyingProgress.add(task.verificationBytes);
        downloadProgressDuringVerify.add(task.receivedBytes);
      }
    });

    final ok = await task.run();

    expect(ok, isTrue);
    expect(verifyingProgress, contains(0));
    expect(verifyingProgress.where((value) => value > 0), isNotEmpty);
    expect(verifyingProgress.last, data.length);
    expect(downloadProgressDuringVerify.toSet(), {data.length});
    await server.stop();
  });

  test(
    'downloads through custom cache directory then copies to final path',
    () async {
      final data = randomBytes(2 * 1024 * 1024);
      final server = _RangeServer(data);
      final uri = await server.start();

      final savePath = '${tempDir.path}/external/file.bin';
      final cacheDir = '${tempDir.path}/internal_cache';
      final task = DownloadTask(
        url: uri.toString(),
        savePath: savePath,
        totalSize: data.length,
        expectedMd5: hex.encode(md5.convert(data).bytes),
        displayName: 'file.bin',
        cacheDir: cacheDir,
      );
      final publishingProgress = <int>[];
      final publishedFileLengths = <int>[];
      task.addListener(() {
        if (task.status == DownloadStatus.publishing) {
          publishingProgress.add(task.publishingBytes);
          final file = File(savePath);
          publishedFileLengths.add(file.existsSync() ? file.lengthSync() : 0);
        }
      });
      final ok = await task.run();

      expect(ok, isTrue);
      expect(task.status, DownloadStatus.completed);
      expect(await File(savePath).readAsBytes(), data);
      expect(File('${savePath}_tmp').existsSync(), isFalse);
      expect(File(task.tmpPath).existsSync(), isFalse);
      expect(task.tmpPath.startsWith(cacheDir), isTrue);
      expect(publishingProgress, contains(0));
      expect(publishingProgress.where((value) => value > 0), isNotEmpty);
      expect(publishingProgress.last, data.length);
      for (var i = 0; i < publishingProgress.length; i++) {
        expect(
          publishingProgress[i],
          lessThanOrEqualTo(publishedFileLengths[i]),
        );
      }
      await server.stop();
    },
  );

  test(
    'retry copies validated cache without redownloading after publish failure',
    () async {
      final data = randomBytes(256 * 1024);
      final server = _RangeServer(data);
      final uri = await server.start();

      final blockedParent = '${tempDir.path}/external';
      final savePath = '$blockedParent/file.bin';
      final cacheDir = '${tempDir.path}/internal_cache';
      await File(blockedParent).writeAsString('u disk unavailable');
      final task = DownloadTask(
        url: uri.toString(),
        savePath: savePath,
        totalSize: data.length,
        expectedMd5: hex.encode(md5.convert(data).bytes),
        displayName: 'file.bin',
        cacheDir: cacheDir,
      );

      final firstOk = await task.run();

      expect(firstOk, isFalse);
      expect(task.status, DownloadStatus.failed);
      expect(server.requestCount, 1);
      expect(File(task.tmpPath).existsSync(), isTrue);
      expect(File(task.validatedCacheMarkerPath!).existsSync(), isTrue);

      await File(blockedParent).delete();
      task.reset();
      final secondOk = await task.run();

      expect(secondOk, isTrue);
      expect(task.status, DownloadStatus.completed);
      expect(server.requestCount, 1);
      expect(await File(savePath).readAsBytes(), data);
      expect(File(task.tmpPath).existsSync(), isFalse);
      expect(File(task.validatedCacheMarkerPath!).existsSync(), isFalse);
      await server.stop();
    },
  );

  test('resumes from existing tmp file with Range header', () async {
    final data = randomBytes(256 * 1024);
    final server = _RangeServer(data);
    final uri = await server.start();

    final savePath = '${tempDir.path}/file.bin';
    // Simulate a previously interrupted download: half the file on disk.
    final half = data.length ~/ 2;
    await File('${savePath}_tmp').writeAsBytes(data.sublist(0, half));

    final task = DownloadTask(
      url: uri.toString(),
      savePath: savePath,
      totalSize: data.length,
      expectedMd5: hex.encode(md5.convert(data).bytes),
      displayName: 'file.bin',
    );
    final ok = await task.run();

    expect(ok, isTrue);
    expect(task.status, DownloadStatus.completed);
    // The completed file must be byte-identical despite the resume.
    expect(await File(savePath).readAsBytes(), data);
    await server.stop();
  });

  test('redownloads existing final file when md5 mismatches', () async {
    final data = randomBytes(128 * 1024);
    final server = _RangeServer(data);
    final uri = await server.start();

    final savePath = '${tempDir.path}/file.bin';
    // Same length, wrong content: size-only checks would incorrectly skip it.
    await File(savePath).writeAsBytes(List.filled(data.length, 1));
    final task = DownloadTask(
      url: uri.toString(),
      savePath: savePath,
      totalSize: data.length,
      expectedMd5: hex.encode(md5.convert(data).bytes),
      displayName: 'file.bin',
    );
    final ok = await task.run();

    expect(ok, isTrue);
    expect(task.status, DownloadStatus.completed);
    expect(await File(savePath).readAsBytes(), data);
    await server.stop();
  });

  test('fails and deletes tmp when md5 mismatches', () async {
    final data = randomBytes(64 * 1024);
    final server = _RangeServer(data);
    final uri = await server.start();

    final savePath = '${tempDir.path}/file.bin';
    final task = DownloadTask(
      url: uri.toString(),
      savePath: savePath,
      totalSize: data.length,
      expectedMd5: '0' * 32,
      displayName: 'file.bin',
    );
    final ok = await task.run();

    expect(ok, isFalse);
    expect(task.status, DownloadStatus.failed);
    expect(File(savePath).existsSync(), isFalse);
    expect(File('${savePath}_tmp').existsSync(), isFalse);
    await server.stop();
  });

  test(
    'auto retries once from scratch after corrupted tmp md5 mismatch',
    () async {
      final data = randomBytes(128 * 1024);
      final server = _RangeServer(data);
      final uri = await server.start();

      final savePath = '${tempDir.path}/file.bin';
      // A full-size but corrupted tmp simulates a bad resume/CDN range result.
      await File('${savePath}_tmp').writeAsBytes(List.filled(data.length, 2));
      final task = DownloadTask(
        url: uri.toString(),
        savePath: savePath,
        totalSize: data.length,
        expectedMd5: hex.encode(md5.convert(data).bytes),
        displayName: 'file.bin',
      );
      final ok = await task.run();

      expect(ok, isTrue);
      expect(task.status, DownloadStatus.completed);
      expect(await File(savePath).readAsBytes(), data);
      // No network request for the first bad tmp verification, then one clean
      // redownload request after the mismatch is detected.
      expect(server.requestCount, 1);
      await server.stop();
    },
  );

  test('rate limiter throttles a real transfer', () async {
    final data = randomBytes(512 * 1024);
    final server = _RangeServer(data);
    final uri = await server.start();

    // 256 KB/s: the first-second burst covers half the file, the rest
    // needs ~1 s of refill, so the download cannot finish instantly.
    final limiter = RateLimiter()..setLimit(256 * 1024);
    final savePath = '${tempDir.path}/file.bin';
    final task = DownloadTask(
      url: uri.toString(),
      savePath: savePath,
      totalSize: data.length,
      expectedMd5: hex.encode(md5.convert(data).bytes),
      displayName: 'file.bin',
      rateLimiter: limiter,
    );
    final sw = Stopwatch()..start();
    final ok = await task.run();
    sw.stop();

    expect(ok, isTrue);
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(600));
    expect(await File(savePath).readAsBytes(), data);
    await server.stop();
  });

  test('pause stops the task, resume completes it', () async {
    final data = randomBytes(1024 * 1024);
    // Throttled server: 64 KB per 30 ms, the full file takes ~500 ms so the
    // pause below is guaranteed to land mid-transfer on any runner speed.
    final server = _RangeServer(
      data,
      throttle: const Duration(milliseconds: 30),
    );
    final uri = await server.start();

    final savePath = '${tempDir.path}/file.bin';
    final task = DownloadTask(
      url: uri.toString(),
      savePath: savePath,
      totalSize: data.length,
      expectedMd5: hex.encode(md5.convert(data).bytes),
      displayName: 'file.bin',
    );

    final firstRun = task.run();
    // Wait until some bytes arrived, then pause mid-transfer.
    while (task.receivedBytes == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    task.pause();
    final ok1 = await firstRun;

    expect(ok1, isFalse);
    expect(task.status, DownloadStatus.paused);
    expect(File('${savePath}_tmp').existsSync(), isTrue);
    expect(task.receivedBytes, lessThan(data.length));

    task.reset();
    final ok2 = await task.run();

    expect(ok2, isTrue);
    expect(task.status, DownloadStatus.completed);
    // Resume must have issued a second (Range) request.
    expect(server.requestCount, greaterThanOrEqualTo(2));
    expect(await File(savePath).readAsBytes(), data);
    await server.stop();
  });
}
