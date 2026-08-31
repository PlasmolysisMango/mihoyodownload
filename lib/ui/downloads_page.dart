import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../download/download_job.dart';
import '../download/download_manager.dart';
import 'format.dart';

/// Download management page: per-task progress, pause / resume / cancel.
class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key});

  Future<void> _loadTaskRecords(BuildContext context) async {
    final manager = context.read<DownloadManager>();
    final messenger = ScaffoldMessenger.of(context);
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择包含任务记录的下载目录',
    );
    if (path == null) return;
    final count = await manager.importTaskRecordsFromDirectory(path);
    messenger.showSnackBar(
      SnackBar(content: Text(count == 0 ? '未找到可载入的任务记录' : '已载入 $count 个下载任务')),
    );
  }

  Future<void> _removeAllTasks(BuildContext context) async {
    final manager = context.read<DownloadManager>();
    final choice = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除全部任务？'),
        content: const Text('可以只删除任务记录，或同时删除已下载文件和临时缓存。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('仅删除任务'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('任务和文件都删除'),
          ),
        ],
      ),
    );
    if (choice == null) return;
    await manager.removeAllTasks(deleteFiles: choice);
  }

  @override
  Widget build(BuildContext context) {
    final manager = context.watch<DownloadManager>();
    final tasks = manager.tasks;
    return Scaffold(
      appBar: AppBar(
        title: const Text('下载管理'),
        actions: [
          IconButton(
            tooltip: '载入任务记录',
            onPressed: () => _loadTaskRecords(context),
            icon: const Icon(Icons.drive_folder_upload),
          ),
          IconButton(
            tooltip: '全部暂停',
            onPressed: manager.pauseAll,
            icon: const Icon(Icons.pause),
          ),
          IconButton(
            tooltip: '全部开始',
            onPressed: manager.resumeAll,
            icon: const Icon(Icons.play_arrow),
          ),
          IconButton(
            tooltip: '删除全部任务',
            onPressed: tasks.isEmpty ? null : () => _removeAllTasks(context),
            icon: const Icon(Icons.delete_sweep),
          ),
          IconButton(
            tooltip: '清除已完成',
            onPressed: manager.removeFinished,
            icon: const Icon(Icons.clear_all),
          ),
        ],
      ),
      body: tasks.isEmpty
          ? const Center(child: Text('暂无下载任务'))
          : Column(
              children: [
                _TotalBar(manager: manager),
                Expanded(
                  child: ListView.builder(
                    itemCount: tasks.length,
                    itemBuilder: (context, index) =>
                        _TaskTile(manager: manager, task: tasks[index]),
                  ),
                ),
              ],
            ),
    );
  }
}

enum _TaskMenuAction { removeRecord, removeTaskAndFiles }

class _TotalBar extends StatelessWidget {
  const _TotalBar({required this.manager});

  final DownloadManager manager;

  @override
  Widget build(BuildContext context) {
    final total = manager.totalSize;
    final received = manager.receivedBytes;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LinearProgressIndicator(
            value: total <= 0 ? 0 : received / total,
            minHeight: 6,
            borderRadius: BorderRadius.circular(3),
          ),
          const SizedBox(height: 6),
          Text(
            '总进度 ${formatBytes(received)} / ${formatBytes(total)}'
            '   速度 ${formatSpeed(manager.totalSpeed)}'
            '   剩余 ${formatEta(total - received, manager.totalSpeed)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({required this.manager, required this.task});

  final DownloadManager manager;
  final DownloadJob task;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      isThreeLine: true,
      title: Text(
        task.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: task.progress,
            minHeight: 4,
            borderRadius: BorderRadius.circular(2),
          ),
          if (task.status == DownloadStatus.verifying) ...[
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: task.verificationProgress,
              minHeight: 3,
              borderRadius: BorderRadius.circular(2),
            ),
          ],
          if (task.status == DownloadStatus.publishing) ...[
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: task.publishingProgress,
              minHeight: 3,
              borderRadius: BorderRadius.circular(2),
            ),
          ],
          const SizedBox(height: 4),
          Text(
            '${task.groupName} · ${_statusText(task)}'
            ' · ${formatBytes(task.receivedBytes)} / ${formatBytes(task.totalSize)}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _actionButton(),
          PopupMenuButton<_TaskMenuAction>(
            tooltip: '任务操作',
            icon: const Icon(Icons.more_vert),
            onSelected: (value) => _handleMenuAction(context, value),
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: _TaskMenuAction.removeRecord,
                child: Text('仅删除任务'),
              ),
              PopupMenuItem(
                value: _TaskMenuAction.removeTaskAndFiles,
                child: Text('删除任务和文件'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _actionButton() {
    switch (task.status) {
      case DownloadStatus.downloading:
      case DownloadStatus.verifying:
      case DownloadStatus.publishing:
        return IconButton(
          tooltip: '暂停',
          icon: const Icon(Icons.pause),
          onPressed: () => manager.pause(task),
        );
      case DownloadStatus.paused:
      case DownloadStatus.failed:
        return IconButton(
          tooltip: '继续',
          icon: const Icon(Icons.play_arrow),
          onPressed: () => manager.resume(task),
        );
      case DownloadStatus.completed:
        return const IconButton(
          icon: Icon(Icons.check, color: Colors.green),
          onPressed: null,
        );
      case DownloadStatus.queued:
      case DownloadStatus.canceled:
        return const IconButton(
          icon: Icon(Icons.hourglass_empty),
          onPressed: null,
        );
    }
  }

  Future<void> _handleMenuAction(
    BuildContext context,
    _TaskMenuAction action,
  ) async {
    if (action == _TaskMenuAction.removeTaskAndFiles) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('删除任务和文件？'),
          content: Text('将删除“${task.displayName}”的任务记录、已下载文件和临时缓存。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('删除'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      await manager.removeTask(task, deleteFiles: true);
      return;
    }
    await manager.removeTask(task);
  }

  String _statusText(DownloadJob task) {
    switch (task.status) {
      case DownloadStatus.queued:
        return '排队中';
      case DownloadStatus.downloading:
        return '下载中 ${formatSpeed(task.speed)} · 剩余 ${formatEta(task.totalSize - task.receivedBytes, task.speed)}';
      case DownloadStatus.paused:
        return '已暂停';
      case DownloadStatus.verifying:
        return '校验中 ${(task.verificationProgress * 100).clamp(0, 100).toStringAsFixed(1)}%';
      case DownloadStatus.publishing:
        if (task.isPublishingFinalizing) {
          return '复制收尾中 · 速度 ${formatSpeed(task.speed)}';
        }
        return '复制中 ${(task.publishingProgress * 100).clamp(0, 100).toStringAsFixed(1)}% · 速度 ${formatSpeed(task.speed)}';
      case DownloadStatus.completed:
        return '已完成';
      case DownloadStatus.failed:
        return '失败：${task.error ?? '未知错误'}';
      case DownloadStatus.canceled:
        return '已取消';
    }
  }
}
