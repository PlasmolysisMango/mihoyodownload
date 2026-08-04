import 'dart:async';
import 'dart:math';

/// Global token-bucket rate limiter shared by all download tasks,
/// the counterpart of Starward's `RateLimiter.AcquireAsync` usage in
/// `GameInstallHelper`.
///
/// Tokens refill continuously at [bytesPerSecond]; the bucket holds at most
/// one second worth of burst. `acquire` debits the bucket and, when it goes
/// negative, sleeps just long enough for the refill to catch up — this keeps
/// the aggregate throughput of any number of concurrent tasks at the limit.
class RateLimiter {
  int _bytesPerSecond = 0; // 0 or less = unlimited
  double _tokens = 0;
  DateTime _lastRefill = DateTime.now();

  int get bytesPerSecond => _bytesPerSecond;

  /// Sets the limit in bytes/second; 0 disables limiting.
  void setLimit(int bytesPerSecond) {
    _bytesPerSecond = bytesPerSecond;
    // Start with a full one-second burst so transfers ramp up instantly.
    _tokens = bytesPerSecond.toDouble();
    _lastRefill = DateTime.now();
  }

  void _refill() {
    final now = DateTime.now();
    final elapsed = now.difference(_lastRefill).inMicroseconds / 1e6;
    _lastRefill = now;
    _tokens = min(
      _tokens + elapsed * _bytesPerSecond,
      _bytesPerSecond.toDouble(),
    );
  }

  /// Waits until [bytes] may pass under the current limit.
  Future<void> acquire(int bytes) async {
    if (_bytesPerSecond <= 0) return;
    _refill();
    _tokens -= bytes;
    if (_tokens < 0) {
      final waitMs = (-_tokens / _bytesPerSecond * 1000).ceil();
      await Future<void>.delayed(Duration(milliseconds: waitMs));
    }
  }
}
