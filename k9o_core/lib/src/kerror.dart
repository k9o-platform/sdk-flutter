/// Closed-taxonomy error thrown by every k9o_core operation.
///
/// Wire shape on non-2xx: flat JSON `{code, message, context, recommendation}`.
/// Never contains request bodies.
class KError implements Exception {
  final String code;
  final String message;
  final Map<String, dynamic> context;
  final String? recommendation;
  final int? status;
  final String? requestId;

  /// Seconds the gateway asks you to wait before retrying, when it says so.
  final double? retryAfterSec;

  KError({
    required this.code,
    required this.message,
    Map<String, dynamic>? context,
    this.recommendation,
    this.status,
    this.requestId,
    this.retryAfterSec,
  }) : context = Map.unmodifiable(context ?? const <String, dynamic>{});

  @override
  String toString() => 'KError($code): $message';
}
