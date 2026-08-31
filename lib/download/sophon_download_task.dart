import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../models/sophon_models.dart';
import 'download_job.dart';
import 'rate_limiter.dart';
import 'verified_file_index.dart';
import 'zstd_codec.dart';

const _maxChunkPrefetch = 3;
const _chunkDownloadAttempts = 3;
const _chunkRequestTimeout = Duration(seconds: 30);
const _chunkPartTimeout = Duration(seconds: 30);
const _chunkCacheThreshold = 8 * 1024 * 1024;
const _publishCopyChunkSize = 4 * 1024 * 1024;

/// Downloads one Sophon category by small official chunks.
///
/// Each chunk is cached and verified independently using the official
/// compressed/uncompressed MD5, then decompressed and written to its target
/// file at the manifest-provided offset. A bad chunk only redownloads that
/// chunk; the task never needs to redownload a multi-GB package file.
class SophonDownloadTask extends DownloadJob {
  SophonDownloadTask({
    required this.meta,
    required this.saveDir,
    required this.version,
    required this.groupName,
    this.initialManifest,
    this.chunkCacheDir,
    this.rateLimiter,
    this.prefetchNextFileDuringVerification = false,
    this.zstdCodec = const ZstandardZstdCodec(),
  });

  final SophonManifestMeta meta;
  final String saveDir;
  final String version;
  final String? chunkCacheDir;
  final SophonChunkManifest? initialManifest;
  final RateLimiter? rateLimiter;
  final ZstdCodec zstdCodec;

  /// Whether the next file's chunks should keep downloading while the
  /// current file is in final MD5 verification, publishing, and cleanup.
  /// Prefetched data only lands in the chunk cache; the final (possibly slow,
  /// e.g. USB) target file is still written strictly one file at a time.
  bool prefetchNextFileDuringVerification;

  SophonChunkManifest? _manifest;
  http.Client? _client;
  bool _abortRequested = false;
  Timer? _speedTimer;
  int _lastNetworkBytes = 0;
  int _networkBytes = 0;
  int _receivedBytes = 0;
  int _verificationBytes = 0;
  int _verificationTotalBytes = 0;
  int _publishingBytes = 0;
  int _publishingTotalBytes = 0;
  bool _isPublishingFinalizing = false;
  double _speed = 0;
  String? _error;
  DownloadStatus _status = DownloadStatus.queued;

  @override
  String get savePath => '$saveDir/${meta.matchingField}';

  @override
  int get totalSize => meta.compressedSize;

  @override
  int get receivedBytes => _receivedBytes;

  @override
  int get verificationBytes => _verificationBytes;

  @override
  double get verificationProgress => _verificationTotalBytes <= 0
      ? 0
      : _verificationBytes / _verificationTotalBytes;

  @override
  int get publishingBytes => _publishingBytes;

  @override
  double get publishingProgress =>
      _publishingTotalBytes <= 0 ? 0 : _publishingBytes / _publishingTotalBytes;

  @override
  bool get isPublishingFinalizing => _isPublishingFinalizing;

  @override
  double get progress => totalSize <= 0 ? 0 : _receivedBytes / totalSize;

  @override
  double get speed => _speed;

  @override
  String? get error => _error;

  @override
  String get displayName => meta.displayName;

  @override
  final String groupName;

  @override
  DownloadStatus get status => _status;

  String get cacheDir {
    final root = chunkCacheDir == null || chunkCacheDir!.isEmpty
        ? '$saveDir/.sophon/chunks'
        : chunkCacheDir!;
    return '$root/${meta.categoryId}';
  }

  /// Whether an independent high-speed cache directory is configured.
  ///
  /// Only then does it make sense to assemble and verify each final file in
  /// the cache first, and only copy to the (possibly slow, e.g. USB) final
  /// destination once verification passes; otherwise the cache already lives
  /// on the same device as the final destination, so writing there first and
  /// copying again would just double the slow-device I/O for no benefit.
  bool get _usesFastCacheAssembly {
    final configured = chunkCacheDir;
    if (configured == null || configured.isEmpty) return false;
    return _normalizedDirectoryPath(configured) !=
        _normalizedDirectoryPath('$saveDir/.sophon/chunks');
  }

