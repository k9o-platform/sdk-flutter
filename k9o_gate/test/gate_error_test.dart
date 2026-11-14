import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:k9o_gate/k9o_gate.dart';

// The region is already known, so the client makes no region probe and calls the refresh route directly.
const _base = 'https://acme.api-us01.k9o.io';

GateClient _gate(http.Response Function(http.Request) answer, {String? errors}) => GateClient(
      orgBaseUrl: _base,
      projectSlug: 'test-project',
      tokenStore: _Store(),
      httpClient: MockClient((r) async => answer(r)),
      errors: errors ?? 'full',
    );

http.Response _json(int status, Object body, {Map<String, String> headers = const {}}) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json', ...headers},
    );

Future<GateError> _thrownBy(Future<Object?> Function() call) async {
  try {
    await call();
  } on GateError catch (e) {
    return e;
  }
  fail('expected a GateError');
}

Future<GateError> _refreshError(GateClient gate) => _thrownBy(() => gate.refreshToken(refreshToken: 'rt_test'));

class _Store implements TokenStore {
  String? _token;
  @override
  Future<void> save(String token) async => _token = token;
  @override
  Future<String?> load() async => _token;
  @override
  Future<void> delete() async => _token = null;
}

const _magicCode = 'K9O_MAGIC_LINK_REDIRECT_NOT_CONFIGURED';
const _magicBody = {
  'code': _magicCode,
  'message': 'x',
  'recommendation': {'action': 'Register a default redirect'},
};

void main() {
  group('unknown wire code', () {
    test('default mode keeps the full wire code, status, recommendation, request id and a 5xx publicMessage', () async {
      final gate = _gate((_) => _json(503, _magicBody, headers: {'x-k9o-request-id': 'req_abc'}));
      final e = await _refreshError(gate);
      expect(e.code, _magicCode);
      expect(e.status, 503);
      expect(e.message, 'x');
      expect(e.recommendation, 'Register a default redirect');
      expect(e.requestId, 'req_abc');
      expect(e.publicMessage, 'Something went wrong. Try again later.');
      expect(e.toString(), contains(_magicCode));
    });

    test('redacted mode gives the generic internal error and drops message, recommendation, context and body', () async {
      final body = {..._magicBody, 'context': {'region': 'de01'}};
      final gate = _gate((_) => _json(503, body, headers: {'x-k9o-request-id': 'req_abc'}), errors: 'redacted');
      final e = await _refreshError(gate);
      expect(e.code, 'INTERNAL_ERROR');
      expect(e.status, 503);
      expect(e.requestId, 'req_abc');
      expect(e.message, e.publicMessage);
      expect(e.recommendation, isNull);
      expect(e.context, isEmpty);
      expect(e.toString(), isNot(contains('Register a default redirect')));
      expect(e.toString(), isNot(contains(_magicCode)));
    });

    test('a 5xx without a request id header has a null requestId', () async {
      final gate = _gate((_) => _json(500, {'code': 'K9O_INTERNAL_ERROR', 'message': 'x'}));
      final e = await _refreshError(gate);
      expect(e.requestId, isNull);
      expect(e.code, 'K9O_INTERNAL_ERROR');
    });
  });

  group('known wire code', () {
    test('INVALID_CREDENTIALS keeps its code and status in both modes', () async {
      for (final mode in ['full', 'redacted']) {
        final gate = _gate(
          (_) => _json(401, {'code': 'K9O_INVALID_CREDENTIALS', 'message': 'Bad password', 'context': {}, 'recommendation': null}),
          errors: mode,
        );
        final e = await _refreshError(gate);
        expect(e, isA<GateError>(), reason: mode);
        expect(e.toString(), startsWith('GateError.invalidCredentials'), reason: mode);
        expect(e.code, 'INVALID_CREDENTIALS', reason: mode);
        expect(e.status, 401, reason: mode);
        expect(e.publicMessage, 'You are not signed in or not allowed to do this.', reason: mode);
      }
      final redacted = await _refreshError(_gate(
        (_) => _json(401, {'code': 'K9O_INVALID_CREDENTIALS', 'message': 'Bad password', 'context': {}, 'recommendation': null}),
        errors: 'redacted',
      ));
      expect(redacted.message, redacted.publicMessage);
      expect(redacted.toString(), isNot(contains('Bad password')));
    });

    test('a 429 keeps its retry hint in redacted mode', () async {
      final body = {
        'code': 'K9O_RATE_LIMITED',
        'message': 'slow down',
        'context': {'bucket': 'locate'},
        'recommendation': {'retryAfterSec': 30, 'note': 'Wait before retrying'},
      };
      final full = await _refreshError(_gate((_) => _json(429, body)));
      expect(full.code, 'RATE_LIMITED');
      expect(full.recommendation, 'Wait before retrying');
      expect(full.retryAfterSec, 30);

      final redacted = await _refreshError(_gate((_) => _json(429, body), errors: 'redacted'));
      expect(redacted.code, 'RATE_LIMITED');
      expect(redacted.retryAfterSec, 30);
      expect(redacted.recommendation, isNull);
      expect(redacted.context, isEmpty);
      expect(redacted.message, 'Too many attempts. Try again later.');
      expect(redacted.publicMessage, 'Too many attempts. Try again later.');
    });
  });

  group('errors option', () {
    test('an invalid value is refused with K9O_INVALID_FIELD_VALUE and the field', () {
      expect(
        () => _gate((_) => _json(200, {}), errors: 'partial'),
        throwsA(isA<K9OGateConfigError>()
            .having((e) => e.code, 'code', 'K9O_INVALID_FIELD_VALUE')
            .having((e) => e.context, 'context', {'field': 'errors', 'value': 'partial'})),
      );
    });
  });
}
