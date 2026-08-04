import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:zstandard/zstandard.dart';

import '../models/models.dart';
import '../models/sophon_models.dart';
import 'api_exception.dart';
import 'launcher_region.dart';

/// HTTP client for the HoYoPlay hyp-connect API,
/// ported from Starward's `HoYoPlayClient`.
class HoYoPlayApiClient {
  HoYoPlayApiClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// Sends a GET request and unwraps the `{retcode, message, data}` envelope,
  /// mirroring Starward's `CommonGetAsync`.
  Future<dynamic> _getData(Uri uri) async {
    final response = await _client.get(uri);
    if (response.statusCode != 200) {
      throw ApiException(response.statusCode, 'HTTP ${response.statusCode}');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (body is! Map<String, dynamic>) {
      throw const ApiException(-1, 'Can not parse the response body.');
    }
    final retcode = body['retcode'] as int? ?? -1;
    if (retcode != 0) {
      throw ApiException(retcode, body['message'] as String? ?? 'Unknown error');
    }
    return body['data'];
  }

  /// Fetches the game list of a launcher region (`getGames`).
  Future<List<GameInfo>> getGames(LauncherRegion region,
      {String language = 'zh-cn'}) async {
    final data = await _getData(region.buildApiUri('getGames', language: language));
    final games = (data?['games'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(GameInfo.fromJson)
        .toList();
    return games;
  }

  /// Fetches package info of one game (`getGamePackages`).
  Future<GamePackage?> getGamePackage(LauncherRegion region, GameId gameId,
      {String language = 'zh-cn'}) async {
    final uri = region.buildApiUri('getGamePackages',
        language: language, extra: {'game_ids[]': gameId.id});
    final data = await _getData(uri);
    final packages = (data?['game_packages'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(GamePackage.fromJson)
        .toList();
    for (final p in packages) {
      if (p.gameId == gameId) return p;
    }
    return packages.isEmpty ? null : packages.first;
  }

  /// Fetches the Sophon branch info of one game (`getGameBranches`).
  Future<GameBranch?> getGameBranch(LauncherRegion region, GameId gameId,
      {String language = 'zh-cn'}) async {
    final uri = region.buildApiUri('getGameBranches',
        language: language, extra: {'game_ids[]': gameId.id});
    final data = await _getData(uri);
    final branches = (data?['game_branches'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(GameBranch.fromJson)
        .toList();
    for (final b in branches) {
      if (b.gameId == gameId) return b;
    }
    return branches.isEmpty ? null : branches.first;
  }

  /// Fetches the Sophon full-build manifest index.
  Future<SophonBuild> getSophonChunkBuild(
    LauncherRegion region,
    GameId gameId,
    GameBranchPackage package,
  ) async {
    final host = _downloaderHost(region, gameId);
    final uri = Uri.https(host, '/downloader/sophon_chunk/api/getBuild', {
      'branch': package.branch,
      'package_id': package.packageId,
      'password': package.password,
      'tag': package.tag,
    });
    final data = await _getData(uri);
    return SophonBuild.fromJson(data as Map<String, dynamic>);
  }

  /// Downloads, zstd-decompresses and parses one Sophon manifest.
  Future<SophonChunkManifest> downloadAndParseSophonManifest(
      SophonManifestMeta meta) async {
    final response = await _client.get(Uri.parse(meta.manifestUrl));
    if (response.statusCode != 200 && response.statusCode != 206) {
      throw ApiException(response.statusCode, 'HTTP ${response.statusCode}');
    }
    final compressed = Uint8List.fromList(response.bodyBytes);
    final decompressed = await Zstandard().decompress(compressed);
    if (decompressed == null) {
      throw const ApiException(-1, 'Can not decompress Sophon manifest.');
    }
    final checksum = hex.encode(md5.convert(decompressed).bytes);
    if (meta.manifestChecksum.isNotEmpty && checksum != meta.manifestChecksum) {
      throw ApiException(-1,
          'Sophon manifest checksum mismatch: $checksum != ${meta.manifestChecksum}');
    }
    return SophonChunkManifest.fromProtoBytes(decompressed);
  }

  String _downloaderHost(LauncherRegion region, GameId gameId) {
    if (region == LauncherRegion.globalOfficial ||
        gameId.biz.endsWith('_global')) {
      return 'sg-downloader-api.hoyoverse.com';
    }
    return 'downloader-api.mihoyo.com';
  }

  void close() => _client.close();
}