  @override
  bool get hasFastCache => _usesFastCacheAssembly;

  @override
  Future<bool> run() async {
    if (_status == DownloadStatus.completed) return true;
    _abortRequested = false;
    _error = null;
    _receivedBytes = 0;
    _verificationBytes = 0;
    _verificationTotalBytes = 0;
    _publishingBytes = 0;
    _publishingTotalBytes = 0;
    _isPublishingFinalizing = false;
    _networkBytes = 0;
    _lastNetworkBytes = 0;
    _setStatus(DownloadStatus.downloading);
    _startSpeedTimer();
    _client = http.Client();
    _SophonFileCachePrefetch? prefetchedFile;
    try {
      final manifest = await _loadManifest();
      final files = manifest.files;
      for (var fileIndex = 0; fileIndex < files.length; fileIndex++) {
        final file = files[fileIndex];
        final currentPrefetch = prefetchedFile?.file == file
            ? prefetchedFile
            : null;
        if (currentPrefetch != null) prefetchedFile = null;
        if (_abortRequested) return _pause();
        if (file.isFolder) {
          await Directory(_targetPath(file.file)).create(recursive: true);
          continue;
        }
        final fileCompressedSize = file.chunks.fold<int>(
          0,
          (sum, c) => sum + c.compressedSize,
        );
        final progressBase = _receivedBytes;
        _beginVerifying();
        if (await _isFinalFileValid(file, progressSize: fileCompressedSize)) {
          await _discardPrefetch(currentPrefetch);
          _receivedBytes += fileCompressedSize;
          notifyListeners();
          continue;
        }
        if (_usesFastCacheAssembly &&
            await _verifyAssembledFile(
              file,
              progressSize: fileCompressedSize,
            )) {
          // Already assembled and verified in the cache by a previous run;
          // only the copy to the final (possibly slow, e.g. USB) destination
          // failed or was interrupted, so resume from there without
          // redownloading or reassembling anything.
          await _discardPrefetch(currentPrefetch);
          _receivedBytes = progressBase + fileCompressedSize;
          notifyListeners();
          if (prefetchNextFileDuringVerification) {
            prefetchedFile ??= _startNextFilePrefetch(files, fileIndex + 1);
          }
          await _publishAssembledFile(file, progressSize: fileCompressedSize);
          if (_abortRequested) return _pause();
          await _deleteChunkCache(
            file,
            retainChunkIds: _prefetchedChunkIds(prefetchedFile),
          );
          _finishPublishing(fileCompressedSize);
          continue;
        }
        _receivedBytes = progressBase;
        _setStatus(DownloadStatus.downloading);
        await _assembleFile(file, prefetch: currentPrefetch);
        if (_abortRequested) return _pause();
        _beginVerifying();
        if (prefetchNextFileDuringVerification && _usesFastCacheAssembly) {
          prefetchedFile ??= _startNextFilePrefetch(files, fileIndex + 1);
        }
        if (!await _verifyAssembledFile(
          file,
          progressSize: fileCompressedSize,
        )) {
          // Reassemble once from cached, independently verified chunks. This
          // handles a transient write failure without network redownload.
          final assemblyTarget = File(_assemblyTargetPath(file));
          await _clearAssemblyVerifiedMarker(file);
          if (await assemblyTarget.exists()) await assemblyTarget.delete();
          _receivedBytes = progressBase;
          _setStatus(DownloadStatus.downloading);
          await _assembleFile(file, countProgress: false);
          _beginVerifying();
          if (prefetchNextFileDuringVerification && _usesFastCacheAssembly) {
            prefetchedFile ??= _startNextFilePrefetch(files, fileIndex + 1);
          }
          if (!await _verifyAssembledFile(
            file,
            progressSize: fileCompressedSize,
          )) {
            _fail('文件校验失败：${file.file}');
            return false;
          }
          _receivedBytes = progressBase + fileCompressedSize;
          notifyListeners();
        }
        if (_usesFastCacheAssembly) {
          await _publishAssembledFile(file, progressSize: fileCompressedSize);
          if (_abortRequested) return _pause();
        }
        await _deleteChunkCache(
          file,
          retainChunkIds: _prefetchedChunkIds(prefetchedFile),
        );
        if (_usesFastCacheAssembly) {
          _finishPublishing(fileCompressedSize);
        }
      }
      _setStatus(DownloadStatus.completed);
      return true;
    } on _SophonPausedException {
      return _pause();
    } catch (e) {
      if (_abortRequested) return _pause();
      _fail(e.toString());
      return false;
    } finally {
      _stopSpeedTimer();
      _client?.close();
      _client = null;
      await _discardPrefetch(prefetchedFile);
      _speed = 0;
    }
  }

