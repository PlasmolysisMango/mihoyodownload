import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hoyo_downloader/download/download_job.dart';
import 'package:hoyo_downloader/download/rate_limiter.dart';
import 'package:hoyo_downloader/download/sophon_download_task.dart';
import 'package:hoyo_downloader/download/zstd_codec.dart';
import 'package:hoyo_downloader/models/sophon_models.dart';

class _FakeZstdCodec implements ZstdCodec {
  const _FakeZstdCodec();

  @override
  Future<Uint8List?> decompress(Uint8List data) async => data;
}

class _ChunkServer {
  _ChunkServer(this.chunks, {this.throttle, this.chunkSize = 64 * 1024});

  final Map<String, Uint8List> chunks;
  final Duration? throttle;
  final int chunkSize;
  final Map<String, int> hits = {};
  late HttpServer _server;

  Future<Uri> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      final id = request.uri.pathSegments.last;
      hits[id] = (hits[id] ?? 0) + 1;
      final bytes = chunks[id];
      if (bytes == null) {
        request.response.statusCode = HttpStatus.notFound;
      } else {
        request.response.headers.contentLength = bytes.length;
        try {
          if (throttle == null) {
            request.response.add(bytes);
          } else {
            for (var i = 0; i < bytes.length; i += chunkSize) {
              request.response.add(
                bytes.sublist(i, min(i + chunkSize, bytes.length)),
              );
              await request.response.flush();
              await Future<void>.delayed(throttle!);
            }
          }
        } catch (_) {
          // Client aborted mid-transfer (pause/cancel), nothing to do.
        }
      }
      await request.response.close();
    });
    return Uri.parse('http://127.0.0.1:${_server.port}/chunks');
  }

  Future<void> stop() => _server.close(force: true);
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sophon_task_');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  Future<(SophonManifestMeta, SophonChunkManifest, Map<String, Uint8List>)>
  fixture({Uint8List? raw1Override, Uint8List? raw2Override}) async {
    final raw1 = raw1Override ?? Uint8List.fromList('hello '.codeUnits);
    final raw2 = raw2Override ?? Uint8List.fromList('world'.codeUnits);
    final c1 = raw1;
    final c2 = raw2;
    final fileBytes = Uint8List.fromList([...raw1, ...raw2]);
    final chunks = [
      SophonChunk(
        id: 'c1',
        uncompressedMd5: hex.encode(md5.convert(raw1).bytes),
        offset: 0,
        compressedSize: c1.length,
        uncompressedSize: raw1.length,
        compressedMd5: hex.encode(md5.convert(c1).bytes),
      ),
      SophonChunk(
        id: 'c2',
        uncompressedMd5: hex.encode(md5.convert(raw2).bytes),
        offset: raw1.length,
        compressedSize: c2.length,
        uncompressedSize: raw2.length,
        compressedMd5: hex.encode(md5.convert(c2).bytes),
      ),
    ];
    const meta = SophonManifestMeta(
      categoryId: 'cat',
      categoryName: 'Test Category',
      matchingField: 'game',
      manifestId: 'manifest',
      manifestChecksum: '',
      manifestCompressedSize: 0,
      manifestUncompressedSize: 0,
      manifestUrlPrefix: '',
      manifestUrlSuffix: '',
      chunkUrlPrefix: '',
      chunkUrlSuffix: '',
      compressedSize: 0,
      uncompressedSize: 11,
      fileCount: 1,
      chunkCount: 2,
    );
    final manifest = SophonChunkManifest(
      files: [
        SophonFile(
          file: 'Game/file.txt',
          chunks: chunks,
          isFolder: false,
          size: fileBytes.length,
          md5: hex.encode(md5.convert(fileBytes).bytes),
        ),
      ],
    );
    return (meta, manifest, {'c1': c1, 'c2': c2});
  }

  test('downloads chunks, verifies them, and assembles final file', () async {
    final (baseMeta, manifest, chunks) = await fixture();
    final server = _ChunkServer(chunks);
    final baseUrl = await server.start();
    final meta = SophonManifestMeta.fromPersistedJson({
      ...baseMeta.toJson(),
      'chunkUrlPrefix': baseUrl.toString(),
      'compressedSize': chunks.values.fold<int>(0, (s, b) => s + b.length),
    });
    final task = SophonDownloadTask(
      meta: meta,
      initialManifest: manifest,
      saveDir: tempDir.path,
      version: '1.0',
      groupName: 'Test 1.0',
      zstdCodec: const _FakeZstdCodec(),
    );

    final ok = await task.run();

    expect(ok, isTrue);
    expect(task.status, DownloadStatus.completed);
    expect(
      await File('${tempDir.path}/Game/file.txt').readAsString(),
      'hello world',
    );
    expect(server.hits['c1'], 1);
    expect(server.hits['c2'], 1);
    await server.stop();
  });

  test(
    'bad cached chunk is redownloaded without redownloading good chunks',
    () async {
      final (baseMeta, manifest, chunks) = await fixture();
      final server = _ChunkServer(chunks);
      final baseUrl = await server.start();
      final meta = SophonManifestMeta.fromPersistedJson({
        ...baseMeta.toJson(),
        'chunkUrlPrefix': baseUrl.toString(),
        'compressedSize': chunks.values.fold<int>(0, (s, b) => s + b.length),
      });
      final cacheDir = Directory('${tempDir.path}/.sophon/chunks/cat');
      await cacheDir.create(recursive: true);
      await File('${cacheDir.path}/c1').writeAsBytes([1, 2, 3]);
      await File('${cacheDir.path}/c2').writeAsBytes(chunks['c2']!);

      final task = SophonDownloadTask(
        meta: meta,
        initialManifest: manifest,
        saveDir: tempDir.path,
        version: '1.0',
        groupName: 'Test 1.0',
        zstdCodec: const _FakeZstdCodec(),
      );

      final ok = await task.run();

      expect(ok, isTrue);
      expect(
        await File('${tempDir.path}/Game/file.txt').readAsString(),
        'hello world',
      );
      expect(server.hits['c1'], 1);
      expect(server.hits['c2'] ?? 0, 0);
      await server.stop();
    },
  );

  test(
    'pause stops Sophon task, resume reuses valid chunks and completes',
    () async {
      final raw1 = Uint8List.fromList(List.filled(512 * 1024, 1));
      final raw2 = Uint8List.fromList(List.filled(512 * 1024, 2));
      final (baseMeta, manifest, chunks) = await fixture(
        raw1Override: raw1,
        raw2Override: raw2,
      );
      final server = _ChunkServer(
        chunks,
        throttle: const Duration(milliseconds: 25),
        chunkSize: 32 * 1024,
      );
      final baseUrl = await server.start();
      final meta = SophonManifestMeta.fromPersistedJson({
        ...baseMeta.toJson(),
        'chunkUrlPrefix': baseUrl.toString(),
        'compressedSize': chunks.values.fold<int>(0, (s, b) => s + b.length),
      });
      final task = SophonDownloadTask(
        meta: meta,
        initialManifest: manifest,
        saveDir: tempDir.path,
        version: '1.0',
        groupName: 'Test 1.0',
        zstdCodec: const _FakeZstdCodec(),
      );

      final firstRun = task.run();
      while ((server.hits['c1'] ?? 0) == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      task.pause();
      final ok1 = await firstRun.timeout(const Duration(seconds: 5));

      expect(ok1, isFalse);
      expect(task.status, DownloadStatus.paused);
      expect(task.receivedBytes, lessThan(meta.compressedSize));

      task.reset();
      final ok2 = await task.run();

      expect(ok2, isTrue);
      expect(task.status, DownloadStatus.completed);
      expect(await File('${tempDir.path}/Game/file.txt').readAsBytes(), [
        ...raw1,
        ...raw2,
      ]);
      await server.stop();
    },
  );

  test('rate limiter throttles Sophon chunk downloads', () async {
    final raw1 = Uint8List.fromList(List.filled(256 * 1024, 1));
    final raw2 = Uint8List.fromList(List.filled(256 * 1024, 2));
    final (baseMeta, manifest, chunks) = await fixture(
      raw1Override: raw1,
      raw2Override: raw2,
    );
    final server = _ChunkServer(chunks);
    final baseUrl = await server.start();
    final meta = SophonManifestMeta.fromPersistedJson({
      ...baseMeta.toJson(),
      'chunkUrlPrefix': baseUrl.toString(),
      'compressedSize': chunks.values.fold<int>(0, (s, b) => s + b.length),
    });
    final limiter = RateLimiter()..setLimit(256 * 1024);
    final task = SophonDownloadTask(
      meta: meta,
      initialManifest: manifest,
      saveDir: tempDir.path,
      version: '1.0',
      groupName: 'Test 1.0',
      rateLimiter: limiter,
      zstdCodec: const _FakeZstdCodec(),
    );

    final sw = Stopwatch()..start();
    final ok = await task.run();
    sw.stop();

    expect(ok, isTrue);
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(600));
    expect(await File('${tempDir.path}/Game/file.txt').readAsBytes(), [
      ...raw1,
      ...raw2,
    ]);
    await server.stop();
  });
}
