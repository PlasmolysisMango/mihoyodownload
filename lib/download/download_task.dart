import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'download_job.dart';
import 'rate_limiter.dart';
import 'verified_file_index.dart';

const _publishCopyChunkSize = 4 * 1024 * 1024;

/// Downloads one file with HTTP range resume and streaming MD5 verification.
///
/// Ported from Starward's `GameInstallHelper.DownloadToFileAsync`:
/// data is written to `<file>_tmp`; on resume the existing tmp length is sent
/// as the `Range` start; after the full length arrives the tmp file is hashed
/// and renamed to the final name only when the MD5 matches.
class DownloadTask extends DownloadJob {
  DownloadTask({
    required this.url,
    required this.savePath,
    required this.totalSize,
    required this.expectedMd5,
    required this.displayName,
    this.groupName = '',
    this.cacheDir,
    this.rateLimiter,
  });

  final String url;

  /// Final path of the completed file.
  @override
  final String savePath;
  @override
  final int totalSize;

  /// Lowercase hex MD5; empty string skips verification.
  final String expectedMd5;
  @override
  final String displayName;

  /// Which game/version this file belongs to, for UI grouping.
  @override
  final String groupName;

  /// Optional high-speed cache root for the resumable tmp file.
  final String? cacheDir;

  /// Shared limiter throttling the aggregate download speed; null = unlimited.
  final RateLimiter? rateLimiter;

  DownloadStatus _status = DownloadStatus.queued;
  @override
  DownloadStatus get status => _status;

  int _receivedBytes = 0;
  @override
  int get receivedBytes => _receivedBytes;

  int _verificationBytes = 0;
  @override
  int get verificationBytes => _verificationBytes;

  @override
  double get verificationProgress =>
      totalSize <= 0 ? 0 : _verificationBytes / totalSize;

  int _publishingBytes = 0;
  @override
  int get publishingBytes => _publishingBytes;

  @override
  double get publishingProgress =>
      totalSize <= 0 ? 0 : _publishingBytes / totalSize;

  @override
  double get progress => totalSize <= 0 ? 0 : _receivedBytes / totalSize;

  /// Bytes per second, updated once per second while downloading.
  double _speed = 0;
  @override
  double get speed => _speed;

  String? _error;
  @override
  String? get error => _error;

  http.Client? _client;
  bool _abortRequested = false;

  String get tmpPath {
    final root = cacheDir;
    if (root == null || root.isEmpty) return '${savePath}_tmp';
    final key = hex.encode(md5.convert(savePath.codeUnits).bytes);
    final name = _fileName(savePath);
    return '$root/$key-$name.tmp';
  }

  /// Sidecar marker written only after the cache tmp file passed verification.
  String? get validatedCacheMarkerPath {
    final root = cacheDir;
    if (root == null || root.isEmpty) return null;
    return '$tmpPath.verified';
  }

  /// Directory-level index entry written after the final file passed verification.
  String get finalVerifiedIndexRoot => File(savePath).parent.path;
  String get finalVerifiedIndexKey => _fileName(savePath);

  String get _tmpPath => tmpPath;

  @override
  bool get isActive =>
      _status == DownloadStatus.downloading ||
      _status == DownloadStatus.verifying ||
      _status == DownloadStatus.publishing;

