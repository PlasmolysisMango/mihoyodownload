import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../core/app_settings.dart';
import '../download/download_manager.dart';
import 'format.dart';

/// Speed limit presets in bytes/second; 0 = unlimited.
const _speedLimitOptions = [
  0,
  512 * 1024,
  1 * 1024 * 1024,
  2 * 1024 * 1024,
  5 * 1024 * 1024,
  10 * 1024 * 1024,
  20 * 1024 * 1024,
  50 * 1024 * 1024,
];

/// Settings page: choose the download directory (internal storage,
/// SD card or USB drives) with the system directory picker.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _busy = false;

  /// On Android 11+ "All files access" is required to write to paths
  /// outside the app sandbox (SD cards / USB OTG drives); older versions
  /// use the legacy storage permission instead.
  Future<bool> _ensureStoragePermission() async {
    if (!Platform.isAndroid) return true;
    if (await Permission.manageExternalStorage.request().isGranted) {
      return true;
    }
    return (await Permission.storage.request()).isGranted;
  }

  /// Probes the directory with a temp file: the picker may return paths
  /// (e.g. read-only mounts) that dart:io cannot actually write to.
  Future<bool> _isWritable(String dir) async {
    try {
      final probe = File(
        '$dir/.hoyo_write_test_${DateTime.now().millisecondsSinceEpoch}',
      );
      await probe.writeAsString('ok');
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _pickDirectory() async {
    final settings = context.read<AppSettings>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      if (!await _ensureStoragePermission()) {
        messenger.showSnackBar(
          const SnackBar(content: Text('未授予存储权限，无法写入外部存储')),
        );
        return;
      }
      final path = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择下载目录',
      );
      if (path == null) return; // user canceled
      if (!await _isWritable(path)) {
        messenger.showSnackBar(SnackBar(content: Text('该目录不可写入：$path')));
        return;
      }
      await settings.setDownloadDir(path);
      messenger.showSnackBar(SnackBar(content: Text('下载目录已设置为：$path')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resetDirectory() async {
    final settings = context.read<AppSettings>();
    await settings.setDownloadDir(null);
  }

  Future<void> _pickCacheDirectory() async {
    final settings = context.read<AppSettings>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      if (!await _ensureStoragePermission()) {
        messenger.showSnackBar(
          const SnackBar(content: Text('未授予存储权限，无法写入高速缓存目录')),
        );
        return;
      }
      final path = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择高速缓存目录',
      );
      if (path == null) return;
      if (!await _isWritable(path)) {
        messenger.showSnackBar(SnackBar(content: Text('该目录不可写入：$path')));
        return;
      }
      await settings.setCacheDir(path);
      messenger.showSnackBar(SnackBar(content: Text('高速缓存目录已设置为：$path')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resetCacheDirectory() async {
    final settings = context.read<AppSettings>();
    await settings.setCacheDir(null);
  }

  Future<void> _clearChunkCaches() async {
    final manager = context.read<DownloadManager>();
    final settings = context.read<AppSettings>();
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清理下载缓存'),
        content: const Text(
          '将删除当前高速缓存目录下的临时缓存，以及未运行任务的旧缓存。'
          '不会删除已下载的游戏文件，正在下载的任务缓存会保留。是否继续？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清理'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    try {
      final downloadDir = await settings.resolveDownloadDir();
      final count = await manager.clearChunkCaches(
        extraRoots: [settings.resolveChunkCacheDir(downloadDir)],
      );
      messenger.showSnackBar(
        SnackBar(content: Text(count == 0 ? '没有可清理的缓存' : '已清理 $count 个缓存目录')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('下载目录', style: Theme.of(context).textTheme.titleSmall),
          ),
          FutureBuilder<String>(
            future: settings.resolveDownloadDir(),
            builder: (context, snapshot) {
              return ListTile(
                leading: const Icon(Icons.folder),
                title: Text(snapshot.data ?? '...'),
                subtitle: Text(
                  settings.customDownloadDir == null ? '默认（应用私有目录）' : '自定义目录',
                ),
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : _pickDirectory,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('选择目录'),
                ),
                const SizedBox(width: 12),
                TextButton(
                  onPressed: settings.customDownloadDir == null
                      ? null
                      : _resetDirectory,
                  child: const Text('恢复默认'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('实验性功能', style: Theme.of(context).textTheme.titleSmall),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.science),
            title: const Text('启用 Chunk 模式'),
            subtitle: const Text('实验性功能。关闭时只使用压缩包模式，默认关闭。'),
            value: settings.experimentalChunkEnabled,
            onChanged: _busy ? null : settings.setExperimentalChunkEnabled,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.sd_storage),
            title: const Text('启用压缩包高速缓存下载'),
            subtitle: const Text('关闭时压缩包直接下载到下载目录；开启后先下载到高速缓存目录再复制。默认关闭。'),
            value: settings.packageCacheEnabled,
            onChanged: _busy ? null : settings.setPackageCacheEnabled,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              '高速缓存目录',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          FutureBuilder<String>(
            future: settings.resolveDownloadDir().then(
              settings.resolveChunkCacheDir,
            ),
            builder: (context, snapshot) {
              return ListTile(
                leading: const Icon(Icons.storage),
                title: Text(
                  settings.customCacheDir == null
                      ? '未设置'
                      : snapshot.data ?? '...',
                ),
                subtitle: Text(
                  settings.customCacheDir == null
                      ? '默认：Chunk 使用下载目录内缓存；压缩包直接写入下载目录'
                      : settings.packageCacheEnabled
                      ? '自定义目录，建议选择手机内置高速存储；压缩包会先下载到这里再复制到下载目录'
                      : '自定义目录，建议选择手机内置高速存储；压缩包缓存下载开关关闭，仍直接写入下载目录',
                ),
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : _pickCacheDirectory,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('选择缓存目录'),
                ),
                const SizedBox(width: 12),
                TextButton(
                  onPressed: settings.customCacheDir == null
                      ? null
                      : _resetCacheDirectory,
                  child: const Text('恢复默认'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _clearChunkCaches,
              icon: const Icon(Icons.cleaning_services),
              label: const Text('清理所有下载缓存'),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              '提示：\n'
              '• Android 上写入 SD 卡 / U 盘（OTG）需要授予“所有文件访问权限”。\n'
              '• Chunk 模式是实验性功能，需要在本页手动开启；默认使用压缩包模式。\n'
              '• 高速缓存目录建议放在手机内置高速存储，下载目录可继续放在 U 盘。\n'
              '• 压缩包高速缓存下载默认关闭；开启后才会先下载到缓存目录，校验通过后复制到下载目录。\n'
              '• 清理缓存会删除当前缓存目录和旧任务目录里的临时缓存，不会删除已下载的游戏文件，正在下载的任务缓存会保留。\n'
              '• 更改目录只影响之后新添加的任务，进行中的任务仍写入原目录。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('下载参数', style: Theme.of(context).textTheme.titleSmall),
          ),
          ListTile(
            leading: const Icon(Icons.dynamic_feed),
            title: const Text('同时下载任务数'),
            subtitle: const Text('调低不会中断已在进行的任务'),
            trailing: DropdownButton<int>(
              value: settings.maxConcurrent,
              items: [
                for (var i = 1; i <= 8; i++)
                  DropdownMenuItem(value: i, child: Text('$i')),
              ],
              onChanged: (value) {
                if (value == null) return;
                settings.setMaxConcurrent(value);
                // Apply immediately to the running queue.
                context.read<DownloadManager>().maxConcurrent = value;
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.speed),
            title: const Text('下载限速'),
            subtitle: const Text('所有任务共享的总速度上限'),
            trailing: DropdownButton<int>(
              value: _speedLimitOptions.contains(settings.speedLimitBytesPerSec)
                  ? settings.speedLimitBytesPerSec
                  : 0,
              items: [
                for (final bps in _speedLimitOptions)
                  DropdownMenuItem(
                    value: bps,
                    child: Text(bps == 0 ? '不限速' : formatSpeed(bps)),
                  ),
              ],
              onChanged: (value) {
                if (value == null) return;
                settings.setSpeedLimit(value);
                // Apply immediately to the running queue.
                context.read<DownloadManager>().setSpeedLimit(value);
              },
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              '高速缓存优化',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              '以下选项仅对配置了独立高速缓存目录的任务生效，默认关闭。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.fast_forward),
            title: const Text('Chunk 校验时预取下一个文件'),
            subtitle: const Text(
              '低风险：仅在当前 Chunk 任务内部提前下载下一个文件的分片到高速缓存，不改变最终文件写入顺序。',
            ),
            value: settings.sophonPrefetchDuringVerification,
            onChanged: _busy
                ? null
                : (value) {
                    settings.setSophonPrefetchDuringVerification(value);
                    context
                            .read<DownloadManager>()
                            .sophonPrefetchDuringVerification =
                        value;
                  },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.playlist_play),
            title: const Text('校验/复制时继续后续任务'),
            subtitle: const Text(
              '较高风险：当前任务校验或复制期间释放并发槽，让其他排队任务开始下载；可能增加高速缓存和最终存储的 I/O 压力。',
            ),
            value: settings.continueDownloadsDuringFinalization,
            onChanged: _busy
                ? null
                : (value) {
                    settings.setContinueDownloadsDuringFinalization(value);
                    context
                            .read<DownloadManager>()
                            .continueDownloadsDuringFinalization =
                        value;
                  },
          ),
        ],
      ),
    );
  }
}
