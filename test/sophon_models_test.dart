import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hoyo_downloader/models/sophon_models.dart';

void main() {
  SophonManifestMeta meta(
    String id,
    String matchingField, {
    String categoryName = '',
    int size = 10,
  }) {
    return SophonManifestMeta(
      categoryId: id,
      categoryName: categoryName,
      matchingField: matchingField,
      manifestId: 'manifest_$id',
      manifestChecksum: '',
      manifestCompressedSize: 0,
      manifestUncompressedSize: 0,
      manifestUrlPrefix: 'https://example.com/manifests',
      manifestUrlSuffix: '',
      chunkUrlPrefix: 'https://example.com/chunks',
      chunkUrlSuffix: '',
      compressedSize: size,
      uncompressedSize: size * 2,
      fileCount: 1,
      chunkCount: 2,
    );
  }

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
    final item = meta('100', 'game', categoryName: 'null', size: 3);
    final chapter = meta('101', '12345', categoryName: '第一章资源', size: 3);

    expect(item.displayName, '游戏资源');
    expect(chapter.displayName, '第一章资源');
    expect(item.manifestUrl, 'https://example.com/manifests/manifest_100');
    expect(item.chunkUrl('chunk_id'), 'https://example.com/chunks/chunk_id');
    expect(SophonManifestMeta.fromPersistedJson(item.toJson()).chunkCount, 2);
  });

  test(
    'groups Sophon manifests into game resource and language audio packs',
    () {
      final groups = groupSophonManifests([
        meta('game_a', 'game', size: 100),
        meta('game_b', '10001', categoryName: '第一章资源', size: 50),
        meta('zh_a', 'zh-cn', size: 20),
        meta('zh_b', 'mini-zh-cn', categoryName: '中文语音', size: 30),
        meta('ja_a', 'ja-jp', size: 40),
        meta('ko_a', 'mini-ko-kr', size: 60),
        meta('activity_a', 'activity_en', categoryName: '活动场景', size: 70),
        meta('garden_a', 'box_garden_de', categoryName: '箱庭独立场景', size: 80),
      ]);

      expect(groups.map((g) => g.title), [
        '游戏资源',
        '中文语音包',
        '日文语音包',
        '韩文语音包',
        '其他',
      ]);
      expect(groups.first.kind, SophonCategoryKind.game);
      expect(groups.first.manifests.map((m) => m.categoryId), [
        'game_a',
        'game_b',
      ]);
      final zh = groups.firstWhere((g) => g.title == '中文语音包');
      expect(zh.kind, SophonCategoryKind.audio);
      expect(zh.languageCode, 'zh-cn');
      expect(zh.compressedSize, 50);
      expect(zh.fileCount, 2);
      expect(zh.chunkCount, 4);
      final other = groups.firstWhere((g) => g.title == '其他');
      expect(other.kind, SophonCategoryKind.other);
      expect(other.languageCode, isNull);
      expect(other.manifests.map((m) => m.categoryId), [
        'activity_a',
        'garden_a',
      ]);
    },
  );
}