  Future<SophonChunkManifest> _loadManifest() async {
    if (_manifest != null) return _manifest!;
    if (initialManifest != null) {
      _manifest = initialManifest;
      return _manifest!;
    }
    final client = _client ?? http.Client();
    final response = await client.get(Uri.parse(meta.manifestUrl));
    if (response.statusCode != 200 && response.statusCode != 206) {
      throw HttpException(
        'HTTP ${response.statusCode}',
        uri: Uri.parse(meta.manifestUrl),
      );
    }
    final decompressed = await zstdCodec.decompress(
      Uint8List.fromList(response.bodyBytes),
    );
    if (decompressed == null) {
      throw const FormatException('Can not decompress Sophon manifest.');
    }
    final checksum = hex.encode(md5.convert(decompressed).bytes);
    if (meta.manifestChecksum.isNotEmpty && checksum != meta.manifestChecksum) {
      throw FormatException(
        'Sophon manifest checksum mismatch: $checksum != ${meta.manifestChecksum}',
      );
    }
    _manifest = SophonChunkManifest.fromProtoBytes(decompressed);
    return _manifest!;
  }

  Future<void> _assembleFile(
    SophonFile file, {
    bool countProgress = true,
    _SophonFileCachePrefetch? prefetch,
  }) async {
    final target = File(_assemblyTargetPath(file));
    await _clearAssemblyVerifiedMarker(file);
    await target.parent.create(recursive: true);
    final raf = await target.open(mode: FileMode.write);
    final queue = _SophonAssemblyPrefetch(file, prefetch);

    try {
      await raf.truncate(file.size);
      _prefetchAssemblyMore(queue);
      for (var index = 0; index < file.chunks.length; index++) {
        if (_abortRequested) throw const _SophonPausedException();
        final prepared = await queue.pending.remove(index)!;
        _prefetchAssemblyMore(queue);
        if (_abortRequested) throw const _SophonPausedException();
        await raf.setPosition(prepared.chunk.offset);
        await raf.writeFrom(prepared.decompressed);
        if (countProgress) {
          _receivedBytes += prepared.chunk.compressedSize;
          notifyListeners();
        }
      }
    } finally {
      await _discardAssemblyPrefetch(queue);
      await _discardPrefetch(prefetch);
      await raf.close();
    }
  }

  _SophonFileCachePrefetch? _startNextFilePrefetch(
    List<SophonFile> files,
    int startIndex,
  ) {
    for (var i = startIndex; i < files.length; i++) {
      final file = files[i];
      if (file.isFolder || file.chunks.isEmpty) continue;
      final queue = _SophonFileCachePrefetch(file);
      _prefetchFileCacheMore(queue);
      return queue;
    }
    return null;
  }

  void _prefetchFileCacheMore(_SophonFileCachePrefetch queue) {
    while (!_abortRequested &&
        !queue.stopped &&
        queue.nextPrefetchIndex < queue.file.chunks.length &&
        queue.pending.length < _maxChunkPrefetch) {
      final index = queue.nextPrefetchIndex++;
      final future = _cacheChunkForPrefetch(queue.file.chunks[index]);
      queue.pending[index] = future;
      unawaited(
        future.then<void>(
          (_) => _completeFileCachePrefetch(queue, index, future),
          onError: (_) => _completeFileCachePrefetch(queue, index, future),
        ),
      );
    }
  }

