import 'dart:convert';
import 'dart:typed_data';

import 'models.dart';

/// HoYoPlay branch information used by the Sophon/chunk downloader.
class GameBranch {
  const GameBranch({required this.gameId, required this.main});

  final GameId gameId;
  final GameBranchPackage main;

  factory GameBranch.fromJson(Map<String, dynamic> json) {
    return GameBranch(
      gameId: GameId.fromJson(json['game'] as Map<String, dynamic>),
      main: GameBranchPackage.fromJson(
          json['main'] as Map<String, dynamic>? ?? const {}),
    );
  }
}

class GameBranchPackage {
  const GameBranchPackage({
    required this.packageId,
    required this.branch,
    required this.password,
    required this.tag,
    required this.categories,
  });

  final String packageId;
  final String branch;
  final String password;
  final String tag;
  final List<GameBranchCategory> categories;

  factory GameBranchPackage.fromJson(Map<String, dynamic> json) {
    return GameBranchPackage(
      packageId: json['package_id'] as String? ?? '',
      branch: json['branch'] as String? ?? '',
      password: json['password'] as String? ?? '',
      tag: json['tag'] as String? ?? '',
      categories: (json['categories'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(GameBranchCategory.fromJson)
          .toList(),
    );
  }
}

class GameBranchCategory {
  const GameBranchCategory({
    required this.categoryId,
    required this.matchingField,
    required this.type,
    required this.scenarios,
  });

  final String categoryId;
  final String matchingField;
  final String type;
  final List<String> scenarios;

  bool get isBaseScenario => scenarios.contains('CATEGORY_SCENARIO_BASE');

  factory GameBranchCategory.fromJson(Map<String, dynamic> json) {
    return GameBranchCategory(
      categoryId: json['category_id'] as String? ?? '',
      matchingField: json['matching_field'] as String? ?? '',
      type: json['type'] as String? ?? '',
      scenarios: (json['scenarios'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(),
    );
  }
}

class SophonBuild {
  const SophonBuild({
    required this.buildId,
    required this.tag,
    required this.manifests,
  });

  final String buildId;
  final String tag;
  final List<SophonManifestMeta> manifests;

  factory SophonBuild.fromJson(Map<String, dynamic> json) {
    return SophonBuild(
      buildId: json['build_id'] as String? ?? '',
      tag: json['tag'] as String? ?? '',
      manifests: (json['manifests'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(SophonManifestMeta.fromJson)
          .toList(),
    );
  }
}

class SophonManifestMeta {
  const SophonManifestMeta({
    required this.categoryId,
    required this.categoryName,
    required this.matchingField,
    required this.manifestId,
    required this.manifestChecksum,
    required this.manifestCompressedSize,
    required this.manifestUncompressedSize,
    required this.manifestUrlPrefix,
    required this.manifestUrlSuffix,
    required this.chunkUrlPrefix,
    required this.chunkUrlSuffix,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.fileCount,
    required this.chunkCount,
  });

  final String categoryId;
  final String categoryName;
  final String matchingField;
  final String manifestId;
  final String manifestChecksum;
  final int manifestCompressedSize;
  final int manifestUncompressedSize;
  final String manifestUrlPrefix;
  final String manifestUrlSuffix;
  final String chunkUrlPrefix;
  final String chunkUrlSuffix;
  final int compressedSize;
  final int uncompressedSize;
  final int fileCount;
  final int chunkCount;

  String get displayName {
    if (matchingField == 'game') return '游戏资源';
    if (categoryName.isNotEmpty && categoryName != 'null') return categoryName;
    return '资源 $matchingField';
  }

  String get manifestUrl => _joinUrl(manifestUrlPrefix, manifestId, manifestUrlSuffix);

  String chunkUrl(String chunkId) => _joinUrl(chunkUrlPrefix, chunkId, chunkUrlSuffix);

  Map<String, dynamic> toJson() => {
        'categoryId': categoryId,
        'categoryName': categoryName,
        'matchingField': matchingField,
        'manifestId': manifestId,
        'manifestChecksum': manifestChecksum,
        'manifestCompressedSize': manifestCompressedSize,
        'manifestUncompressedSize': manifestUncompressedSize,
        'manifestUrlPrefix': manifestUrlPrefix,
        'manifestUrlSuffix': manifestUrlSuffix,
        'chunkUrlPrefix': chunkUrlPrefix,
        'chunkUrlSuffix': chunkUrlSuffix,
        'compressedSize': compressedSize,
        'uncompressedSize': uncompressedSize,
        'fileCount': fileCount,
        'chunkCount': chunkCount,
      };

  factory SophonManifestMeta.fromPersistedJson(Map<String, dynamic> json) {
    return SophonManifestMeta(
      categoryId: json['categoryId'] as String? ?? '',
      categoryName: json['categoryName'] as String? ?? '',
      matchingField: json['matchingField'] as String? ?? '',
      manifestId: json['manifestId'] as String? ?? '',
      manifestChecksum: json['manifestChecksum'] as String? ?? '',
      manifestCompressedSize: _asInt(json['manifestCompressedSize']),
      manifestUncompressedSize: _asInt(json['manifestUncompressedSize']),
      manifestUrlPrefix: json['manifestUrlPrefix'] as String? ?? '',
      manifestUrlSuffix: json['manifestUrlSuffix'] as String? ?? '',
      chunkUrlPrefix: json['chunkUrlPrefix'] as String? ?? '',
      chunkUrlSuffix: json['chunkUrlSuffix'] as String? ?? '',
      compressedSize: _asInt(json['compressedSize']),
      uncompressedSize: _asInt(json['uncompressedSize']),
      fileCount: _asInt(json['fileCount']),
      chunkCount: _asInt(json['chunkCount']),
    );
  }

  factory SophonManifestMeta.fromJson(Map<String, dynamic> json) {
    final manifest = json['manifest'] as Map<String, dynamic>? ?? const {};
    final manifestDownload =
        json['manifest_download'] as Map<String, dynamic>? ?? const {};
    final chunkDownload =
        json['chunk_download'] as Map<String, dynamic>? ?? const {};
    final stats = json['deduplicated_stats'] as Map<String, dynamic>? ??
        json['stats'] as Map<String, dynamic>? ??
        const {};
    return SophonManifestMeta(
      categoryId: json['category_id'] as String? ?? '',
      categoryName: json['category_name'] as String? ?? '',
      matchingField: json['matching_field'] as String? ?? '',
      manifestId: manifest['id'] as String? ?? '',
      manifestChecksum: (manifest['checksum'] as String? ?? '').toLowerCase(),
      manifestCompressedSize: _asInt(manifest['compressed_size']),
      manifestUncompressedSize: _asInt(manifest['uncompressed_size']),
      manifestUrlPrefix: manifestDownload['url_prefix'] as String? ?? '',
      manifestUrlSuffix: manifestDownload['url_suffix'] as String? ?? '',
      chunkUrlPrefix: chunkDownload['url_prefix'] as String? ?? '',
      chunkUrlSuffix: chunkDownload['url_suffix'] as String? ?? '',
      compressedSize: _asInt(stats['compressed_size']),
      uncompressedSize: _asInt(stats['uncompressed_size']),
      fileCount: _asInt(stats['file_count']),
      chunkCount: _asInt(stats['chunk_count']),
    );
  }
}

class SophonChunkManifest {
  const SophonChunkManifest({required this.files});

  final List<SophonFile> files;

  factory SophonChunkManifest.fromProtoBytes(Uint8List bytes) {
    final reader = _ProtoReader(bytes);
    final files = <SophonFile>[];
    while (!reader.isDone) {
      final field = reader.readField();
      if (field == null) break;
      if (field.number == 1 && field.value is Uint8List) {
        files.add(SophonFile.fromProtoBytes(field.value as Uint8List));
      }
    }
    return SophonChunkManifest(files: files);
  }
}

class SophonFile {
  const SophonFile({
    required this.file,
    required this.chunks,
    required this.isFolder,
    required this.size,
    required this.md5,
  });

  final String file;
  final List<SophonChunk> chunks;
  final bool isFolder;
  final int size;
  final String md5;

  factory SophonFile.fromProtoBytes(Uint8List bytes) {
    final reader = _ProtoReader(bytes);
    var file = '';
    final chunks = <SophonChunk>[];
    var isFolder = false;
    var size = 0;
    var md5 = '';
    while (!reader.isDone) {
      final field = reader.readField();
      if (field == null) break;
      switch (field.number) {
        case 1:
          file = _utf8(field.value);
        case 2:
          if (field.value is Uint8List) {
            chunks.add(SophonChunk.fromProtoBytes(field.value as Uint8List));
          }
        case 3:
          isFolder = (field.value as int? ?? 0) != 0;
        case 4:
          size = field.value as int? ?? 0;
        case 5:
          md5 = _utf8(field.value).toLowerCase();
      }
    }
    return SophonFile(
      file: file,
      chunks: chunks,
      isFolder: isFolder,
      size: size,
      md5: md5,
    );
  }
}

class SophonChunk {
  const SophonChunk({
    required this.id,
    required this.uncompressedMd5,
    required this.offset,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.compressedMd5,
  });

  final String id;
  final String uncompressedMd5;
  final int offset;
  final int compressedSize;
  final int uncompressedSize;
  final String compressedMd5;

  factory SophonChunk.fromProtoBytes(Uint8List bytes) {
    final reader = _ProtoReader(bytes);
    var id = '';
    var uncompressedMd5 = '';
    var offset = 0;
    var compressedSize = 0;
    var uncompressedSize = 0;
    var compressedMd5 = '';
    while (!reader.isDone) {
      final field = reader.readField();
      if (field == null) break;
      switch (field.number) {
        case 1:
          id = _utf8(field.value);
        case 2:
          uncompressedMd5 = _utf8(field.value).toLowerCase();
        case 3:
          offset = field.value as int? ?? 0;
        case 4:
          compressedSize = field.value as int? ?? 0;
        case 5:
          uncompressedSize = field.value as int? ?? 0;
        case 7:
          compressedMd5 = _utf8(field.value).toLowerCase();
      }
    }
    return SophonChunk(
      id: id,
      uncompressedMd5: uncompressedMd5,
      offset: offset,
      compressedSize: compressedSize,
      uncompressedSize: uncompressedSize,
      compressedMd5: compressedMd5,
    );
  }
}

class _ProtoField {
  const _ProtoField(this.number, this.value);
  final int number;
  final Object value;
}

class _ProtoReader {
  _ProtoReader(this.bytes);

  final Uint8List bytes;
  int _offset = 0;

  bool get isDone => _offset >= bytes.length;

  _ProtoField? readField() {
    if (isDone) return null;
    final key = _readVarint();
    final number = key >> 3;
    final wireType = key & 0x7;
    switch (wireType) {
      case 0:
        return _ProtoField(number, _readVarint());
      case 1:
        _offset += 8;
        return _ProtoField(number, 0);
      case 2:
        final length = _readVarint();
        final value = Uint8List.sublistView(bytes, _offset, _offset + length);
        _offset += length;
        return _ProtoField(number, value);
      case 5:
        _offset += 4;
        return _ProtoField(number, 0);
      default:
        throw FormatException('Unsupported protobuf wire type: $wireType');
    }
  }

  int _readVarint() {
    var result = 0;
    var shift = 0;
    while (_offset < bytes.length) {
      final byte = bytes[_offset++];
      result |= (byte & 0x7f) << shift;
      if (byte < 0x80) return result;
      shift += 7;
    }
    throw const FormatException('Unexpected EOF while reading varint');
  }
}

String _utf8(Object value) {
  if (value is! Uint8List) return '';
  return utf8.decode(value);
}

String _joinUrl(String prefix, String value, String suffix) {
  final p = prefix.endsWith('/') ? prefix.substring(0, prefix.length - 1) : prefix;
  return '$p/$value$suffix';
}

int _asInt(dynamic value) {
  if (value is int) return value;
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}
