import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hoyo_downloader/download/download_task.dart';

/// A tiny local HTTP server supporting Range requests, used to verify the
/// download engine's resume and md5 logic without touching the real CDN.
class _RangeServer {
  _RangeServer(this.data);

  final Uint8List data;
  late HttpServer _server;
  int requestCount = 0;

  Future<Uri> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) {
      requestCount++;
      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      int start = 0;
      if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
        start = int.parse(rangeHeader.substring(6).split('-').first);
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(HttpHeaders.contentRangeHeader,
            'bytes $start-${data.length - 1}/${data.length}');
      }
      request.response.headers.contentLength = data.length - start;
      request.response.add(data.sublist(start));
      request.response.close();
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
    return Uint8List.fromList(
        List.generate(length, (_) => rng.nextInt(256)));
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

  test('pause stops the task, resume completes it', () async {
    final data = randomBytes(1024 * 1024);
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

    final firstRun = task.run();
    // Pause almost immediately after the transfer starts.
    await Future<void>.delayed(const Duration(milliseconds: 10));
    task.pause();
    final ok1 = await firstRun;
    expect(ok1, isFalse);

    // Paused (or already finished on a very fast loopback).
    if (task.status == DownloadStatus.paused) {
      task.reset();
      final ok2 = await task.run();
      expect(ok2, isTrue);
    }
    expect(await File(savePath).readAsBytes(), data);
    await server.stop();
  });
}
