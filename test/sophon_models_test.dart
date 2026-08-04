import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hoyo_downloader/models/sophon_models.dart';

void main() {
  List<int> varint(int value) {
    final out = <int>[];
    var v = value;
    while (true) {
      if (v < 0x80) {
        out.add(v);
        return out;
      }
      out.add((v & 0x7f) | 0x80);
      v >>= 7;
    }
  }

  List<int> fieldVarint(int number, int value) => [
        ...varint(number << 3),
        ...varint(value),
      ];

  List<int> fieldBytes(int number, List<int> value) => [
        ...varint((number << 3) | 2),
        ...varint(value.length),
        ...value,
      ];

  List<int> fieldString(int number, String value) =>
      fieldBytes(number, utf8.encode(value));

  test('parses Sophon chunk manifest proto fields', () {
    final chunk = <int>[
      ...fieldString(1, 'chunk_id'),
      ...fieldString(2, 'uncompressed_md5'),
      ...fieldVarint(3, 123),
      ...fieldVarint(4, 456),
      ...fieldVarint(5, 789),
      ...fieldVarint(6, 1),
      ...fieldString(7, 'compressed_md5'),
    ];
    final file = <int>[
      ...fieldString(1, 'Game/Data/file.bin'),
      ...fieldBytes(2, chunk),
      ...fieldVarint(3, 0),
      ...fieldVarint(4, 789),
      ...fieldString(5, 'file_md5'),
    ];
    final manifest = SophonChunkManifest.fromProtoBytes(
      Uint8List.fromList(fieldBytes(1, file)),
    );

    expect(manifest.files, hasLength(1));
    final parsedFile = manifest.files.single;
    expect(parsedFile.file, 'Game/Data/file.bin');
    expect(parsedFile.size, 789);
    expect(parsedFile.md5, 'file_md5');
    expect(parsedFile.chunks, hasLength(1));
    final parsedChunk = parsedFile.chunks.single;
    expect(parsedChunk.id, 'chunk_id');
    expect(parsedChunk.offset, 123);
    expect(parsedChunk.compressedSize, 456);
    expect(parsedChunk.uncompressedSize, 789);
    expect(parsedChunk.compressedMd5, 'compressed_md5');
    expect(parsedChunk.uncompressedMd5, 'uncompressed_md5');
  });

  test('SophonManifestMeta builds display names and URLs', () {
    const meta = SophonManifestMeta(
      categoryId: '100',
      categoryName: 'null',
      matchingField: 'game',
      manifestId: 'manifest_id',
      manifestChecksum: 'abc',
      manifestCompressedSize: 1,
      manifestUncompressedSize: 2,
      manifestUrlPrefix: 'https://example.com/manifests/',
      manifestUrlSuffix: '?x=1',
      chunkUrlPrefix: 'https://example.com/chunks',
      chunkUrlSuffix: '',
      compressedSize: 3,
      uncompressedSize: 4,
      fileCount: 5,
      chunkCount: 6,
    );

    expect(meta.displayName, '游戏资源');
    expect(meta.manifestUrl, 'https://example.com/manifests/manifest_id?x=1');
    expect(meta.chunkUrl('chunk_id'), 'https://example.com/chunks/chunk_id');
    expect(SophonManifestMeta.fromPersistedJson(meta.toJson()).chunkCount, 6);
  });
}
