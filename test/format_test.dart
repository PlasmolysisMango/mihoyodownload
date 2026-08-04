import 'package:flutter_test/flutter_test.dart';
import 'package:hoyo_downloader/ui/format.dart';

void main() {
  test('formatEta handles common remaining time ranges', () {
    expect(formatEta(0, 100), '已完成');
    expect(formatEta(100, 0), '计算中');
    expect(formatEta(150, 100), '2秒');
    expect(formatEta(60 * 1024, 1024), '1分钟');
    expect(formatEta(90 * 1024, 1024), '1分30秒');
    expect(formatEta(2 * 60 * 60 * 1024, 1024), '2小时');
    expect(formatEta((26 * 60 * 60 * 1024), 1024), '1天2小时');
  });
}
