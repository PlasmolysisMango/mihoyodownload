/// Thrown when the miHoYo API returns a non-zero retcode,
/// ported from Starward's `miHoYoApiException`.
class ApiException implements Exception {
  const ApiException(this.retcode, this.message);

  final int retcode;
  final String message;

  @override
  String toString() => 'ApiException($retcode): $message';
}