  void _completeFileCachePrefetch(
    _SophonFileCachePrefetch queue,
    int index,
    Future<void> future,
  ) {
    if (identical(queue.pending[index], future)) {
      queue.pending.remove(index);
    }
    _prefetchFileCacheMore(queue);
  }

  Future<void> _cacheChunkForPrefetch(SophonChunk chunk) async {
    await _getVerifiedCompressedChunk(chunk, forceCache: true);
  }

  void _prefetchAssemblyMore(_SophonAssemblyPrefetch queue) {
    while (!_abortRequested &&
        queue.nextPrefetchIndex < queue.file.chunks.length &&
        queue.pending.length < _maxChunkPrefetch) {
      final index = queue.nextPrefetchIndex++;
      final future = _prepareChunkAfterCachePrefetch(
        queue.file.chunks[index],
        queue.cachePrefetch,
        index,
      );
      unawaited(future.then<void>((_) {}, onError: (_) {}));
      queue.pending[index] = future;
    }
  }

  Future<_PreparedSophonChunk> _prepareChunkAfterCachePrefetch(
    SophonChunk chunk,
    _SophonFileCachePrefetch? prefetch,
    int index,
  ) async {
    final activePrefetch = prefetch?.pending[index];
    if (activePrefetch != null) {
      try {
        await activePrefetch;
      } catch (_) {
        // The normal preparation path below retains its own retry behavior.
      }
    }
    return _prepareChunk(chunk);
  }

  Future<void> _discardAssemblyPrefetch(_SophonAssemblyPrefetch queue) async {
    await Future.wait(
      queue.pending.values.toList().map(
        (future) => future.then<void>((_) {}, onError: (_) {}),
      ),
    );
    queue.pending.clear();
  }

  Future<void> _discardPrefetch(_SophonFileCachePrefetch? queue) async {
    if (queue == null) return;
    queue.stopped = true;
    await Future.wait(
      queue.pending.values.toList().map(
        (future) => future.then<void>((_) {}, onError: (_) {}),
      ),
    );
    queue.pending.clear();
  }

  Future<_PreparedSophonChunk> _prepareChunk(SophonChunk chunk) async {
    final compressed = await _getVerifiedCompressedChunk(chunk);
    final decompressed = await zstdCodec.decompress(compressed);
    if (decompressed == null) {
      await _deleteChunk(chunk);
      throw FormatException('Can not decompress chunk ${chunk.id}');
    }
    if (decompressed.length != chunk.uncompressedSize ||
        _md5Hex(decompressed) != chunk.uncompressedMd5) {
      await _deleteChunk(chunk);
      throw FormatException('Chunk MD5 mismatch: ${chunk.id}');
    }
    return _PreparedSophonChunk(chunk, decompressed);
  }

  Future<Uint8List> _getVerifiedCompressedChunk(
    SophonChunk chunk, {
    bool forceCache = false,
  }) async {
    final cache = File(_chunkPath(chunk));
    if (await cache.exists() && await cache.length() == chunk.compressedSize) {
      final bytes = await cache.readAsBytes();
      if (_md5Hex(bytes) == chunk.compressedMd5) return bytes;
      await cache.delete();
    }
    return _downloadVerifiedCompressedChunk(
      chunk,
      cache,
      forceCache: forceCache,
    );
  }

  Future<Uint8List> _downloadVerifiedCompressedChunk(
    SophonChunk chunk,
    File cache, {
    bool forceCache = false,
  }) async {
    Object? lastError;
    for (var attempt = 1; attempt <= _chunkDownloadAttempts; attempt++) {
      if (_abortRequested) throw const _SophonPausedException();
      try {
        final bytes = forceCache || _shouldCacheChunk(chunk)
            ? await _downloadChunkToCache(chunk, cache)
            : await _downloadChunkToMemory(chunk);
        if (bytes.length != chunk.compressedSize ||
            _md5Hex(bytes) != chunk.compressedMd5) {
          await _deleteChunk(chunk);
          throw FormatException('Compressed chunk MD5 mismatch: ${chunk.id}');
        }
        return bytes;
      } catch (e) {
        if (_abortRequested) throw const _SophonPausedException();
        lastError = e;
        await _deleteChunk(chunk);
        if (attempt < _chunkDownloadAttempts) {
          await Future<void>.delayed(Duration(milliseconds: 300 * attempt));
        }
      }
    }
    throw lastError ?? FormatException('Can not download chunk ${chunk.id}');
  }

