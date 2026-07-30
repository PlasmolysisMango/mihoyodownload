import 'dart:async';
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Lifecycle states of a [DownloadTask].
enum DownloadStatus {
  queued,
  downloading,
  paused,
  verifying,
  completed,
  failed,
  canceled,
}

/// Downloads one file with HTTP range resume and streaming MD5 verification.
///
/// Ported from Starward's `GameInstallHelper.DownloadToFileAsync`:
/// data is written to `<file>_tmp`; on resume the existing tmp length is sent
/// as the `Range` start; after the full length arrives the tmp file is hashed
/// and renamed to the final name only when the MD5 matches.
class DownloadTask extends ChangeNotifier {
  DownloadTask({
    required this.url,
    required this.savePath,
    required this.totalSize,
    required this.expectedMd5,
    required this.displayName,
    this.groupName = '',
  });

  final String url;

  /// Final path of the completed file.
  final String savePath;
  final int totalSize;

  /// Lowercase hex MD5; empty string skips verification.
  final String expectedMd5;
  final String displayName;

  /// Which game/version this file belongs to, for UI grouping.
  final String groupName;

  DownloadStatus _status = DownloadStatus.queued;
  DownloadStatus get status => _status;

  int _receivedBytes = 0;
  int get receivedBytes => _receivedBytes;

  double get progress => totalSize <= 0 ? 0 : _receivedBytes / totalSize;

  /// Bytes per second, updated once per second while downloading.
  double _speed = 0;
  double get speed => _speed;

  String? _error;
  String? get error => _error;

  http.Client? _client;
  bool _abortRequested = false;

  String get _tmpPath => '${savePath}_tmp';

  bool get isActive =>
      _status == DownloadStatus.downloading || _status == DownloadStatus.verifying;

  /// Runs the download until completion, pause or failure.
  /// Returns true when the file is completed and verified.
  Future<bool> run() async {
    if (_status == DownloadStatus.completed) return true;
    _abortRequested = false;
    _error = null;
    _setStatus(DownloadStatus.downloading);
    try {
      final finalFile = File(savePath);
      if (await finalFile.exists()) {
        // Already downloaded before (e.g. app restart); trust and finish.
        if (await finalFile.length() == totalSize) {
          _receivedBytes = totalSize;
          _setStatus(DownloadStatus.completed);
          return true;
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
        await tmpFile.rename(savePath);
        _setStatus(DownloadStatus.completed);
        return true;
      } else {
        // Same as Starward: drop the corrupted tmp so the next attempt restarts.
        await tmpFile.delete();
        _receivedBytes = 0;
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
        mode: resumed ? FileMode.append : FileMode.write);
    int lastBytes = _receivedBytes;
    final speedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _speed = (_receivedBytes - lastBytes).toDouble();
      lastBytes = _receivedBytes;
      notifyListeners();
    });
    try {
      await for (final chunk in response.stream) {
        if (_abortRequested) break;
        sink.add(chunk);
        _receivedBytes += chunk.length;
      }
      await sink.flush();
    } finally {
      speedTimer.cancel();
      await sink.close();
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

  /// Requests pause; the running loop stops at the next chunk.
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
  void reset() {
    if (isActive) return;
    _error = null;
    _setStatus(DownloadStatus.queued);
  }

  /// Restores state loaded from persistence without notifying listeners;
  /// only used before the task is attached to the UI.
  void restoreState(DownloadStatus status, int receivedBytes) {
    _status = status;
    _receivedBytes = receivedBytes;
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
