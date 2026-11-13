
import 'dart:convert';

/// Raised by the [GateClient] constructor for a configuration that cannot name an org:
/// `K9O_INVALID_BASE_URL` (context `{field: 'baseUrl'}`) or `K9O_INVALID_FIELD_VALUE`
/// (context `{field: 'orgSlug', slug: <value>}`, or `{field: 'errors', value: <value>}`).
/// It is an [ArgumentError], so existing `on ArgumentError` handlers keep working; [GateError]
/// stays a closed set.
class K9OGateConfigError extends ArgumentError {
  final String code;
  final Map<String, Object?> context;

  K9OGateConfigError({
    required this.code,
    required String message,
    Map<String, Object?> context = const {},
  })  : context = Map.unmodifiable(context),
        super(message);

  @override
  String toString() => 'K9OGateConfigError($code): $message';
}

/// Closed error taxonomy for K9OGate SDK operations.
/// Maps the gateway KError wire codes to Dart exception subclasses.
///
/// [code], [status], [message], [recommendation], [context] and [requestId] are for logs. An app
/// shows [publicMessage] to its users and logs [requestId]. [retryAfterSec] is the number of
/// seconds the gateway asked the caller to wait, when it sent one.
sealed class GateError implements Exception {
  const GateError({
    this.code,
    this.status,
    String? message,
    this.recommendation,
    this.context = const {},
    this.requestId,
    this.retryAfterSec,
    this.sessionEndReason,
  }) : _message = message;

  /// Session token missing, expired, or revoked (HTTP 401).
  const factory GateError.unauthenticated() = _Unauthenticated;

  /// Caller lacks permission for the requested operation (HTTP 403).
  const factory GateError.forbidden() = _Forbidden;

  /// Email/password (or other credential) did not match (HTTP 401 INVALID_CREDENTIALS).
  const factory GateError.invalidCredentials() = _InvalidCredentials;

  /// The step that finds the email's region is rate-limited (HTTP 429). Safe to retry.
  const factory GateError.rateLimited(int statusCode, String? body) = _RateLimited;

  /// The region that holds the email is unavailable (HTTP 503). Safe to retry after the hint in the body.
  const factory GateError.regionUnavailable(int statusCode, String? body) = _RegionUnavailable;

  /// Transport-level failure — network unreachable, timeout, etc.
  const factory GateError.network(Object cause) = _NetworkError;

  /// Gateway response could not be parsed into the expected shape.
  const factory GateError.decoding(Object cause) = _DecodingError;

  /// Any other non-2xx HTTP status not covered above.
  const factory GateError.unknown(int statusCode, String? body) = _UnknownError;

  /// The wire code without its `K9O_` prefix for a code the client knows (for example
  /// `INVALID_CREDENTIALS`), or the full wire code for one it does not (for example
  /// `K9O_MAGIC_LINK_REDIRECT_NOT_CONFIGURED`). Null when the gateway sent no code.
  final String? code;

  /// HTTP status the gateway returned. Null for a failure before any response (network, or a
  /// 2xx body that cannot be decoded).
  final int? status;

  final String? _message;

  /// The gateway's message, or [publicMessage] when the gateway sent none. For logs.
  String get message => _message ?? publicMessage;

  /// A fixed sentence chosen by status class only, never the gateway's text. Show this to your users.
  String get publicMessage => _publicMessageFor(status);

  /// The gateway's recommendation: its string, or the `action` (else the `note`) of its object.
  /// Null when there is none. For logs.
  final String? recommendation;

  /// The gateway's structured payload for the code. For logs.
  final Map<String, Object?> context;

  /// The `x-k9o-request-id` response header, when the gateway sent one.
  final String? requestId;

  /// Seconds the gateway asked the caller to wait (`recommendation.retryAfterSec`), when it sent one.
  final num? retryAfterSec;

  /// Why the gateway ended the session (`K9O_SESSION_EXPIRED`): `inactive`, `max_length`, `revoked` or
  /// `replay`. Null for any other error. Kept when redacted. The user must sign in again.
  final String? sessionEndReason;
}

const _sessionEndReasons = {'inactive', 'max_length', 'revoked', 'replay'};

/// The code a redacted unknown error carries: the same generic internal error the TypeScript client uses.
const String _internalErrorCode = 'INTERNAL_ERROR';