  Future<Uint8List> _downloadChunkToMemory(SophonChunk chunk) async {
    final builder = BytesBuilder(copy: false);
    await _downloadChunkStream(chunk, (part) {
      builder.add(part);
    });
    return builder.takeBytes();
  }

  Future<Uint8List> _downloadChunkToCache(SophonChunk chunk, File cache) async {
    await cache.parent.create(recursive: true);
    final tmp = File('${cache.path}_tmp');
    final sink = tmp.openWrite(mode: FileMode.write);
    try {
      await _downloadChunkStream(chunk, sink.add);
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (_abortRequested) throw const _SophonPausedException();
    final bytes = await tmp.readAsBytes();
    await tmp.rename(cache.path);
    return bytes;
  }

  Future<void> _downloadChunkStream(
    SophonChunk chunk,
    void Function(List<int> part) onPart,
  ) async {
    final request = http.Request('GET', Uri.parse(meta.chunkUrl(chunk.id)));
    final response = await (_client ?? http.Client())
        .send(request)
        .timeout(_chunkRequestTimeout);
    if (response.statusCode != 200) {
      throw HttpException(
        'HTTP ${response.statusCode}',
        uri: Uri.parse(meta.chunkUrl(chunk.id)),
      );
    }
    await for (final part in response.stream.timeout(_chunkPartTimeout)) {
      if (_abortRequested) break;
      if (rateLimiter != null) await rateLimiter!.acquire(part.length);
      if (_abortRequested) break;
      _networkBytes += part.length;
      onPart(part);
    }
    if (_abortRequested) throw const _SophonPausedException();
  }

  Future<bool> _isFinalFileValid(SophonFile file, {int? progressSize}) async {
    final target = File(_targetPath(file.file));
    if (!await target.exists()) {
      await _clearFinalVerifiedMarker(file);
      return false;
    }
    if (await target.length() != file.size) {
      await _clearFinalVerifiedMarker(file);
      return false;
    }
    if (await _hasValidatedFinalFile(file, target)) {
      _setVerifyProgress(progressSize, file.size, file.size);
      return true;
    }
    if (file.md5.isEmpty) {
      _setVerifyProgress(progressSize, file.size, file.size);
      await _markValidatedFinalFile(file, target);
      return true;
    }
    final hash = await _fileMd5(target, progressSize: progressSize);
    if (hash == file.md5) {
      await _markValidatedFinalFile(file, target);
      return true;
    }
    await _clearFinalVerifiedMarker(file);
    return false;
  }

  Future<bool> _hasValidatedFinalFile(SophonFile file, File target) async {
    return VerifiedFileIndex.isVerified(
      root: _finalVerifiedIndexRoot(file),
      key: _finalVerifiedIndexKey(file),
      file: target,
      size: file.size,
      md5: file.md5,
      context: {
        'type': 'sophon',
        'version': version,
        'categoryId': meta.categoryId,
      },
    );
  }

  Future<void> _markValidatedFinalFile(SophonFile file, File target) async {
    await VerifiedFileIndex.markVerified(
      root: _finalVerifiedIndexRoot(file),
      key: _finalVerifiedIndexKey(file),
      file: target,
      size: file.size,
      md5: file.md5,
      context: {
        'type': 'sophon',
        'version': version,
        'categoryId': meta.categoryId,
      },
    );
    await _deleteLegacyFinalVerifiedMarker(file);
  }

  Future<void> _clearFinalVerifiedMarker(SophonFile file) async {
    await VerifiedFileIndex.remove(
      _finalVerifiedIndexRoot(file),
      _finalVerifiedIndexKey(file),
    );
    await _deleteLegacyFinalVerifiedMarker(file);
  }

  String _finalVerifiedIndexRoot(SophonFile file) {
    final parts = _safeRelativePath(file.file).split(Platform.pathSeparator);
    if (parts.length <= 1) return saveDir;
    return '$saveDir${Platform.pathSeparator}${parts.first}';
  }

  String _finalVerifiedIndexKey(SophonFile file) {
    final parts = _safeRelativePath(file.file).split(Platform.pathSeparator);
    if (parts.length <= 1) return parts.first;
    return parts.skip(1).join(Platform.pathSeparator);
  }

  Future<void> _deleteLegacyFinalVerifiedMarker(SophonFile file) async {
    final marker = File('${_targetPath(file.file)}.verified');
    if (await marker.exists()) await marker.delete();
  }

  /// Verifies whichever path the current assembly target is: the final
  /// destination when no independent fast cache is configured (unchanged
  /// behavior), or the cache copy when [_usesFastCacheAssembly] is true.
  Future<bool> _verifyAssembledFile(
    SophonFile file, {
    int? progressSize,
  }) async {
    if (!_usesFastCacheAssembly) {
      return _isFinalFileValid(file, progressSize: progressSize);
    }
    final cacheFile = File(_cachedAssemblyPath(file));
    if (!await cacheFile.exists() || await cacheFile.length() != file.size) {
      await _clearCacheVerifiedMarker(file);
      return false;
    }
    if (await _hasValidatedCacheAssembly(file, cacheFile)) {
      _setVerifyProgress(progressSize, file.size, file.size);
      return true;
    }
    if (file.md5.isEmpty) {
      _setVerifyProgress(progressSize, file.size, file.size);
      await _markValidatedCacheAssembly(file, cacheFile);
      return true;
    }
    final hash = await _fileMd5(cacheFile, progressSize: progressSize);
    if (hash == file.md5) {
      await _markValidatedCacheAssembly(file, cacheFile);
      return true;
    }
    await _clearCacheVerifiedMarker(file);
    return false;
  }

  Future<void> _clearAssemblyVerifiedMarker(SophonFile file) async {
    if (_usesFastCacheAssembly) {
      await _clearCacheVerifiedMarker(file);
    } else {
      await _clearFinalVerifiedMarker(file);
    }
  }

  String get _cacheAssemblyIndexRoot => '$cacheDir/assembled';

  String _cacheAssemblyIndexKey(SophonFile file) =>
      _safeRelativePath(file.file);

  Future<bool> _hasValidatedCacheAssembly(SophonFile file, File cacheFile) {
    return VerifiedFileIndex.isVerified(
      root: _cacheAssemblyIndexRoot,
      key: _cacheAssemblyIndexKey(file),
      file: cacheFile,
      size: file.size,
      md5: file.md5,
      context: {
        'type': 'sophon-cache',
        'version': version,
        'categoryId': meta.categoryId,
      },
    );
  }

  Future<void> _markValidatedCacheAssembly(SophonFile file, File cacheFile) {
    return VerifiedFileIndex.markVerified(
      root: _cacheAssemblyIndexRoot,
      key: _cacheAssemblyIndexKey(file),
      file: cacheFile,
      size: file.size,
      md5: file.md5,
      context: {
        'type': 'sophon-cache',
        'version': version,
        'categoryId': meta.categoryId,
      },
    );
  }

  Future<void> _clearCacheVerifiedMarker(SophonFile file) {
    return VerifiedFileIndex.remove(
      _cacheAssemblyIndexRoot,
      _cacheAssemblyIndexKey(file),
    );
  }

  /// Copies the already-verified cache-assembled file to the final
  /// (possibly slow, e.g. USB) destination with explicit backpressure, then
  /// trusts that verified copy instead of re-hashing the final file again.
  Future<void> _publishAssembledFile(
    SophonFile file, {
    int? progressSize,
  }) async {
    final cacheFile = File(_cachedAssemblyPath(file));
    final finalFile = File(_targetPath(file.file));
    await finalFile.parent.create(recursive: true);
    await _clearFinalVerifiedMarker(file);
    _beginPublishing();
    final source = await cacheFile.open(mode: FileMode.read);
    final target = await finalFile.open(mode: FileMode.write);
    var processed = 0;
    final total = file.size;
    try {
      await target.truncate(0);
      while (true) {
        if (_abortRequested) throw const _SophonPausedException();
        final chunk = await source.read(_publishCopyChunkSize);
        if (chunk.isEmpty) break;
        await target.writeFrom(chunk);
        processed += chunk.length;
        _setPublishProgress(progressSize, processed, total);
      }
      _isPublishingFinalizing = true;
      notifyListeners();
      await target.flush();
    } finally {
      await source.close();
      await target.close();
    }
    if (_abortRequested) throw const _SophonPausedException();
    await _markValidatedFinalFile(file, finalFile);
    await _clearCacheVerifiedMarker(file);
    if (await cacheFile.exists()) await cacheFile.delete();
  }

  Set<String> _prefetchedChunkIds(_SophonFileCachePrefetch? prefetch) {
    if (prefetch == null) return const <String>{};
    return prefetch.file.chunks.map((chunk) => chunk.id).toSet();
  }

  Future<void> _deleteChunkCache(
    SophonFile file, {
    Set<String> retainChunkIds = const <String>{},
  }) async {
    for (final chunk in file.chunks) {
      if (!retainChunkIds.contains(chunk.id)) await _deleteChunk(chunk);
    }
  }

  Future<void> _deleteChunk(SophonChunk chunk) async {
    final cache = File(_chunkPath(chunk));
    if (await cache.exists()) await cache.delete();
    final tmp = File('${cache.path}_tmp');
    if (await tmp.exists()) await tmp.delete();
  }

  String _targetPath(String file) {
    return '$saveDir${Platform.pathSeparator}${_safeRelativePath(file)}';
  }

  /// The path an in-progress file is being written to: the cache copy when
  /// [_usesFastCacheAssembly] is enabled, otherwise the final destination.
  String _assemblyTargetPath(SophonFile file) => _usesFastCacheAssembly
      ? _cachedAssemblyPath(file)
      : _targetPath(file.file);

  String _cachedAssemblyPath(SophonFile file) =>
      '$cacheDir/assembled/${_safeRelativePath(file.file)}';

  String _safeRelativePath(String file) {
    return file
        .replaceAll('\\', '/')
        .split('/')
        .where((p) => p.isNotEmpty && p != '..')
        .join(Platform.pathSeparator);
  }

  String _chunkPath(SophonChunk chunk) => '$cacheDir/${chunk.id}';

  String _normalizedDirectoryPath(String path) {
    var normalized = path.replaceAll('\\', '/');
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  bool _shouldCacheChunk(SophonChunk chunk) {
    return chunk.compressedSize >= _chunkCacheThreshold;
  }

  void _startSpeedTimer() {
    _lastNetworkBytes = _networkBytes;
    _speedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _speed = (_networkBytes - _lastNetworkBytes).toDouble();
      _lastNetworkBytes = _networkBytes;
      notifyListeners();
    });
  }

