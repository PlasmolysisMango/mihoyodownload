import 'package:flutter_test/flutter_test.dart';
import 'package:hoyo_downloader/download/rate_limiter.dart';

void main() {
  test('unlimited limiter never waits', () async {
    final limiter = RateLimiter();
    final sw = Stopwatch()..start();
    for (var i = 0; i < 100; i++) {
      await limiter.acquire(1024 * 1024);
    }
    expect(sw.elapsedMilliseconds, lessThan(200));
  });

  test('limiter throttles to roughly the configured rate', () async {
    final limiter = RateLimiter()..setLimit(200 * 1024); // 200 KB/s
    // 300 KB total: the first ~200 KB burst is free, the remaining
    // ~100 KB must take about 0.5 s of refill time.
    final sw = Stopwatch()..start();
    for (var i = 0; i < 6; i++) {
      await limiter.acquire(50 * 1024);
    }
    sw.stop();
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(300));
    expect(sw.elapsedMilliseconds, lessThan(3000));
  });

  test('setLimit(0) disables an active limit', () async {
    final limiter = RateLimiter()..setLimit(1024);
    limiter.setLimit(0);
    final sw = Stopwatch()..start();
    await limiter.acquire(10 * 1024 * 1024);
    expect(sw.elapsedMilliseconds, lessThan(100));
  });
}