final class _Unauthenticated extends GateError {
  const _Unauthenticated({
    String code = 'UNAUTHENTICATED',
    int? status,
    String? message,
    String? recommendation,
    Map<String, Object?> context = const {},
    String? requestId,
    num? retryAfterSec,
    String? sessionEndReason,
  }) : super(
          code: code,
          status: status,
          message: message,
          recommendation: recommendation,
          context: context,
          requestId: requestId,
          retryAfterSec: retryAfterSec,
          sessionEndReason: sessionEndReason,
        );
  @override
  String get publicMessage => _publicMessageFor(status ?? 401);
  @override
  String toString() => 'GateError.unauthenticated: Session expired or not authenticated.';
}

final class _Forbidden extends GateError {
  const _Forbidden({
    String code = 'FORBIDDEN',
    int? status,
    String? message,
    String? recommendation,
    Map<String, Object?> context = const {},
    String? requestId,
    num? retryAfterSec,
  }) : super(
          code: code,
          status: status,
          message: message,
          recommendation: recommendation,
          context: context,
          requestId: requestId,
          retryAfterSec: retryAfterSec,
        );
  @override
  String get publicMessage => _publicMessageFor(status ?? 403);
  @override
  String toString() => 'GateError.forbidden: Access forbidden for the current session.';
}

final class _InvalidCredentials extends GateError {
  const _InvalidCredentials({
    String code = 'INVALID_CREDENTIALS',
    int? status,
    String? message,
    String? recommendation,
    Map<String, Object?> context = const {},
    String? requestId,
    num? retryAfterSec,
  }) : super(
          code: code,
          status: status,
          message: message,
          recommendation: recommendation,
          context: context,
          requestId: requestId,
          retryAfterSec: retryAfterSec,
        );
  @override
  String get publicMessage => _publicMessageFor(status ?? 401);
  @override
  String toString() => 'GateError.invalidCredentials: Invalid credentials.';
}

final class _RateLimited extends GateError {
  final String? body;
  const _RateLimited(
    int statusCode,
    this.body, {
    String code = 'RATE_LIMITED',
    String? message,
    String? recommendation,
    Map<String, Object?> context = const {},
    String? requestId,
    num? retryAfterSec,
  }) : super(
          code: code,
          status: statusCode,
          message: message,
          recommendation: recommendation,
          context: context,
          requestId: requestId,
          retryAfterSec: retryAfterSec,
        );
  @override
  String toString() => 'GateError.rateLimited: Too many requests. Try again shortly.';
}

final class _RegionUnavailable extends GateError {
  final String? body;
  const _RegionUnavailable(
    int statusCode,
    this.body, {
    String code = 'GATE_REGION_UNAVAILABLE',
    String? message,
    String? recommendation,
    Map<String, Object?> context = const {},
    String? requestId,
    num? retryAfterSec,
  }) : super(
          code: code,
          status: statusCode,
          message: message,
          recommendation: recommendation,
          context: context,
          requestId: requestId,
          retryAfterSec: retryAfterSec,
        );
  @override
  String toString() => 'GateError.regionUnavailable: The region is unavailable. Try again shortly.';
}

final class _NetworkError extends GateError {
  final Object cause;
  const _NetworkError(this.cause);
  @override
  String get publicMessage => 'Could not reach the service.';
  @override
  String toString() => 'GateError.network: $cause';
}

final class _DecodingError extends GateError {
  final Object cause;
  const _DecodingError(this.cause);
  @override
  String toString() => 'GateError.decoding: $cause';
}

final class _UnknownError extends GateError {
  final String? body;
  const _UnknownError(
    int statusCode,
    this.body, {
    String? code,
    String? message,
    String? recommendation,
    Map<String, Object?> context = const {},
    String? requestId,
    num? retryAfterSec,
  }) : super(
          code: code,
          status: statusCode,
          message: message,
          recommendation: recommendation,
          context: context,
          requestId: requestId,
          retryAfterSec: retryAfterSec,
        );
  @override
  String toString() => 'GateError.unknown: HTTP $status — ${body ?? '<no body>'}';
}

/// The fixed public sentence for a status class. Never built from the gateway's text.
String _publicMessageFor(int? status) {
  if (status == 401 || status == 403) return 'You are not signed in or not allowed to do this.';
  if (status == 404) return 'Not found.';
  if (status == 429) return 'Too many attempts. Try again later.';
  if (status != null && status >= 500 && status <= 599) return 'Something went wrong. Try again later.';
  return 'The request could not be completed.';
}

// MARK: — Wire error parsing