  void _stopSpeedTimer() {
    _speedTimer?.cancel();
    _speedTimer = null;
  }

  bool _pause() {
    _setStatus(DownloadStatus.paused);
    return false;
  }

  @override
  void pause() {
    if (!isActive) return;
    _abortRequested = true;
    _client?.close();
    _client = null;
  }

  @override
  Future<void> cancel() async {
    _abortRequested = true;
    _client?.close();
    _client = null;
    _setStatus(DownloadStatus.canceled);
    _receivedBytes = 0;
    _verificationBytes = 0;
    _verificationTotalBytes = 0;
    _publishingBytes = 0;
    _publishingTotalBytes = 0;
    _isPublishingFinalizing = false;
    notifyListeners();
  }

  @override
  void reset() {
    if (isActive) return;
    _error = null;
    _verificationBytes = 0;
    _verificationTotalBytes = 0;
    _publishingBytes = 0;
    _publishingTotalBytes = 0;
    _setStatus(DownloadStatus.queued);
  }

  @override
  void restoreState(DownloadStatus status, int receivedBytes) {
    _status = status;
    _receivedBytes = receivedBytes;
  }

  @override
  Map<String, dynamic> toPersistedJson() => {
    'type': 'sophon',
    'saveDir': saveDir,
    'version': version,
    'groupName': groupName,
    if (chunkCacheDir != null && chunkCacheDir!.isNotEmpty)
      'chunkCacheDir': chunkCacheDir,
    'meta': meta.toJson(),
    'status': status == DownloadStatus.completed ? 'completed' : 'paused',
  };

