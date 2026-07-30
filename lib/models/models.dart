/// Data models for the HoYoPlay hyp-connect API,
/// ported from Starward's `Starward.Core.HoYoPlay` models.
library;

/// Identifies a game on a launcher, ported from `GameId`.
class GameId {
  const GameId({required this.id, required this.biz});

  final String id;

  /// Business region code, e.g. `hk4e_cn`, `hkrpg_global`.
  final String biz;

  factory GameId.fromJson(Map<String, dynamic> json) {
    return GameId(id: json['id'] as String, biz: json['biz'] as String? ?? '');
  }

  @override
  bool operator ==(Object other) => other is GameId && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// An image resource (icon / background / thumbnail).
class GameImage {
  const GameImage({required this.url});

  final String url;

  factory GameImage.fromJson(Map<String, dynamic> json) {
    return GameImage(url: json['url'] as String? ?? '');
  }
}

/// Basic game info returned by `getGames`, ported from `GameInfo`.
class GameInfo {
  const GameInfo({
    required this.gameId,
    required this.name,
    required this.iconUrl,
    required this.backgroundUrl,
    required this.displayStatus,
  });

  final GameId gameId;
  final String name;
  final String iconUrl;
  final String backgroundUrl;
  final String displayStatus;

  /// Whether the game is downloadable now (not "coming soon").
  bool get isAvailable =>
      displayStatus == 'LAUNCHER_GAME_DISPLAY_STATUS_AVAILABLE';

  factory GameInfo.fromJson(Map<String, dynamic> json) {
    final display = json['display'] as Map<String, dynamic>? ?? const {};
    return GameInfo(
      gameId: GameId.fromJson(json),
      name: display['name'] as String? ?? '',
      iconUrl: display['icon'] is Map<String, dynamic>
          ? GameImage.fromJson(display['icon'] as Map<String, dynamic>).url
          : '',
      backgroundUrl: display['background'] is Map<String, dynamic>
          ? GameImage.fromJson(display['background'] as Map<String, dynamic>).url
          : '',
      displayStatus: json['display_status'] as String? ?? '',
    );
  }
}

/// A single downloadable file of a package, ported from `GamePackageFile`.
class GamePackageFile {
  const GamePackageFile({
    required this.url,
    required this.md5,
    required this.size,
    required this.decompressedSize,
    this.language,
  });

  final String url;

  /// Lowercase hex md5 of the file.
  final String md5;
  final int size;
  final int decompressedSize;

  /// Audio package language such as `zh-cn`, null for game packages.
  final String? language;

  String get fileName {
    final path = Uri.parse(url).path;
    final i = path.lastIndexOf('/');
    return i >= 0 ? path.substring(i + 1) : path;
  }

  factory GamePackageFile.fromJson(Map<String, dynamic> json) {
    return GamePackageFile(
      url: json['url'] as String? ?? '',
      md5: (json['md5'] as String? ?? '').toLowerCase(),
      size: _asInt(json['size']),
      decompressedSize: _asInt(json['decompressed_size']),
      language: json['language'] as String?,
    );
  }
}

/// A full package of one version, ported from `GamePackageResource`.
class GamePackageResource {
  const GamePackageResource({
    required this.version,
    required this.gamePackages,
    required this.audioPackages,
  });

  final String version;
  final List<GamePackageFile> gamePackages;
  final List<GamePackageFile> audioPackages;

  factory GamePackageResource.fromJson(Map<String, dynamic> json) {
    return GamePackageResource(
      version: json['version'] as String? ?? '',
      gamePackages: _fileList(json['game_pkgs']),
      audioPackages: _fileList(json['audio_pkgs']),
    );
  }
}

/// Main / pre-download package versions, ported from `GamePackageVersion`.
class GamePackageVersion {
  const GamePackageVersion({this.major, required this.patches});

  /// Full install package; null when unavailable.
  final GamePackageResource? major;

  /// Incremental update packages from older versions.
  final List<GamePackageResource> patches;

  factory GamePackageVersion.fromJson(Map<String, dynamic> json) {
    return GamePackageVersion(
      major: json['major'] is Map<String, dynamic>
          ? GamePackageResource.fromJson(json['major'] as Map<String, dynamic>)
          : null,
      patches: (json['patches'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(GamePackageResource.fromJson)
          .toList(),
    );
  }
}

/// Package info of a game returned by `getGamePackages`, ported from `GamePackage`.
class GamePackage {
  const GamePackage({
    required this.gameId,
    required this.main,
    this.preDownload,
  });

  final GameId gameId;
  final GamePackageVersion main;
  final GamePackageVersion? preDownload;

  factory GamePackage.fromJson(Map<String, dynamic> json) {
    return GamePackage(
      gameId: GameId.fromJson(json['game'] as Map<String, dynamic>),
      main: GamePackageVersion.fromJson(
          json['main'] as Map<String, dynamic>? ?? const {}),
      preDownload: json['pre_download'] is Map<String, dynamic>
          ? GamePackageVersion.fromJson(
              json['pre_download'] as Map<String, dynamic>)
          : null,
    );
  }
}

List<GamePackageFile> _fileList(dynamic value) {
  return (value as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>()
      .map(GamePackageFile.fromJson)
      .toList();
}

/// The API serializes sizes as strings ("79214804219").
int _asInt(dynamic value) {
  if (value is int) return value;
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}
