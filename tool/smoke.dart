/// Smoke test against the real HoYoPlay API (network required):
/// lists games, fetches package info, and range-downloads the first bytes of
/// a real CDN file to prove resume support. Run with `dart run tool/smoke.dart`.
library;

import 'dart:io';

import 'package:hoyo_downloader/core/hoyoplay_client.dart';
import 'package:hoyo_downloader/core/launcher_region.dart';

Future<void> main() async {
  final client = HoYoPlayApiClient();
  try {
    final games = await client.getGames(LauncherRegion.chinaOfficial);
    stdout.writeln('getGames: ${games.length} games');
    for (final game in games) {
      stdout.writeln('  - ${game.name} (${game.gameId.biz}) available=${game.isAvailable}');
    }

    final game = games.firstWhere((g) => g.isAvailable);
    final package = await client.getGamePackage(
        LauncherRegion.chinaOfficial, game.gameId);
    final major = package?.main.major;
    if (major == null) {
      stdout.writeln('no major package for ${game.name}');
      exit(1);
    }
    stdout.writeln('getGamePackages: ${game.name} v${major.version}, '
        '${major.gamePackages.length} game pkgs, '
        '${major.audioPackages.length} audio pkgs');
    final first = major.gamePackages.first;
    stdout.writeln('first file: ${first.fileName} size=${first.size} md5=${first.md5}');

    // Verify the CDN supports Range (the base of our resume logic).
    final httpClient = HttpClient();
    final request = await httpClient.getUrl(Uri.parse(first.url));
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
    final response = await request.close();
    final bytes = await response.fold<int>(0, (n, chunk) => n + chunk.length);
    stdout.writeln('range request: HTTP ${response.statusCode}, got $bytes bytes');
    httpClient.close(force: true);
    if (response.statusCode != 206) {
      stdout.writeln('WARNING: CDN did not answer 206 Partial Content');
      exit(1);
    }
    stdout.writeln('SMOKE TEST PASSED');
  } finally {
    client.close();
  }
}