  void _setStatus(DownloadStatus value) {
    _status = value;
    if (value != DownloadStatus.publishing) {
      _isPublishingFinalizing = false;
    }
    notifyListeners();
  }

  void _fail(String message) {
    _error = message;
    _setStatus(DownloadStatus.failed);
  }

  void _beginVerifying() {
    _verificationBytes = 0;
    _verificationTotalBytes = 0;
    _setStatus(DownloadStatus.verifying);
  }

  void _setVerifyProgress(int? progressSize, int processed, int total) {
    if (progressSize == null || total <= 0) return;
    _verificationTotalBytes = progressSize;
    final phaseBytes = (processed / total * progressSize).round();
    _verificationBytes = phaseBytes.clamp(0, totalSize).toInt();
    notifyListeners();
  }

  void _beginPublishing() {
    _publishingBytes = 0;
    _publishingTotalBytes = 0;
    _isPublishingFinalizing = false;
    _setStatus(DownloadStatus.publishing);
  }

  void _finishPublishing(int progressSize) {
    _publishingTotalBytes = progressSize;
    _publishingBytes = progressSize;
    _isPublishingFinalizing = false;
    notifyListeners();
  }

  void _setPublishProgress(int? progressSize, int processed, int total) {
    if (progressSize == null || total <= 0) return;
    _publishingTotalBytes = progressSize;
    final phaseBytes = (processed / total * progressSize).round();
    final progressLimit = progressSize > 0 ? progressSize - 1 : 0;
    _publishingBytes = phaseBytes.clamp(0, progressLimit).toInt();
    notifyListeners();
  }