/// Maps a non-2xx answer to a [GateError]. With [redacted], an unknown code becomes the generic
/// internal error, and a known code loses its message, recommendation, context and raw body but
/// keeps its code, status, request id and retry hint.
GateError gateErrorFromResponse(
  int statusCode,
  String? body, {
  String? requestId,
  bool redacted = false,
}) {
  if (body != null) {
    try {
      final Map<String, dynamic> json = jsonDecode(body) as Map<String, dynamic>;
      // The gateway emits a KError at the ROOT: { code, message, … }
      // with K9O_-prefixed codes — NOT wrapped in { error: … }. Strip the
      // prefix to match the typed cases.
      final rawCode = json['code'] as String?;
      final code = (rawCode != null && rawCode.startsWith('K9O_'))
          ? rawCode.substring(4)
          : rawCode;
      final rawMessage = json['message'];
      final message = rawMessage is String ? rawMessage : null;
      final rawContext = json['context'];
      final context = rawContext is Map<String, dynamic>
          ? Map<String, Object?>.unmodifiable(rawContext)
          : const <String, Object?>{};
      final recommendation = _decodeRecommendation(json['recommendation']);

      final keptMessage = redacted ? null : message;
      final keptRecommendation = redacted ? null : recommendation.text;
      final keptContext = redacted ? const <String, Object?>{} : context;
      final keptBody = redacted ? null : body;
      switch (code) {
        case 'UNAUTHENTICATED':
        case 'SESSION_EXPIRED':
        case 'MISSING_TOKEN':
          // The reason is one of four fixed words, so it is kept in both modes.
          final reason = code == 'SESSION_EXPIRED' ? context['reason'] : null;
          return _Unauthenticated(
            code: code!,
            status: statusCode,
            message: keptMessage,
            recommendation: keptRecommendation,
            context: keptContext,
            requestId: requestId,
            retryAfterSec: recommendation.retryAfterSec,
            sessionEndReason:
                reason is String && _sessionEndReasons.contains(reason) ? reason : null,
          );
        case 'FORBIDDEN':
          return _Forbidden(
            code: code!,
            status: statusCode,
            message: keptMessage,
            recommendation: keptRecommendation,
            context: keptContext,
            requestId: requestId,
            retryAfterSec: recommendation.retryAfterSec,
          );
        case 'INVALID_CREDENTIALS':
          return _InvalidCredentials(
            code: code!,
            status: statusCode,
            message: keptMessage,
            recommendation: keptRecommendation,
            context: keptContext,
            requestId: requestId,
            retryAfterSec: recommendation.retryAfterSec,
          );
        case 'RATE_LIMITED':
          return _RateLimited(
            statusCode,
            keptBody,
            code: code!,
            message: keptMessage,
            recommendation: keptRecommendation,
            context: keptContext,
            requestId: requestId,
            retryAfterSec: recommendation.retryAfterSec,
          );
        case 'GATE_REGION_UNAVAILABLE':
          return _RegionUnavailable(
            statusCode,
            keptBody,
            code: code!,
            message: keptMessage,
            recommendation: keptRecommendation,
            context: keptContext,
            requestId: requestId,
            retryAfterSec: recommendation.retryAfterSec,
          );
      }
      // Not a code the client knows: it keeps the wire code (or, redacted, the generic internal error).
      return _UnknownError(
        statusCode,
        keptBody,
        code: redacted ? _internalErrorCode : rawCode,
        message: keptMessage,
        recommendation: keptRecommendation,
        context: keptContext,
        requestId: requestId,
        retryAfterSec: redacted ? null : recommendation.retryAfterSec,
      );
    } catch (_) {}
  }
  return _UnknownError(
    statusCode,
    redacted ? null : body,
    code: redacted ? _internalErrorCode : null,
    requestId: requestId,
  );
}

/// Reads the wire `recommendation`: a string is kept; an object gives its `action`, else its
/// `note`, when that is a string. `retryAfterSec` is the object's number when it is finite and not negative.
({String? text, num? retryAfterSec}) _decodeRecommendation(Object? raw) {
  if (raw is String) return (text: raw, retryAfterSec: null);
  if (raw is! Map<String, dynamic>) return (text: null, retryAfterSec: null);
  final action = raw['action'];
  final note = raw['note'];
  final text = action is String ? action : (note is String ? note : null);
  final n = raw['retryAfterSec'];
  final retryAfterSec = n is num && n.isFinite && n >= 0 ? n : null;
  return (text: text, retryAfterSec: retryAfterSec);
}
