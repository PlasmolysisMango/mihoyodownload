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
