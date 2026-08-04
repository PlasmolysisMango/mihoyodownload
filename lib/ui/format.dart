/// Formats a byte count as a human readable string, the counterpart of
/// Starward's `ByteLengthToStringConverter`.
String formatBytes(num bytes) {
  if (bytes < 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  double value = bytes.toDouble();
  int unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return unit == 0
      ? '${value.toStringAsFixed(0)} ${units[unit]}'
      : '${value.toStringAsFixed(2)} ${units[unit]}';
}

/// Formats bytes-per-second as a speed string.
String formatSpeed(num bytesPerSecond) => '${formatBytes(bytesPerSecond)}/s';

/// Formats a remaining time estimate from bytes and current speed.
String formatEta(num remainingBytes, num bytesPerSecond) {
  if (remainingBytes <= 0) return '已完成';
  if (bytesPerSecond <= 0) return '计算中';
  final seconds = (remainingBytes / bytesPerSecond).ceil();
  if (seconds < 60) return '$seconds秒';
  final minutes = seconds ~/ 60;
  final sec = seconds % 60;
  if (minutes < 60) return sec == 0 ? '$minutes分钟' : '$minutes分$sec秒';
  final hours = minutes ~/ 60;
  final min = minutes % 60;
  if (hours < 24) return min == 0 ? '$hours小时' : '$hours小时$min分钟';
  final days = hours ~/ 24;
  final hour = hours % 24;
  return hour == 0 ? '$days天' : '$days天$hour小时';
}
