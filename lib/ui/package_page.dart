import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_settings.dart';
import '../core/hoyoplay_client.dart';
import '../core/launcher_region.dart';
import '../download/download_manager.dart';
import '../models/models.dart';
import 'downloads_page.dart';
import 'format.dart';

/// Package selection page: choose game/audio package files of the latest
/// version and enqueue them for download.
class PackagePage extends StatefulWidget {
  const PackagePage({super.key, required this.region, required this.game});

  final LauncherRegion region;
  final GameInfo game;

  @override
  State<PackagePage> createState() => _PackagePageState();
}

class _PackagePageState extends State<PackagePage> {
  late Future<GamePackage?> _packageFuture;
  final Set<GamePackageFile> _selected = {};
  bool _initializedSelection = false;

  @override
  void initState() {
    super.initState();
    final client = context.read<HoYoPlayApiClient>();
    _packageFuture =
        client.getGamePackage(widget.region, widget.game.gameId);
  }

  int get _selectedSize => _selected.fold(0, (s, f) => s + f.size);

  void _initSelection(GamePackageResource resource) {
    if (_initializedSelection) return;
    _initializedSelection = true;
    // Game packages are required parts of the archive, check them by default.
    _selected.addAll(resource.gamePackages);
  }

  Future<void> _startDownload(GamePackageResource resource) async {
    final manager = context.read<DownloadManager>();
    final settings = context.read<AppSettings>();
    final navigator = Navigator.of(context);
    // Uses the directory chosen in settings (may be an external drive).
    final baseDir = await settings.resolveDownloadDir();
    final saveDir =
        '$baseDir/${widget.game.gameId.biz}_${resource.version}';
    manager.addPackageFiles(
      groupName: '${widget.game.name} ${resource.version}',
      saveDir: saveDir,
      files: _selected.toList(),
    );
    navigator.push(
      MaterialPageRoute(builder: (_) => const DownloadsPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.game.name)),
      body: FutureBuilder<GamePackage?>(
        future: _packageFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('加载失败：${snapshot.error}'));
          }
          final resource = snapshot.data?.main.major;
          if (resource == null) {
            return const Center(child: Text('该游戏暂无完整安装包（可能仅支持 Chunk 模式）'));
          }
          _initSelection(resource);
          return Column(
            children: [
              Expanded(
                child: ListView(
                  children: [
                    _sectionHeader(context,
                        '游戏本体 v${resource.version}（${resource.gamePackages.length} 个分卷）'),
                    for (final file in resource.gamePackages)
                      _fileTile(file),
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
                          '已选 ${_selected.length} 个文件\n共 ${formatBytes(_selectedSize)}',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                      FilledButton.icon(
                        onPressed: _selected.isEmpty
                            ? null
                            : () => _startDownload(resource),
                        icon: const Icon(Icons.download),
                        label: const Text('开始下载'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(title, style: Theme.of(context).textTheme.titleSmall),
    );
  }

  Widget _fileTile(GamePackageFile file, {String? subtitlePrefix}) {
    final subtitle = [
      if (subtitlePrefix != null && subtitlePrefix.isNotEmpty) subtitlePrefix,
      formatBytes(file.size),
    ].join(' · ');
    return CheckboxListTile(
      value: _selected.contains(file),
      dense: true,
      title: Text(file.fileName, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle),
      onChanged: (checked) {
        setState(() {
          if (checked == true) {
            _selected.add(file);
          } else {
            _selected.remove(file);
          }
        });
      },
    );
  }
}
