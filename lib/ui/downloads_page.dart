import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../download/download_job.dart';
import '../download/download_manager.dart';
import 'format.dart';

/// Download management page: per-task progress, pause / resume / cancel.
class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final manager = context.watch<DownloadManager>();
    final tasks = manager.tasks;
    return Scaffold(
      appBar: AppBar(
        title: const Text('下载管理'),
        actions: [
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
      title: Text(task.displayName,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: task.progress,
            minHeight: 4,
            borderRadius: BorderRadius.circular(2),
          ),
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
          IconButton(
            tooltip: '取消',
            icon: const Icon(Icons.close),
            onPressed: task.status == DownloadStatus.completed ||
                    task.status == DownloadStatus.canceled
                ? null
                : () => manager.cancel(task),
          ),
        ],
      ),
    );
  }

  Widget _actionButton() {
    switch (task.status) {
      case DownloadStatus.downloading:
      case DownloadStatus.verifying:
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

  String _statusText(DownloadJob task) {
    switch (task.status) {
      case DownloadStatus.queued:
        return '排队中';
      case DownloadStatus.downloading:
        return '下载中 ${formatSpeed(task.speed)} · 剩余 ${formatEta(task.totalSize - task.receivedBytes, task.speed)}';
      case DownloadStatus.paused:
        return '已暂停';
      case DownloadStatus.verifying:
        return '校验中';
      case DownloadStatus.completed:
        return '已完成';
      case DownloadStatus.failed:
        return '失败：${task.error ?? '未知错误'}';
      case DownloadStatus.canceled:
        return '已取消';
    }
  }
}
