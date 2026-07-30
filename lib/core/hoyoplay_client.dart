import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/models.dart';
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

  void close() => _client.close();
}
