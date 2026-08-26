import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Directory-level index for final files that have already passed validation.
///
/// The temporary package-cache `.verified` marker is intentionally separate:
/// it represents a verified cache artifact before publishing. This index only
/// tracks final files in the game/save directory.
class VerifiedFileIndex {
  VerifiedFileIndex._();

  static const fileName = '.hoyo_verified_files.json';
  static const _schemaVersion = 1;
  static final Map<String, Future<void>> _locks = {};

  static String indexPathFor(String root) {
    return '$root${Platform.pathSeparator}$fileName';
  }

  static Future<bool> isVerified({
    required String root,
    required String key,
    required File file,
    required int size,
    required String md5,
    Map<String, String> context = const {},
  }) async {
    if (!await file.exists() || await file.length() != size) return false;
    return _withLock(root, () async {
      final index = await _read(root);
      final files = index['files'];
      if (files is! Map<String, dynamic>) return false;
      final entry = files[key];
      if (entry is! Map<String, dynamic>) return false;
      final stat = await file.stat();
      if (entry['size'] != size ||
          entry['md5'] != md5 ||
          entry['modifiedMillis'] != stat.modified.millisecondsSinceEpoch) {
        return false;
      }
      final entryContext = entry['context'];
      if (entryContext is! Map<String, dynamic>) return context.isEmpty;
      for (final item in context.entries) {
        if (entryContext[item.key] != item.value) return false;
      }
      return true;
    });
  }

  static Future<void> markVerified({
    required String root,
    required String key,
    required File file,
    required int size,
    required String md5,
    Map<String, String> context = const {},
  }) async {
    if (!await file.exists()) return;
    await _withLock(root, () async {
      final index = await _read(root);
      final files = _files(index);
      final stat = await file.stat();
      files[key] = {
        'size': size,
        'md5': md5,
        'modifiedMillis': stat.modified.millisecondsSinceEpoch,
        'context': context,
      };
      await _write(root, index);
    });
  }

  static Future<void> remove(String root, String key) async {
    await _withLock(root, () async {
      final index = await _read(root);
      final files = _files(index);
      if (files.remove(key) != null) {
        await _write(root, index);
      }
    });
  }

  static Future<T> _withLock<T>(
    String root,
    Future<T> Function() action,
  ) async {
    final previous = _locks[root] ?? Future<void>.value();
    final completer = Completer<void>();
    final current = previous.then((_) => completer.future);
    _locks[root] = current;
    try {
      await previous;
      return await action();
    } finally {
      completer.complete();
      if (identical(_locks[root], current)) {
        _locks.remove(root);
      }
    }
  }

  static Future<Map<String, dynamic>> _read(String root) async {
    final file = File(indexPathFor(root));
    if (!await file.exists()) {
      return {'version': _schemaVersion, 'files': <String, dynamic>{}};
    }
    try {
      final data = jsonDecode(await file.readAsString());
      if (data is Map<String, dynamic>) {
        final files = data['files'];
        return {
          'version': data['version'] ?? _schemaVersion,
          'files': files is Map<String, dynamic>
              ? Map<String, dynamic>.from(files)
              : <String, dynamic>{},
        };
      }
    } catch (_) {}
    return {'version': _schemaVersion, 'files': <String, dynamic>{}};
  }

  static Map<String, dynamic> _files(Map<String, dynamic> index) {
    final files = index['files'];
    if (files is Map<String, dynamic>) return files;
    final next = <String, dynamic>{};
    index['files'] = next;
    return next;
  }

  static Future<void> _write(String root, Map<String, dynamic> index) async {
    index['version'] = _schemaVersion;
    final file = File(indexPathFor(root));
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(index));
    try {
      await tmp.rename(file.path);
    } catch (_) {
      if (await file.exists()) await file.delete();
      await tmp.rename(file.path);
    }
  }
}
