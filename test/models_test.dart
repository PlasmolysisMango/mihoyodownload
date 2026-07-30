import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hoyo_downloader/core/launcher_region.dart';
import 'package:hoyo_downloader/models/models.dart';

void main() {
  group('LauncherRegion', () {
    test('builds getGames url like Starward BuildUrl', () {
      final uri = LauncherRegion.chinaOfficial.buildApiUri('getGames');
      expect(uri.host, 'hyp-api.mihoyo.com');
      expect(uri.path, '/hyp/hyp-connect/api/getGames');
      expect(uri.queryParameters['launcher_id'], 'jGHBHlcOq1');
      expect(uri.queryParameters['language'], 'zh-cn');

      final global = LauncherRegion.globalOfficial
          .buildApiUri('getGamePackages', language: 'en-us', extra: {'game_ids[]': 'abc'});
      expect(global.host, 'sg-hyp-api.hoyoverse.com');
      expect(global.queryParameters['game_ids[]'], 'abc');
    });
  });

  group('models', () {
    test('parses GameInfo from getGames payload', () {
      final json = jsonDecode('''
      {
        "id": "1Z8W5NHUQb",
        "biz": "hk4e_cn",
        "display": {
          "name": "原神",
          "icon": {"url": "https://example.com/icon.png"},
          "background": {"url": "https://example.com/bg.webp"}
        },
        "display_status": "LAUNCHER_GAME_DISPLAY_STATUS_AVAILABLE"
      }
      ''') as Map<String, dynamic>;
      final info = GameInfo.fromJson(json);
      expect(info.gameId.id, '1Z8W5NHUQb');
      expect(info.gameId.biz, 'hk4e_cn');
      expect(info.name, '原神');
      expect(info.iconUrl, 'https://example.com/icon.png');
      expect(info.isAvailable, isTrue);
    });

    test('parses GamePackage with string sizes and audio languages', () {
      final json = jsonDecode('''
      {
        "game": {"id": "1Z8W5NHUQb", "biz": "hk4e_cn"},
        "main": {
          "major": {
            "version": "5.5.0",
            "game_pkgs": [
              {"url": "https://example.com/game.zip.001", "md5": "ABCDEF", "size": "79214804219", "decompressed_size": "100000000000"}
            ],
            "audio_pkgs": [
              {"language": "zh-cn", "url": "https://example.com/audio_zh.zip", "md5": "123456", "size": "15083993globalbad", "decompressed_size": "2"}
            ],
            "res_list_url": ""
          },
          "patches": []
        },
        "pre_download": {}
      }
      ''') as Map<String, dynamic>;
      final package = GamePackage.fromJson(json);
      expect(package.gameId.biz, 'hk4e_cn');
      final major = package.main.major!;
      expect(major.version, '5.5.0');
      expect(major.gamePackages.single.size, 79214804219);
      expect(major.gamePackages.single.md5, 'abcdef');
      expect(major.gamePackages.single.fileName, 'game.zip.001');
      expect(major.audioPackages.single.language, 'zh-cn');
      // Unparsable size falls back to 0 instead of throwing.
      expect(major.audioPackages.single.size, 0);
      expect(package.preDownload!.major, isNull);
    });

    test('parses GamePackage when major is null', () {
      final json = jsonDecode('''
      {
        "game": {"id": "x", "biz": "nap_cn"},
        "main": {"major": null, "patches": []}
      }
      ''') as Map<String, dynamic>;
      final package = GamePackage.fromJson(json);
      expect(package.main.major, isNull);
      expect(package.preDownload, isNull);
    });
  });
}
