import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_settings.dart';
import '../core/hoyoplay_client.dart';
import '../core/launcher_region.dart';
import '../download/download_manager.dart';
import '../models/models.dart';
import '../models/sophon_models.dart';
import 'downloads_page.dart';
import 'format.dart';

/// Package selection page: prefer Sophon/chunk mode and keep zip packages as
/// a compatibility fallback.
class PackagePage extends StatefulWidget {
  const PackagePage({super.key, required this.region, required this.game});

  final LauncherRegion region;
  final GameInfo game;

  @override
  State<PackagePage> createState() => _PackagePageState();
}

class _PackagePageState extends State<PackagePage> {
  late Future<_PackageData> _dataFuture;
  final Set<GamePackageFile> _selectedPackages = {};
  final Set<String> _selectedCategoryIds = {};
  bool _initializedPackageSelection = false;
  bool _initializedSophonSelection = false;
  bool _useChunkMode = true;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    _dataFuture = _loadData();
  }

  Future<_PackageData> _loadData() async {
    final client = context.read<HoYoPlayApiClient>();
    final packageFuture = client.getGamePackage(
      widget.region,
      widget.game.gameId,
    );
    SophonBuild? build;
    try {
      final branch = await client.getGameBranch(
        widget.region,
        widget.game.gameId,
      );
      if (branch != null && branch.main.packageId.isNotEmpty) {
        build = await client.getSophonChunkBuild(
          widget.region,
          widget.game.gameId,
          branch.main,
        );
      }
    } catch (_) {
      // Keep package mode usable when Sophon is unavailable.
    }
    return _PackageData(package: await packageFuture, sophonBuild: build);
  }

  int get _selectedPackageSize =>
      _selectedPackages.fold(0, (s, f) => s + f.size);

  void _initPackageSelection(GamePackageResource resource) {
    if (_initializedPackageSelection) return;
    _initializedPackageSelection = true;
    _selectedPackages.addAll(resource.gamePackages);
  }

  void _initSophonSelection(List<SophonManifestMeta> manifests) {
    if (_initializedSophonSelection) return;
    _initializedSophonSelection = true;
    final groups = groupSophonManifests(manifests);
    final gameGroup = groups.where((g) => g.kind == SophonCategoryKind.game);
    for (final group in gameGroup) {
      _selectedCategoryIds.addAll(group.manifests.map((m) => m.categoryId));
    }
    if (_selectedCategoryIds.isEmpty && groups.isNotEmpty) {
      _selectedCategoryIds.addAll(
        groups.first.manifests.map((m) => m.categoryId),
      );
    }
  }

  Future<String> _downloadSaveDir(String version) async {
    final settings = context.read<AppSettings>();
    final baseDir = await settings.resolveDownloadDir();
    return '$baseDir/${widget.game.gameId.biz}_$version';
  }

  Future<void> _startPackageDownload(GamePackageResource resource) async {
    final manager = context.read<DownloadManager>();
    final navigator = Navigator.of(context);
    final saveDir = await _downloadSaveDir(resource.version);
    manager.addPackageFiles(
      groupName: '${widget.game.name} ${resource.version}',
      saveDir: saveDir,
      files: _selectedPackages.toList(),
    );
    navigator.push(MaterialPageRoute(builder: (_) => const DownloadsPage()));
  }

  Future<void> _startSophonDownload(SophonBuild build) async {
    final manager = context.read<DownloadManager>();
    final client = context.read<HoYoPlayApiClient>();
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final selected = build.manifests
        .where((m) => _selectedCategoryIds.contains(m.categoryId))
        .toList();
    if (selected.isEmpty) return;
    setState(() => _starting = true);
    try {
      final parsed = <(SophonManifestMeta, SophonChunkManifest)>[];
      for (final meta in selected) {
        final manifest = await client.downloadAndParseSophonManifest(meta);
        parsed.add((meta, manifest));
      }
      final saveDir = await _downloadSaveDir(build.tag);
      manager.addSophonManifests(
        groupName: '${widget.game.name} ${build.tag}',
        saveDir: saveDir,
        version: build.tag,
        manifests: parsed,
      );
      navigator.push(MaterialPageRoute(builder: (_) => const DownloadsPage()));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Chunk 清单加载失败：$e')));
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.game.name)),
      body: FutureBuilder<_PackageData>(
        future: _dataFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('加载失败：${snapshot.error}'));
          }
          final data = snapshot.data!;
          final build = data.sophonBuild;
          final packageResource = data.package?.main.major;
          if (build != null && build.manifests.isNotEmpty && _useChunkMode) {
            _initSophonSelection(build.manifests);
            return _buildSophonMode(build, packageResource != null);
          }
          if (packageResource != null) {
            _initPackageSelection(packageResource);
            return _buildPackageMode(packageResource, build != null);
          }
          return const Center(child: Text('暂无可用下载资源'));
        },
      ),
    );
  }

  Widget _buildSophonMode(SophonBuild build, bool canFallback) {
    final groups = groupSophonManifests(build.manifests);
    final gameGroups = groups.where((g) => g.kind == SophonCategoryKind.game);
    final audioGroups = groups.where((g) => g.kind == SophonCategoryKind.audio);
    final otherGroups = groups.where((g) => g.kind == SophonCategoryKind.other);
    final selected = build.manifests
        .where((m) => _selectedCategoryIds.contains(m.categoryId))
        .toList();
    final selectedSize = selected.fold<int>(
      0,
      (sum, m) => sum + m.compressedSize,
    );
    final selectedGroupCount = groups
        .where(
          (g) => g.manifests.any(
            (m) => _selectedCategoryIds.contains(m.categoryId),
          ),
        )
        .length;
    return Column(
      children: [
        _modeBanner(
          title: 'Chunk 模式（推荐）',
          subtitle: '按官方小块下载与校验；界面已聚合为游戏资源和语音包。',
          canSwitch: canFallback,
        ),
        Expanded(
          child: ListView(
            children: [
              _sophonSelectionActions(build.manifests),
              if (gameGroups.isNotEmpty) _sectionHeader(context, '游戏资源'),
              for (final group in gameGroups) _sophonGroupTile(group),
              if (audioGroups.isNotEmpty) _sectionHeader(context, '语音包（可选）'),
              for (final group in audioGroups) _sophonGroupTile(group),
              if (otherGroups.isNotEmpty) _sectionHeader(context, '其他'),
              for (final group in otherGroups) _sophonGroupTile(group),
            ],
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '已选 $selectedGroupCount 个资源组 / ${selected.length} 个分类\n约 ${formatBytes(selectedSize)}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                FilledButton.icon(
                  onPressed: _starting || selected.isEmpty
                      ? null
                      : () => _startSophonDownload(build),
                  icon: _starting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download),
                  label: Text(_starting ? '加载清单...' : '开始下载'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPackageMode(
    GamePackageResource resource,
    bool canSwitchToChunk,
  ) {
    return Column(
      children: [
        _modeBanner(
          title: '压缩包模式（兼容）',
          subtitle: '下载官方 zip 分卷；单个分卷校验失败时重下成本较高。',
          canSwitch: canSwitchToChunk,
        ),
        Expanded(
          child: ListView(
            children: [
              _sectionHeader(
                context,
                '游戏本体 v${resource.version}（${resource.gamePackages.length} 个分卷）',
              ),
              for (final file in resource.gamePackages) _fileTile(file),
              if (resource.audioPackages.isNotEmpty)
                _sectionHeader(context, '语音包（可选）'),
              for (final file in resource.audioPackages)
                _fileTile(file, subtitlePrefix: file.language),
            ],
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '已选 ${_selectedPackages.length} 个文件\n共 ${formatBytes(_selectedPackageSize)}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                FilledButton.icon(
                  onPressed: _selectedPackages.isEmpty
                      ? null
                      : () => _startPackageDownload(resource),
                  icon: const Icon(Icons.download),
                  label: const Text('开始下载'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _modeBanner({
    required String title,
    required String subtitle,
    required bool canSwitch,
  }) {
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: ListTile(
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: canSwitch
            ? TextButton(
                onPressed: () => setState(() => _useChunkMode = !_useChunkMode),
                child: Text(_useChunkMode ? '用压缩包' : '用 Chunk'),
              )
            : null,
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(title, style: Theme.of(context).textTheme.titleSmall),
    );
  }

  Widget _sophonSelectionActions(List<SophonManifestMeta> manifests) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: () => setState(() {
              _selectedCategoryIds.addAll(manifests.map((m) => m.categoryId));
            }),
            icon: const Icon(Icons.select_all),
            label: const Text('全选'),
          ),
          OutlinedButton.icon(
            onPressed: () => setState(_selectedCategoryIds.clear),
            icon: const Icon(Icons.deselect),
            label: const Text('全不选'),
          ),
        ],
      ),
    );
  }

  Widget _sophonGroupTile(SophonCategoryGroup group) {
    final selectedCount = group.manifests
        .where((m) => _selectedCategoryIds.contains(m.categoryId))
        .length;
    final checked = selectedCount == 0
        ? false
        : selectedCount == group.manifests.length
        ? true
        : null;
    return ExpansionTile(
      leading: Checkbox(
        value: checked,
        tristate: true,
        onChanged: (_) => _toggleSophonGroup(group),
      ),
      title: Text(group.title, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${group.manifests.length} 个分类 · ${formatBytes(group.compressedSize)} · '
        '${group.fileCount} 文件 / ${group.chunkCount} chunks',
      ),
      children: [
        for (final meta in group.manifests)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.only(left: 72, right: 16),
            title: Text(
              _sophonOriginalTitle(meta),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${meta.matchingField} · ${formatBytes(meta.compressedSize)} · '
              '${meta.fileCount} 文件 / ${meta.chunkCount} chunks',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }

  String _sophonOriginalTitle(SophonManifestMeta meta) {
    if (meta.displayName.trim().isNotEmpty) return meta.displayName;
    return meta.categoryId;
  }

  void _toggleSophonGroup(SophonCategoryGroup group) {
    final allSelected = group.manifests.every(
      (m) => _selectedCategoryIds.contains(m.categoryId),
    );
    setState(() {
      for (final meta in group.manifests) {
        if (allSelected) {
          _selectedCategoryIds.remove(meta.categoryId);
        } else {
          _selectedCategoryIds.add(meta.categoryId);
        }
      }
    });
  }

  Widget _fileTile(GamePackageFile file, {String? subtitlePrefix}) {
    final subtitle = [
      if (subtitlePrefix != null && subtitlePrefix.isNotEmpty) subtitlePrefix,
      formatBytes(file.size),
    ].join(' · ');
    return CheckboxListTile(
      value: _selectedPackages.contains(file),
      dense: true,
      title: Text(file.fileName, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle),
      onChanged: (checked) {
        setState(() {
          if (checked == true) {
            _selectedPackages.add(file);
          } else {
            _selectedPackages.remove(file);
          }
        });
      },
    );
  }
}

class _PackageData {
  const _PackageData({required this.package, required this.sophonBuild});

  final GamePackage? package;
  final SophonBuild? sophonBuild;
}
