import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../models/sophon_models.dart';
import 'download_job.dart';
import 'rate_limiter.dart';
import 'zstd_codec.dart';

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
    this.rateLimiter,
    this.zstdCodec = const ZstandardZstdCodec(),
  });

  final SophonManifestMeta meta;
  final String saveDir;
  final String version;
  final SophonChunkManifest? initialManifest;
  final RateLimiter? rateLimiter;
  final ZstdCodec zstdCodec;

  SophonChunkManifest? _manifest;
  http.Client? _client;
  bool _abortRequested = false;
  Timer? _speedTimer;
  int _lastBytes = 0;
  int _receivedBytes = 0;
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

  String get _cacheDir => '$saveDir/.sophon/chunks/${meta.categoryId}';

  @override
  Future<bool> run() async {
    if (_status == DownloadStatus.completed) return true;
    _abortRequested = false;
    _error = null;
    _receivedBytes = 0;
    _setStatus(DownloadStatus.downloading);
    _startSpeedTimer();
    _client = http.Client();
    try {
      final manifest = await _loadManifest();
      for (final file in manifest.files) {
        if (_abortRequested) return _pause();
        if (file.isFolder) {
          await Directory(_targetPath(file.file)).create(recursive: true);
          continue;
        }
        final fileCompressedSize =
            file.chunks.fold<int>(0, (sum, c) => sum + c.compressedSize);
        if (await _isFinalFileValid(file)) {
          _receivedBytes += fileCompressedSize;
          notifyListeners();
          continue;
        }
        await _assembleFile(file);
        if (_abortRequested) return _pause();
        if (!await _isFinalFileValid(file)) {
          // Reassemble once from cached, independently verified chunks. This
          // handles a transient write failure without network redownload.
          final target = File(_targetPath(file.file));
          if (await target.exists()) await target.delete();
          await _assembleFile(file, countProgress: false);
          if (!await _isFinalFileValid(file)) {
            _fail('文件校验失败：${file.file}');
            return false;
          }
        }
        await _deleteChunkCache(file);
      }
      _setStatus(DownloadStatus.completed);
      return true;
    } catch (e) {
      if (_abortRequested) return _pause();
      _fail(e.toString());
      return false;
    } finally {
      _stopSpeedTimer();
      _client?.close();
      _client = null;
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
      throw HttpException('HTTP ${response.statusCode}',
          uri: Uri.parse(meta.manifestUrl));
    }
    final decompressed = await zstdCodec.decompress(Uint8List.fromList(response.bodyBytes));
    if (decompressed == null) {
      throw const FormatException('Can not decompress Sophon manifest.');
    }
    final checksum = hex.encode(md5.convert(decompressed).bytes);
    if (meta.manifestChecksum.isNotEmpty && checksum != meta.manifestChecksum) {
      throw FormatException(
          'Sophon manifest checksum mismatch: $checksum != ${meta.manifestChecksum}');
    }
    _manifest = SophonChunkManifest.fromProtoBytes(decompressed);
    return _manifest!;
  }

  Future<void> _assembleFile(SophonFile file, {bool countProgress = true}) async {
    final target = File(_targetPath(file.file));
    await target.parent.create(recursive: true);
    final raf = await target.open(mode: FileMode.write);
    try {
      await raf.truncate(file.size);
      for (final chunk in file.chunks) {
        if (_abortRequested) return;
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
        await raf.setPosition(chunk.offset);
        await raf.writeFrom(decompressed);
        if (countProgress) {
          _receivedBytes += chunk.compressedSize;
          notifyListeners();
        }
      }
    } finally {
      await raf.close();
    }
  }

  Future<Uint8List> _getVerifiedCompressedChunk(SophonChunk chunk) async {
    final cache = File(_chunkPath(chunk));
    if (await cache.exists() && await cache.length() == chunk.compressedSize) {
      final bytes = await cache.readAsBytes();
      if (_md5Hex(bytes) == chunk.compressedMd5) return bytes;
      await cache.delete();
    }
    await cache.parent.create(recursive: true);
    final tmp = File('${cache.path}_tmp');
    final request = http.Request('GET', Uri.parse(meta.chunkUrl(chunk.id)));
    final response = await (_client ?? http.Client()).send(request);
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}',
          uri: Uri.parse(meta.chunkUrl(chunk.id)));
    }
    final sink = tmp.openWrite(mode: FileMode.write);
    try {
      await for (final part in response.stream) {
        if (_abortRequested) break;
        if (rateLimiter != null) await rateLimiter!.acquire(part.length);
        if (_abortRequested) break;
        sink.add(part);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (_abortRequested) throw const _SophonPausedException();
    final bytes = await tmp.readAsBytes();
    if (bytes.length != chunk.compressedSize ||
        _md5Hex(bytes) != chunk.compressedMd5) {
      await tmp.delete();
      throw FormatException('Compressed chunk MD5 mismatch: ${chunk.id}');
    }
    await tmp.rename(cache.path);
    return bytes;
  }

  Future<bool> _isFinalFileValid(SophonFile file) async {
    final target = File(_targetPath(file.file));
    if (!await target.exists()) return false;
    if (await target.length() != file.size) return false;
    if (file.md5.isEmpty) return true;
    final hash = await _fileMd5(target);
    return hash == file.md5;
  }

  Future<void> _deleteChunkCache(SophonFile file) async {
    for (final chunk in file.chunks) {
      await _deleteChunk(chunk);
    }
  }

  Future<void> _deleteChunk(SophonChunk chunk) async {
    final cache = File(_chunkPath(chunk));
    if (await cache.exists()) await cache.delete();
    final tmp = File('${cache.path}_tmp');
    if (await tmp.exists()) await tmp.delete();
  }

  String _targetPath(String file) {
    final safe = file
        .replaceAll('\\', '/')
        .split('/')
        .where((p) => p.isNotEmpty && p != '..')
        .join(Platform.pathSeparator);
    return '$saveDir${Platform.pathSeparator}$safe';
  }

  String _chunkPath(SophonChunk chunk) => '$_cacheDir/${chunk.id}';

  void _startSpeedTimer() {
    _lastBytes = _receivedBytes;
    _speedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _speed = (_receivedBytes - _lastBytes).toDouble();
      _lastBytes = _receivedBytes;
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
    notifyListeners();
  }

  @override
  void reset() {
    if (isActive) return;
    _error = null;
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
        'meta': meta.toJson(),
        'status': status == DownloadStatus.completed ? 'completed' : 'paused',
      };

  void _setStatus(DownloadStatus value) {
    _status = value;
    notifyListeners();
  }

  void _fail(String message) {
    _error = message;
    _setStatus(DownloadStatus.failed);
  }
}

class _SophonPausedException implements Exception {
  const _SophonPausedException();
}

String _md5Hex(Uint8List bytes) => hex.encode(md5.convert(bytes).bytes);

Future<String> _fileMd5(File file) async {
  final output = AccumulatorSink<Digest>();
  final input = md5.startChunkedConversion(output);
  await for (final chunk in file.openRead()) {
    input.add(chunk);
  }
  input.close();
  return hex.encode(output.events.single.bytes);
}
