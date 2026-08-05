import 'dart:async';
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'download_job.dart';
import 'rate_limiter.dart';

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

  String get _tmpPath => tmpPath;

  @override
  bool get isActive =>
      _status == DownloadStatus.downloading ||
      _status == DownloadStatus.verifying;

  /// Runs the download until completion, pause or failure.
  /// Returns true when the file is completed and verified.
  @override
  Future<bool> run() async {
    if (_status == DownloadStatus.completed) return true;
    _abortRequested = false;
    _error = null;
    _setStatus(DownloadStatus.downloading);
    try {
      final finalFile = File(savePath);
      if (await finalFile.exists()) {
        // Already downloaded before (e.g. app restart); verify it instead of
        // trusting the size only. A previously failed disk write or a stale
        // file can have the correct length but wrong content.
        if (await finalFile.length() == totalSize) {
          _receivedBytes = totalSize;
          _setStatus(DownloadStatus.verifying);
          if (await _verifyMd5(finalFile)) {
            _setStatus(DownloadStatus.completed);
            return true;
          }
        }
        await finalFile.delete();
      }

      final tmpFile = File(_tmpPath);
      await tmpFile.parent.create(recursive: true);
      int start = await tmpFile.exists() ? await tmpFile.length() : 0;
      if (start > totalSize) {
        // Corrupted tmp file, restart from scratch.
        await tmpFile.delete();
        start = 0;
      }
      _receivedBytes = start;

      if (start < totalSize) {
        await _downloadRange(tmpFile, start);
        if (_abortRequested) {
          _setStatus(DownloadStatus.paused);
          return false;
        }
      }

      _setStatus(DownloadStatus.verifying);
      if (await _verifyMd5(tmpFile)) {
        await _publishCompletedFile(tmpFile);
        _setStatus(DownloadStatus.completed);
        return true;
      } else {
        // Drop the corrupted tmp so the next attempt restarts from byte 0.
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
      await _downloadRange(tmpFile, 0);
      if (_abortRequested) {
        _setStatus(DownloadStatus.paused);
        return false;
      }
      _setStatus(DownloadStatus.verifying);
      if (await _verifyMd5(tmpFile)) {
        await _publishCompletedFile(tmpFile);
        _setStatus(DownloadStatus.completed);
        return true;
      }
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
    if (expectedMd5.isEmpty) return true;
    final output = AccumulatorSink<Digest>();
    final input = md5.startChunkedConversion(output);
    await for (final chunk in file.openRead()) {
      if (_abortRequested) return false;
      input.add(chunk);
    }
    input.close();
    return hex.encode(output.events.single.bytes) == expectedMd5;
  }

  Future<void> _publishCompletedFile(File tmpFile) async {
    final finalFile = File(savePath);
    await finalFile.parent.create(recursive: true);
    if (cacheDir == null || cacheDir!.isEmpty) {
      await tmpFile.rename(savePath);
      return;
    }
    await tmpFile.copy(savePath);
    await tmpFile.delete();
  }

  String _fileName(String path) => path.replaceAll('\\', '/').split('/').last;

  /// Requests pause; the running loop stops at the next chunk.
  @override
  void pause() {
    if (_status != DownloadStatus.downloading &&
        _status != DownloadStatus.verifying) {
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
    try {
      final tmpFile = File(_tmpPath);
      if (await tmpFile.exists()) await tmpFile.delete();
    } catch (_) {}
    _receivedBytes = 0;
    notifyListeners();
  }

  /// Marks a failed/paused/canceled task as queued again.
  @override
  void reset() {
    if (isActive) return;
    _error = null;
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

  void _setStatus(DownloadStatus value) {
    _status = value;
    notifyListeners();
  }

  void _fail(String message) {
    _error = message;
    _setStatus(DownloadStatus.failed);
  }
}