  Future<String> _fileMd5(File file, {int? progressSize}) async {
    final output = AccumulatorSink<Digest>();
    final input = md5.startChunkedConversion(output);
    final total = await file.length();
    var verified = 0;
    var lastNotified = 0;
    await for (final chunk in file.openRead()) {
      if (_abortRequested) throw const _SophonPausedException();
      input.add(chunk);
      verified += chunk.length;
      if (verified - lastNotified >= 512 * 1024 || verified >= total) {
        _setVerifyProgress(progressSize, verified, total);
        lastNotified = verified;
      }
    }
    input.close();
    _setVerifyProgress(progressSize, total, total);
    return hex.encode(output.events.single.bytes);
  }
}

class _SophonPausedException implements Exception {
  const _SophonPausedException();
}

class _SophonFileCachePrefetch {
  _SophonFileCachePrefetch(this.file);

  final SophonFile file;
  final Map<int, Future<void>> pending = {};
  var nextPrefetchIndex = 0;
  var stopped = false;
}

class _SophonAssemblyPrefetch {
  _SophonAssemblyPrefetch(this.file, this.cachePrefetch);

  final SophonFile file;
  final _SophonFileCachePrefetch? cachePrefetch;
  final Map<int, Future<_PreparedSophonChunk>> pending = {};
  var nextPrefetchIndex = 0;
}

class _PreparedSophonChunk {
  const _PreparedSophonChunk(this.chunk, this.decompressed);

  final SophonChunk chunk;
  final Uint8List decompressed;
}

String _md5Hex(Uint8List bytes) => hex.encode(md5.convert(bytes).bytes);
