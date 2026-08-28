import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hoyo_downloader/download/download_job.dart';
import 'package:hoyo_downloader/download/rate_limiter.dart';
import 'package:hoyo_downloader/download/sophon_download_task.dart';
import 'package:hoyo_downloader/download/verified_file_index.dart';
import 'package:hoyo_downloader/download/zstd_codec.dart';
import 'package:hoyo_downloader/models/sophon_models.dart';

class _FakeZstdCodec implements ZstdCodec {
  const _FakeZstdCodec();

  @override
  Future<Uint8List?> decompress(Uint8List data) async => data;
}

class _ChunkServer {
  _ChunkServer(
    this.chunks, {
    this.throttle,
    this.chunkSize = 64 * 1024,
    Map<String, int>? failuresBeforeSuccess,
  }) : failuresBeforeSuccess = failuresBeforeSuccess ?? const {};

  final Map<String, Uint8List> chunks;
  final Duration? throttle;
  final int chunkSize;
  final Map<String, int> failuresBeforeSuccess;
  final Map<String, int> hits = {};
  late HttpServer _server;

  Future<Uri> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      final id = request.uri.pathSegments.last;
      hits[id] = (hits[id] ?? 0) + 1;
      if ((hits[id] ?? 0) <= (failuresBeforeSuccess[id] ?? 0)) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
        return;
      }
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
    'starts next file chunk download while current file is verifying',
    () async {
      final firstBytes = Uint8List.fromList(List.filled(16 * 1024 * 1024, 1));
      final secondBytes = Uint8List.fromList(List.filled(256 * 1024, 2));
      final chunks = {'first': firstBytes, 'second': secondBytes};
      final manifest = SophonChunkManifest(
        files: [
          SophonFile(
            file: 'Game/first.bin',
            chunks: [
              SophonChunk(
                id: 'first',
                uncompressedMd5: hex.encode(md5.convert(firstBytes).bytes),
                offset: 0,
                compressedSize: firstBytes.length,
                uncompressedSize: firstBytes.length,
                compressedMd5: hex.encode(md5.convert(firstBytes).bytes),
              ),
            ],
            isFolder: false,
            size: firstBytes.length,
            md5: hex.encode(md5.convert(firstBytes).bytes),
          ),
          SophonFile(
            file: 'Game/second.bin',
            chunks: [
              SophonChunk(
                id: 'second',
                uncompressedMd5: hex.encode(md5.convert(secondBytes).bytes),
                offset: 0,
                compressedSize: secondBytes.length,
                uncompressedSize: secondBytes.length,
                compressedMd5: hex.encode(md5.convert(secondBytes).bytes),
              ),
            ],
            isFolder: false,
            size: secondBytes.length,
            md5: hex.encode(md5.convert(secondBytes).bytes),
          ),
        ],
      );
      final server = _ChunkServer(chunks);
      final baseUrl = await server.start();
      final meta = SophonManifestMeta.fromPersistedJson({
        ...const SophonManifestMeta(
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
          uncompressedSize: 0,
          fileCount: 2,
          chunkCount: 2,
        ).toJson(),
        'chunkUrlPrefix': baseUrl.toString(),
        'compressedSize': firstBytes.length + secondBytes.length,
      });
      final task = SophonDownloadTask(
        meta: meta,
        initialManifest: manifest,
        saveDir: tempDir.path,
        version: '1.0',
        groupName: 'Test 1.0',
        zstdCodec: const _FakeZstdCodec(),
        prefetchNextFileDuringVerification: true,
      );
      final run = task.run();
      var nextChunkStartedDuringVerify = false;
      while (task.status != DownloadStatus.completed) {
        if (task.status == DownloadStatus.verifying &&
            (server.hits['second'] ?? 0) > 0) {
          nextChunkStartedDuringVerify = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      final ok = await run;

      expect(ok, isTrue);
      expect(nextChunkStartedDuringVerify, isTrue);
      await server.stop();
    },
  );

  test(
    'reuses verified Sophon final file marker without hashing again',
    () async {
      final raw1 = Uint8List.fromList(List.filled(1024 * 1024, 1));
      final raw2 = Uint8List.fromList(List.filled(1024 * 1024, 2));
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
      final first = SophonDownloadTask(
        meta: meta,
        initialManifest: manifest,
        saveDir: tempDir.path,
        version: '1.0',
        groupName: 'Test 1.0',
        zstdCodec: const _FakeZstdCodec(),
      );

      expect(await first.run(), isTrue);
      expect(
        File(
          VerifiedFileIndex.indexPathFor('${tempDir.path}/Game'),
        ).existsSync(),
        isTrue,
      );
      expect(
        File('${tempDir.path}/Game/file.txt.verified').existsSync(),
        isFalse,
      );

      final second = SophonDownloadTask(
        meta: meta,
        initialManifest: manifest,
        saveDir: tempDir.path,
        version: '1.0',
        groupName: 'Test 1.0',
        zstdCodec: const _FakeZstdCodec(),
      );
      final verifyingProgress = <int>[];
      second.addListener(() {
        if (second.status == DownloadStatus.verifying) {
          verifyingProgress.add(second.verificationBytes);
        }
      });

      expect(await second.run(), isTrue);

      final expectedProgress = chunks.values.fold<int>(
        0,
        (s, b) => s + b.length,
      );
      expect(verifyingProgress.first, 0);
      expect(verifyingProgress.where((value) => value > 0).toSet(), {
        expectedProgress,
      });
      await server.stop();
    },
  );

  test('stores large chunk cache in custom cache directory', () async {
    final raw1 = Uint8List.fromList(List.filled(9 * 1024 * 1024, 1));
    final (baseMeta, manifest, chunks) = await fixture(raw1Override: raw1);
    final server = _ChunkServer(chunks);
    final baseUrl = await server.start();
    final cacheDir = '${tempDir.path}/fast_cache';
    final meta = SophonManifestMeta.fromPersistedJson({
      ...baseMeta.toJson(),
      'chunkUrlPrefix': baseUrl.toString(),
      'compressedSize': chunks.values.fold<int>(0, (s, b) => s + b.length),
    });
    final task = SophonDownloadTask(
      meta: meta,
      initialManifest: manifest,
      saveDir: '${tempDir.path}/external_drive',
      chunkCacheDir: cacheDir,
      version: '1.0',
      groupName: 'Test 1.0',
      zstdCodec: const _FakeZstdCodec(),
    );

    var sawPublishing = false;
    task.addListener(() {
      if (task.status == DownloadStatus.publishing) sawPublishing = true;
    });

    final ok = await task.run();

    expect(ok, isTrue);
    expect(task.cacheDir, '$cacheDir/cat');
    expect(
      await Directory('${tempDir.path}/external_drive/.sophon').exists(),
      isFalse,
    );
    // With a fast cache configured, the file is assembled and verified in
    // the cache first, then published (copied) to the final destination.
    expect(sawPublishing, isTrue);
    expect(
      await File('${tempDir.path}/external_drive/Game/file.txt').readAsBytes(),
      Uint8List.fromList([...raw1, ...'world'.codeUnits]),
    );
    expect(
      await File('$cacheDir/cat/assembled/Game/file.txt').exists(),
      isFalse,
    );
    await server.stop();
  });

  test(
    'resumes publish-only after an interrupted copy without redownloading',
    () async {
      final raw1 = Uint8List.fromList(List.filled(9 * 1024 * 1024, 1));
      final (baseMeta, manifest, chunks) = await fixture(raw1Override: raw1);
      final server = _ChunkServer(chunks);
      final baseUrl = await server.start();
      final cacheDir = '${tempDir.path}/fast_cache';
      final meta = SophonManifestMeta.fromPersistedJson({
        ...baseMeta.toJson(),
        'chunkUrlPrefix': baseUrl.toString(),
        'compressedSize': chunks.values.fold<int>(0, (s, b) => s + b.length),
      });
      final first = SophonDownloadTask(
        meta: meta,
        initialManifest: manifest,
        saveDir: '${tempDir.path}/external_drive',
        chunkCacheDir: cacheDir,
        version: '1.0',
        groupName: 'Test 1.0',
        zstdCodec: const _FakeZstdCodec(),
      );
      first.addListener(() {
        if (first.status == DownloadStatus.publishing) first.pause();
      });

      final firstOk = await first.run();

      expect(firstOk, isFalse);
      expect(first.status, DownloadStatus.paused);
      // The cache copy was fully assembled and verified before the publish
      // (copy-to-final) step was interrupted.
      expect(
        await File('$cacheDir/cat/assembled/Game/file.txt').exists(),
        isTrue,
      );

      final second = SophonDownloadTask(
        meta: meta,
        initialManifest: manifest,
        saveDir: '${tempDir.path}/external_drive',
        chunkCacheDir: cacheDir,
        version: '1.0',
        groupName: 'Test 1.0',
        zstdCodec: const _FakeZstdCodec(),
      );

      final secondOk = await second.run();

      expect(secondOk, isTrue);
      expect(
        await File(
          '${tempDir.path}/external_drive/Game/file.txt',
        ).readAsBytes(),
        Uint8List.fromList([...raw1, ...'world'.codeUnits]),
      );
      // Resuming only republished the already-verified cache copy; no chunk
      // was redownloaded.
      expect(server.hits['c1'], 1);
      expect(
        await File('$cacheDir/cat/assembled/Game/file.txt').exists(),
        isFalse,
      );
      await server.stop();
    },
  );

  test(
    'does not prefetch the next file during verification without a fast cache directory',
    () async {
      final firstBytes = Uint8List.fromList(List.filled(16 * 1024 * 1024, 1));
      final secondBytes = Uint8List.fromList(List.filled(256 * 1024, 2));
      final chunks = {'first': firstBytes, 'second': secondBytes};
      final manifest = SophonChunkManifest(
        files: [
          SophonFile(
            file: 'Game/first.bin',
            chunks: [
              SophonChunk(
                id: 'first',
                uncompressedMd5: hex.encode(md5.convert(firstBytes).bytes),
                offset: 0,
                compressedSize: firstBytes.length,
                uncompressedSize: firstBytes.length,
                compressedMd5: hex.encode(md5.convert(firstBytes).bytes),
              ),
            ],
            isFolder: false,
            size: firstBytes.length,
            md5: hex.encode(md5.convert(firstBytes).bytes),
          ),
          SophonFile(
            file: 'Game/second.bin',
            chunks: [
              SophonChunk(
                id: 'second',
                uncompressedMd5: hex.encode(md5.convert(secondBytes).bytes),
                offset: 0,
                compressedSize: secondBytes.length,
                uncompressedSize: secondBytes.length,
                compressedMd5: hex.encode(md5.convert(secondBytes).bytes),
              ),
            ],
            isFolder: false,
            size: secondBytes.length,
            md5: hex.encode(md5.convert(secondBytes).bytes),
          ),
        ],
      );
      // A plain server (instead of _ChunkServer) so the handler can capture
      // the task's status at the exact moment each chunk request lands.
      late SophonDownloadTask task;
      DownloadStatus? secondRequestedStatus;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final id = request.uri.pathSegments.last;
        if (id == 'second') secondRequestedStatus ??= task.status;
        final bytes = chunks[id]!;
        request.response.headers.contentLength = bytes.length;
        request.response.add(bytes);
        await request.response.close();
      });
      final baseUrl = 'http://127.0.0.1:${server.port}/chunks';
      final meta = SophonManifestMeta.fromPersistedJson({
        ...const SophonManifestMeta(
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
          uncompressedSize: 0,
          fileCount: 2,
          chunkCount: 2,
        ).toJson(),
        'chunkUrlPrefix': baseUrl,
        'compressedSize': firstBytes.length + secondBytes.length,
      });
      task = SophonDownloadTask(
        meta: meta,
        initialManifest: manifest,
        saveDir: tempDir.path,
        version: '1.0',
        groupName: 'Test 1.0',
        zstdCodec: const _FakeZstdCodec(),
        prefetchNextFileDuringVerification: true,
      );

      final ok = await task.run();

      expect(ok, isTrue);
      // No chunkCacheDir configured, so the prefetch gate stays closed even
      // though the flag itself is enabled: the second file's chunk is only
      // requested once its own sequential download phase starts, not while
      // the first file is still verifying.
      expect(secondRequestedStatus, DownloadStatus.downloading);
      await server.close(force: true);
    },
  );

  test('retries transient chunk download failures', () async {
    final (baseMeta, manifest, chunks) = await fixture();
    final server = _ChunkServer(chunks, failuresBeforeSuccess: {'c1': 1});
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
    expect(server.hits['c1'], 2);
    expect(
      await File('${tempDir.path}/Game/file.txt').readAsString(),
      'hello world',
    );
    await server.stop();
  });

  test('reports network speed before a chunk is fully processed', () async {
    final raw1 = Uint8List.fromList(List.filled(768 * 1024, 1));
    final raw2 = Uint8List.fromList(List.filled(768 * 1024, 2));
    final (baseMeta, manifest, chunks) = await fixture(
      raw1Override: raw1,
      raw2Override: raw2,
    );
    final server = _ChunkServer(
      chunks,
      throttle: const Duration(milliseconds: 200),
      chunkSize: 64 * 1024,
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

    final run = task.run();
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (task.speed <= 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    expect(task.speed, greaterThan(0));
    expect(task.receivedBytes, lessThan(meta.compressedSize));
    expect(await run, isTrue);
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
