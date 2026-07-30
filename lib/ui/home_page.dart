import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/hoyoplay_client.dart';
import '../core/launcher_region.dart';
import '../download/download_manager.dart';
import '../download/download_task.dart';
import '../models/models.dart';
import 'downloads_page.dart';
import 'format.dart';
import 'package_page.dart';

/// Game list page: pick a server region, then a game to download.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  LauncherRegion _region = LauncherRegion.chinaOfficial;
  late Future<List<GameInfo>> _gamesFuture;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final client = context.read<HoYoPlayApiClient>();
    _gamesFuture = client.getGames(_region);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('HoYo Downloader'),
        actions: [
          _DownloadsButton(onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const DownloadsPage()),
            );
          }),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: SegmentedButton<LauncherRegion>(
              segments: [
                for (final region in LauncherRegion.values)
                  ButtonSegment(value: region, label: Text(region.displayName)),
              ],
              selected: {_region},
              onSelectionChanged: (selection) {
                setState(() {
                  _region = selection.first;
                  _load();
                });
              },
            ),
          ),
          Expanded(
            child: FutureBuilder<List<GameInfo>>(
              future: _gamesFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return _ErrorRetry(
                    message: '加载失败：${snapshot.error}',
                    onRetry: () => setState(_load),
                  );
                }
                final games = (snapshot.data ?? const <GameInfo>[])
                    .where((g) => g.isAvailable)
                    .toList();
                if (games.isEmpty) {
                  return const Center(child: Text('没有可下载的游戏'));
                }
                return RefreshIndicator(
                  onRefresh: () async => setState(_load),
                  child: ListView.builder(
                    itemCount: games.length,
                    itemBuilder: (context, index) =>
                        _GameTile(region: _region, game: games[index]),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _GameTile extends StatelessWidget {
  const _GameTile({required this.region, required this.game});

  final LauncherRegion region;
  final GameInfo game;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: game.iconUrl.isEmpty
            ? const SizedBox(width: 48, height: 48, child: Icon(Icons.games))
            : Image.network(
                game.iconUrl,
                width: 48,
                height: 48,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    const SizedBox(width: 48, height: 48, child: Icon(Icons.games)),
              ),
      ),
      title: Text(game.name),
      subtitle: Text(game.gameId.biz),
      trailing: const Icon(Icons.chevron_right),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => PackagePage(region: region, game: game),
          ),
        );
      },
    );
  }
}

/// Download entry button with a live total-progress badge.
class _DownloadsButton extends StatelessWidget {
  const _DownloadsButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final manager = context.watch<DownloadManager>();
    final downloading =
        manager.tasks.any((t) => t.status == DownloadStatus.downloading);
    return IconButton(
      tooltip: downloading
          ? '下载中 ${formatSpeed(manager.totalSpeed)}'
          : '下载管理',
      onPressed: onPressed,
      icon: Badge(
        isLabelVisible: manager.tasks.isNotEmpty,
        label: Text('${manager.tasks.length}'),
        child: Icon(downloading ? Icons.downloading : Icons.download),
      ),
    );
  }
}

class _ErrorRetry extends StatelessWidget {
  const _ErrorRetry({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(message, textAlign: TextAlign.center),
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