  /// Runs the download until completion, pause or failure.
  /// Returns true when the file is completed and verified.
  @override
  Future<bool> run() async {
    if (_status == DownloadStatus.completed) return true;
    _abortRequested = false;
    _error = null;
    _verificationBytes = 0;
    _publishingBytes = 0;
    _setStatus(DownloadStatus.downloading);
    try {
      final finalFile = File(savePath);
      if (await finalFile.exists()) {
        // Already downloaded before (e.g. app restart); reuse the previous
        // successful verification only when the final file metadata still
        // matches, otherwise verify the content again.
        if (await finalFile.length() == totalSize) {
          _receivedBytes = totalSize;
          _beginVerifying();
          if (await _hasValidatedFinalFile(finalFile)) {
            _verificationBytes = totalSize;
            notifyListeners();
            _setStatus(DownloadStatus.completed);
            return true;
          }
          if (await _verifyMd5(finalFile)) {
            await _markValidatedFinalFile(finalFile);
            _setStatus(DownloadStatus.completed);
            return true;
          }
        }
        await _clearValidatedFinalFileMarker();
        await finalFile.delete();
      }

      final tmpFile = File(_tmpPath);
      await tmpFile.parent.create(recursive: true);
      int start = await tmpFile.exists() ? await tmpFile.length() : 0;
      if (start > totalSize) {
        // Corrupted tmp file, restart from scratch.
        await _clearValidatedCacheMarker();
        await tmpFile.delete();
        start = 0;
      }
      _receivedBytes = start;

      if (await _hasValidatedCache(tmpFile)) {
        _receivedBytes = totalSize;
        _beginVerifying();
        _verificationBytes = totalSize;
        notifyListeners();
        await _publishCompletedFile(tmpFile);
        await _markValidatedFinalFile(File(savePath));
        _setStatus(DownloadStatus.completed);
        return true;
      }

      if (start < totalSize) {
        await _clearValidatedCacheMarker();
        await _downloadRange(tmpFile, start);
        if (_abortRequested) {
          _setStatus(DownloadStatus.paused);
          return false;
        }
      }

      _beginVerifying();
      if (await _verifyMd5(tmpFile)) {
        await _markValidatedCache();
        await _publishCompletedFile(tmpFile);
        await _markValidatedFinalFile(File(savePath));
        _setStatus(DownloadStatus.completed);
        return true;
      } else {
        // Drop the corrupted tmp so the next attempt restarts from byte 0.
        await _clearValidatedCacheMarker();
        await tmpFile.delete();
        _receivedBytes = 0;
        if (!_abortRequested) {
          // One automatic clean retry fixes the common case where an old tmp
          // file was corrupted or the CDN returned bad range data.
          return await _runFreshAfterMd5Mismatch();
        }
        _fail('MD5 校验失败，文件已删除，请重试');
        return false;
      }
    } catch (e) {
      if (_abortRequested) {
        _setStatus(DownloadStatus.paused);
      } else {
        _fail(e.toString());
      }
      return false;
    } finally {
      _speed = 0;
      _client?.close();
      _client = null;
    }
  }

