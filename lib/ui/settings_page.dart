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
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              '提示：\n'
              '• Android 上写入 SD 卡 / U 盘（OTG）需要授予“所有文件访问权限”。\n'
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
        ],
      ),
    );
  }
}
