/// Launcher region constants, ported from Starward's `LauncherId`.
///
/// A launcher id identifies a HoYoPlay launcher deployment; each deployment
/// serves a different set of games (China official / Global official / Bilibili
/// channel launchers).
class LauncherRegion {
  const LauncherRegion._({
    required this.launcherId,
    required this.apiHost,
    required this.displayName,
  });

  /// The `launcher_id` query parameter value.
  final String launcherId;

  /// API host serving this launcher.
  final String apiHost;

  /// Human readable name.
  final String displayName;

  static const chinaOfficial = LauncherRegion._(
    launcherId: 'jGHBHlcOq1',
    apiHost: 'hyp-api.mihoyo.com',
    displayName: '国服 (China)',
  );

  static const globalOfficial = LauncherRegion._(
    launcherId: 'VYTpXlbWo8',
    apiHost: 'sg-hyp-api.hoyoverse.com',
    displayName: '国际服 (Global)',
  );

  static const bilibiliGenshin = LauncherRegion._(
    launcherId: 'umfgRO5gh5',
    apiHost: 'hyp-api.mihoyo.com',
    displayName: 'B服·原神',
  );

  static const bilibiliStarRail = LauncherRegion._(
    launcherId: '6P5gHMNyK3',
    apiHost: 'hyp-api.mihoyo.com',
    displayName: 'B服·星穹铁道',
  );

  static const bilibiliZZZ = LauncherRegion._(
    launcherId: 'xV0f4r1GT0',
    apiHost: 'hyp-api.mihoyo.com',
    displayName: 'B服·绝区零',
  );

  /// Regions selectable in the UI.
  static const values = [chinaOfficial, globalOfficial];

  /// Builds the hyp-connect API url, mirroring Starward's `BuildUrl`.
  Uri buildApiUri(String api, {String language = 'zh-cn', Map<String, String>? extra}) {
    return Uri.https(apiHost, '/hyp/hyp-connect/api/$api', {
      'launcher_id': launcherId,
      'language': language,
      ...?extra,
    });
  }
}