  Future<void> _downloadRange(File tmpFile, int start) async {
    final client = http.Client();
    _client = client;
    final request = http.Request('GET', Uri.parse(url));
    if (start > 0) {
      request.headers['Range'] = 'bytes=$start-';
    }
    final response = await client.send(request);
    if (response.statusCode != 200 && response.statusCode != 206) {
      throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
    }
    // Server ignored the range header: restart from zero.
    final resumed = response.statusCode == 206;
    if (!resumed && start > 0) {
      _receivedBytes = 0;
    }

    final sink = tmpFile.openWrite(
      mode: resumed ? FileMode.append : FileMode.write,
    );
    int lastBytes = _receivedBytes;
    final speedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _speed = (_receivedBytes - lastBytes).toDouble();
      lastBytes = _receivedBytes;
      notifyListeners();
    });
    try {
      await for (final chunk in response.stream) {
        if (_abortRequested) break;
        // Throttle before writing, like Starward's _rateLimiter.AcquireAsync.
        if (rateLimiter != null) {
          await rateLimiter!.acquire(chunk.length);
          if (_abortRequested) break;
        }
        sink.add(chunk);
        _receivedBytes += chunk.length;
      }
      await sink.flush();
    } finally {
      speedTimer.cancel();
      await sink.close();
    }
  }

  Future<bool> _runFreshAfterMd5Mismatch() async {
    try {
      _setStatus(DownloadStatus.downloading);
      final tmpFile = File(_tmpPath);
      await tmpFile.parent.create(recursive: true);
      await _clearValidatedCacheMarker();
      await _downloadRange(tmpFile, 0);
      if (_abortRequested) {
        _setStatus(DownloadStatus.paused);
        return false;
      }
      _beginVerifying();
      if (await _verifyMd5(tmpFile)) {
        await _markValidatedCache();
        await _publishCompletedFile(tmpFile);
        await _markValidatedFinalFile(File(savePath));
        _setStatus(DownloadStatus.completed);
        return true;
      }
      await _clearValidatedCacheMarker();
      await tmpFile.delete();
      _receivedBytes = 0;
      _fail('MD5 校验失败，已重试一次仍不匹配');
      return false;
    } catch (e) {
      if (_abortRequested) {
        _setStatus(DownloadStatus.paused);
      } else {
        _fail(e.toString());
      }
      return false;
    }
  }

  Future<bool> _verifyMd5(File file) async {
    if (expectedMd5.isEmpty) {
      _verificationBytes = totalSize;
      notifyListeners();
      return true;
    }
    final output = AccumulatorSink<Digest>();
    final input = md5.startChunkedConversion(output);
    var verified = 0;
    var lastNotified = 0;
    await for (final chunk in file.openRead()) {
      if (_abortRequested) return false;
      input.add(chunk);
      verified += chunk.length;
      if (verified - lastNotified >= 512 * 1024 || verified >= totalSize) {
        _verificationBytes = verified.clamp(0, totalSize).toInt();
        lastNotified = verified;
        notifyListeners();
      }
    }
    input.close();
    _verificationBytes = totalSize;
    notifyListeners();
    return hex.encode(output.events.single.bytes) == expectedMd5;
  }

  Future<bool> _hasValidatedFinalFile(File file) async {
    return VerifiedFileIndex.isVerified(
      root: finalVerifiedIndexRoot,
      key: finalVerifiedIndexKey,
      file: file,
      size: totalSize,
      md5: expectedMd5,
      context: const {'type': 'package'},
    );
  }

  Future<void> _markValidatedFinalFile(File file) async {
    await VerifiedFileIndex.markVerified(
      root: finalVerifiedIndexRoot,
      key: finalVerifiedIndexKey,
      file: file,
      size: totalSize,
      md5: expectedMd5,
      context: const {'type': 'package'},
    );
    await _deleteLegacyFinalVerifiedMarker();
  }

  Future<void> _clearValidatedFinalFileMarker() async {
    await VerifiedFileIndex.remove(
      finalVerifiedIndexRoot,
      finalVerifiedIndexKey,
    );
    await _deleteLegacyFinalVerifiedMarker();
  }

  Future<void> _deleteLegacyFinalVerifiedMarker() async {
    final marker = File('$savePath.verified');
    if (await marker.exists()) await marker.delete();
  }

  Future<bool> _hasValidatedCache(File tmpFile) async {
    final markerPath = validatedCacheMarkerPath;
    if (markerPath == null) return false;
    if (!await tmpFile.exists() || await tmpFile.length() != totalSize) {
      return false;
    }
    final marker = File(markerPath);
    if (!await marker.exists()) return false;
    try {
      final data = jsonDecode(await marker.readAsString());
      if (data is! Map<String, dynamic>) return false;
      final stat = await tmpFile.stat();
      return data['savePath'] == savePath &&
          data['tmpPath'] == tmpPath &&
          data['totalSize'] == totalSize &&
          data['expectedMd5'] == expectedMd5 &&
          data['modifiedMillis'] == stat.modified.millisecondsSinceEpoch;
    } catch (_) {
      await _clearValidatedCacheMarker();
      return false;
    }
  }

  Future<void> _markValidatedCache() async {
    final markerPath = validatedCacheMarkerPath;
    if (markerPath == null) return;
    final marker = File(markerPath);
    final tmpStat = await File(_tmpPath).stat();
    await marker.parent.create(recursive: true);
    await marker.writeAsString(
      jsonEncode({
        'savePath': savePath,
        'tmpPath': tmpPath,
        'totalSize': totalSize,
        'expectedMd5': expectedMd5,
        'modifiedMillis': tmpStat.modified.millisecondsSinceEpoch,
      }),
    );
  }

  Future<void> _clearValidatedCacheMarker() async {
    final markerPath = validatedCacheMarkerPath;
    if (markerPath == null) return;
    final marker = File(markerPath);
    if (await marker.exists()) await marker.delete();
  }

  Future<void> _publishCompletedFile(File tmpFile) async {
    final finalFile = File(savePath);
    await finalFile.parent.create(recursive: true);
    _beginPublishing();
    if (cacheDir == null || cacheDir!.isEmpty) {
      await tmpFile.rename(savePath);
      _publishingBytes = totalSize;
      notifyListeners();
      return;
    }
    await _copyFileToFinalPath(tmpFile, finalFile);
    if (_abortRequested) throw const _PackagePausedException();
    await tmpFile.delete();
    await _clearValidatedCacheMarker();
  }

  Future<void> _copyFileToFinalPath(File tmpFile, File finalFile) async {
    final source = await tmpFile.open(mode: FileMode.read);
    final target = await finalFile.open(mode: FileMode.write);
    int lastBytes = _publishingBytes;
    final speedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _speed = (_publishingBytes - lastBytes).toDouble();
      lastBytes = _publishingBytes;
      notifyListeners();
    });
    try {
      await target.truncate(0);
      while (true) {
        if (_abortRequested) throw const _PackagePausedException();
        final chunk = await source.read(_publishCopyChunkSize);
        if (chunk.isEmpty) break;
        await target.writeFrom(chunk);
        _publishingBytes = (_publishingBytes + chunk.length)
            .clamp(0, totalSize)
            .toInt();
        notifyListeners();
      }
      await target.flush();
    } finally {
      speedTimer.cancel();
      await source.close();
      await target.close();
    }
  }

  String _fileName(String path) => path.replaceAll('\\', '/').split('/').last;

  /// Requests pause; the running loop stops at the next chunk.
  @override
  void pause() {
    if (_status != DownloadStatus.downloading &&
        _status != DownloadStatus.verifying &&
        _status != DownloadStatus.publishing) {
      return;
    }
    _abortRequested = true;
    // Force-abort a stalled connection.
    _client?.close();
    _client = null;
  }

  /// Cancels and deletes the partially downloaded tmp file.
  @override
  Future<void> cancel() async {
    _abortRequested = true;
    _client?.close();
    _client = null;
    _setStatus(DownloadStatus.canceled);
    _verificationBytes = 0;
    _publishingBytes = 0;
    try {
      final tmpFile = File(_tmpPath);
      if (await tmpFile.exists()) await tmpFile.delete();
      await _clearValidatedCacheMarker();
    } catch (_) {}
    _receivedBytes = 0;
    notifyListeners();
  }

  /// Marks a failed/paused/canceled task as queued again.
  @override
  void reset() {
    if (isActive) return;
    _error = null;
    _verificationBytes = 0;
    _publishingBytes = 0;
    _setStatus(DownloadStatus.queued);
  }

  /// Restores state loaded from persistence without notifying listeners;
  /// only used before the task is attached to the UI.
  @override
  void restoreState(DownloadStatus status, int receivedBytes) {
    _status = status;
    _receivedBytes = receivedBytes;
  }

  @override
  Map<String, dynamic> toPersistedJson() => {
    'type': 'package',
    'url': url,
    'savePath': savePath,
    'totalSize': totalSize,
    'expectedMd5': expectedMd5,
    'displayName': displayName,
    'groupName': groupName,
    'cacheDir': cacheDir,
    'status': status == DownloadStatus.completed ? 'completed' : 'paused',
  };

  void _beginVerifying() {
    _verificationBytes = 0;
    _setStatus(DownloadStatus.verifying);
  }

  void _beginPublishing() {
    _publishingBytes = 0;
    _setStatus(DownloadStatus.publishing);
  }

  void _setStatus(DownloadStatus value) {
    _status = value;
    notifyListeners();
  }

  void _fail(String message) {
    _error = message;
    _setStatus(DownloadStatus.failed);
  }
}

class _PackagePausedException implements Exception {
  const _PackagePausedException();
}
