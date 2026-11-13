import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:k9o_gate/k9o_gate.dart';

// MARK: - Test helpers

String authResultJson() => jsonEncode({
      'data': {
        'user': {
          'id': 'eu_TestUserABC123',
          'email': 'user@example.com',
          'status': 'active',
          'createdAt': '2026-01-01T00:00:00Z',
          'updatedAt': null,
          'lastSigninAt': null,
          'roles': ['PROJECT_END_USER'],
          'groups': [],
        },
        'session': {
          'accessToken':
              'eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJldV9UZXN0VXNlckFCQzEyMyIsImV4cCI6OTk5OTk5OTk5OSwiaWF0IjoxNzAwMDAwMDAwLCJpc3MiOiJodHRwczovL2FwaS5rOW8uaW8iLCJleHQucGFydG5lcnMiOnsicGFydG5lcl9yb2xlIjoiZXh0ZW5zaW9uX29yZ19hZG1pbiJ9fQ.sig',
          'refreshToken': 'rt_MockRefreshToken0001',
          'expiresAt': '2099-01-01T00:00:00Z',
        },
      },
      'meta': {},
    });

String errorJson(String code) =>
    jsonEncode({'code': code, 'message': 'Error', 'context': {}, 'recommendation': null});

class InMemoryTokenStore implements TokenStore {
  String? _token;
  @override
  Future<void> save(String token) async => _token = token;
  @override
  Future<String?> load() async => _token;
  @override
  Future<void> delete() async => _token = null;
}

String refreshJson() => jsonEncode({
      'data': {
        'accessToken': 'access.jwt.value',
        'refreshToken': 'rt_NextToken0002',
        'expiresAt': '2099-01-01T00:00:00Z',
      },
      'meta': {},
    });

String sessionExpiredJson(String reason) => jsonEncode({
      'code': 'K9O_SESSION_EXPIRED',
      'message': 'x',
      'context': {'reason': reason},
      'recommendation': null,
    });

/// Answers the region probe (a credential-free HEAD) and the locate door itself, so [inner] only sees the API calls
/// after them (locate_test.dart covers the door).
class _NoProbe extends http.BaseClient {
  _NoProbe(this.inner);
  final http.Client inner;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method == 'HEAD') {
      return http.StreamedResponse(const Stream.empty(), 200);
    }
    if (request.url.path.endsWith('/gate/locate')) {
      return http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode({
          'data': {'region': 'de01', 'origin': null},
          'meta': {},
        }))),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return inner.send(request);
  }
}

GateClient makeGate({
  required http.Client httpClient,
  InMemoryTokenStore? store,
}) =>
    GateClient(
      orgBaseUrl: 'https://acme.api.k9o.io',
      projectSlug: 'test-project',
      tokenStore: store ?? InMemoryTokenStore(),
      httpClient: _NoProbe(httpClient),
    );

void main() {
  // MARK: signIn
  test('signIn posts email and password only and returns user and session', () async {
    http.Request? captured;
    final client = MockClient((req) async {
      captured = req;
      return http.Response(authResultJson(), 200, headers: {'content-type': 'application/json'});
    });
    final gate = makeGate(httpClient: client);
    final result = await gate.signIn(email: 'user@example.com', password: 'pass');
    expect(captured!.method, 'POST');
    expect(captured!.url.toString(), 'https://acme.api.k9o.io/@test-project/gate/signin');
    expect(jsonDecode(captured!.body), {'email': 'user@example.com', 'password': 'pass'});
    expect(result.user.id, 'eu_TestUserABC123');
    expect(result.user.email, 'user@example.com');
    expect(result.user.createdAt, '2026-01-01T00:00:00Z');
    expect(result.session.refreshToken, 'rt_MockRefreshToken0001');
    expect(result.session.expiresAt, '2099-01-01T00:00:00Z');
  });

  test('signIn persists refresh token to store', () async {
    final store = InMemoryTokenStore();
    final client = MockClient((_) async =>
        http.Response(authResultJson(), 200, headers: {'content-type': 'application/json'}));
    final gate = makeGate(httpClient: client, store: store);
    await gate.signIn(email: 'user@example.com', password: 'pass');
    expect(await store.load(), 'rt_MockRefreshToken0001');
  });

  // MARK: refreshToken
  test('refreshToken parses the result and stores the next refresh token', () async {
    final store = InMemoryTokenStore();
    await store.save('rt_InitialToken');
    http.Request? captured;
    final client = MockClient((req) async {
      captured = req;
      return http.Response(refreshJson(), 200, headers: {'content-type': 'application/json'});
    });
    final gate = makeGate(httpClient: client, store: store);
    final result = await gate.refreshToken();
    expect(captured!.method, 'POST');
    expect(captured!.url.toString(), 'https://acme.api.k9o.io/@test-project/gate/refresh');
    // The body is closed to {refreshToken}: the gateway refuses any other field.
    expect(jsonDecode(captured!.body), {'refreshToken': 'rt_InitialToken'});
    expect(result.accessToken, 'access.jwt.value');
    expect(result.expiresAt, '2099-01-01T00:00:00Z');
    expect(result.refreshToken, 'rt_NextToken0002');
    expect(await store.load(), 'rt_NextToken0002');
  });

  test('refreshToken with a token that is not the stored one leaves the store alone', () async {
    final store = InMemoryTokenStore();
    await store.save('rt_Stored');
    final client = MockClient((req) async => http.Response(refreshJson(), 200, headers: {'content-type': 'application/json'}));
    final gate = makeGate(httpClient: client, store: store);
    await gate.refreshToken(refreshToken: 'rt_Other');
    expect(await store.load(), 'rt_Stored');
  });

  test('concurrent refreshes share one request and the next refresh sends the stored next token', () async {
    final store = InMemoryTokenStore();
    await store.save('rt_Initial');
    final sent = <String>[];
    final release = Completer<void>();
    final client = MockClient((req) async {
      sent.add((jsonDecode(req.body) as Map)['refreshToken'] as String);
      await release.future;
      return http.Response(refreshJson(), 200, headers: {'content-type': 'application/json'});
    });
    final gate = makeGate(httpClient: client, store: store);
    final calls = [gate.refreshToken(), gate.refreshToken(), gate.refreshToken()];
    release.complete();
    final results = await Future.wait(calls);
    expect(results.every((r) => r.refreshToken == 'rt_NextToken0002'), isTrue);
    expect(sent, ['rt_Initial']);
    await gate.refreshToken();
    expect(sent, ['rt_Initial', 'rt_NextToken0002']);
  });

  test('signOut waits for a refresh in flight and signs out the next token', () async {
    final store = InMemoryTokenStore();
    await store.save('rt_Initial');
    final sent = <String>[];
    final release = Completer<void>();
    final client = MockClient((req) async {
      sent.add((jsonDecode(req.body) as Map)['refreshToken'] as String);
      if (req.url.path.endsWith('/refresh')) {
        await release.future;
        return http.Response(refreshJson(), 200, headers: {'content-type': 'application/json'});
      }
      return http.Response(jsonEncode({'data': {'revoked': true}, 'meta': {}}), 200, headers: {'content-type': 'application/json'});
    });
    final gate = makeGate(httpClient: client, store: store);
    final refreshing = gate.refreshToken();
    final signingOut = gate.signOut();
    release.complete();
    await Future.wait([refreshing, signingOut]);
    expect(sent, ['rt_Initial', 'rt_NextToken0002']);
    expect(await store.load(), isNull);
  });

  for (final reason in ['replay', 'revoked', 'inactive', 'max_length']) {
    test('a session that ended ($reason) clears the store and exposes the reason', () async {
      final store = InMemoryTokenStore();
      await store.save('rt_Old');
      final client = MockClient((req) async => http.Response(sessionExpiredJson(reason), 401, headers: {'content-type': 'application/json'}));
      final gate = makeGate(httpClient: client, store: store);
      await expectLater(
        gate.refreshToken(),
        throwsA(isA<GateError>().having((e) => e.sessionEndReason, 'sessionEndReason', reason).having((e) => e.status, 'status', 401)),
      );
      expect(await store.load(), isNull);
    });
  }

  test('an unknown refresh token clears the store', () async {
    final store = InMemoryTokenStore();
    await store.save('rt_Unknown');
    final client = MockClient((req) async => http.Response(errorJson('K9O_INVALID_CREDENTIALS'), 401, headers: {'content-type': 'application/json'}));
    final gate = makeGate(httpClient: client, store: store);
    await expectLater(gate.refreshToken(), throwsA(isA<GateError>()));
    expect(await store.load(), isNull);
  });

  test('a network failure keeps the stored token', () async {
    final store = InMemoryTokenStore();
    await store.save('rt_Keep');
    final client = MockClient((req) async => throw const SocketException('offline'));
    final gate = makeGate(httpClient: client, store: store);
    await expectLater(gate.refreshToken(), throwsA(isA<GateError>()));
    expect(await store.load(), 'rt_Keep');
  });

  test('sessionEndReason is kept when errors are redacted and null for other errors', () async {
    final store = InMemoryTokenStore();
    await store.save('rt_Old');
    final client = MockClient((req) async => http.Response(sessionExpiredJson('replay'), 401, headers: {'content-type': 'application/json'}));
    final gate = GateClient(
      orgBaseUrl: 'https://acme.api.k9o.io',
      projectSlug: 'test-project',
      tokenStore: store,
      httpClient: _NoProbe(client),
      errors: 'redacted',
    );
    await expectLater(
      gate.refreshToken(),
      throwsA(isA<GateError>().having((e) => e.sessionEndReason, 'sessionEndReason', 'replay').having((e) => e.context, 'context', isEmpty)),
    );
    expect(const GateError.unauthenticated().sessionEndReason, isNull);
  });

  test('refreshToken uses explicit token over store', () async {
    final store = InMemoryTokenStore();
    await store.save('rt_ShouldNotBeUsed');
    http.Request? captured;
    final client = MockClient((req) async {
      captured = req;
      return http.Response(refreshJson(), 200, headers: {'content-type': 'application/json'});
    });
    final gate = makeGate(httpClient: client, store: store);
    await gate.refreshToken(refreshToken: 'rt_Explicit');
    expect(jsonDecode(captured!.body), {'refreshToken': 'rt_Explicit'});
  });

  // MARK: signOut
  test('signOut sends the refresh token, reports revoked and clears the store', () async {
    final store = InMemoryTokenStore();
    await store.save('rt_ToRevoke');
    http.Request? captured;
    final client = MockClient((req) async {
      captured = req;
      return http.Response(
          jsonEncode({'data': {'revoked': true}, 'meta': {}}), 200);
    });
    final gate = makeGate(httpClient: client, store: store);
    expect(await gate.signOut(), isTrue);
    expect(captured!.method, 'POST');
    expect(captured!.url.toString(), 'https://acme.api.k9o.io/@test-project/gate/signout');
    expect(jsonDecode(captured!.body), {'refreshToken': 'rt_ToRevoke'});
    expect(await store.load(), isNull);
  });

  test('signOut of an unknown token returns false and still clears the store', () async {
    final store = InMemoryTokenStore();
    await store.save('rt_Unknown');
    final client = MockClient((_) async =>
        http.Response(jsonEncode({'data': {'revoked': false}, 'meta': {}}), 200));
    final gate = makeGate(httpClient: client, store: store);
    expect(await gate.signOut(), isFalse);
    expect(await store.load(), isNull);
  });

  test('signOut is no-op when no token', () async {
    int callCount = 0;
    final client = MockClient((_) async {
      callCount++;
      return http.Response('{}', 200);
    });
    final gate = makeGate(httpClient: client);
    expect(await gate.signOut(), isFalse);
    expect(callCount, 0);
  });

  // MARK: revokeAllSessions
  test('revokeAllSessions posts with the access token, returns the count and clears the store', () async {
    final store = InMemoryTokenStore();
    await store.save('rt_ToRevoke');
    http.Request? captured;
    final client = MockClient((req) async {
      captured = req;
      return http.Response(jsonEncode({'data': {'revokedCount': 3}, 'meta': {}}), 200);
    });
    final gate = makeGate(httpClient: client, store: store);
    expect(await gate.revokeAllSessions(accessToken: 'access.jwt.value'), 3);
    expect(captured!.method, 'POST');
    expect(captured!.url.toString(), 'https://acme.api.k9o.io/@test-project/auth/sessions/revoke-all');
    expect(captured!.headers['authorization'], 'Bearer access.jwt.value');
    expect(captured!.body, isEmpty);
    expect(await store.load(), isNull);
  });

  for (final code in ['K9O_TRUST_ZONE_VIOLATION', 'K9O_PROJECT_SCOPE_MISMATCH']) {
    test('revokeAllSessions refused with $code is a GateError and keeps the store', () async {
      final store = InMemoryTokenStore();
      await store.save('rt_Keep');
      final client = MockClient((_) async => http.Response(errorJson(code), 403));
      final gate = makeGate(httpClient: client, store: store);
      await expectLater(
        gate.revokeAllSessions(accessToken: 'operator.token'),
        throwsA(isA<GateError>()
            .having((e) => e.code, 'code', code)
            .having((e) => e.status, 'status', 403)),
      );
      expect(await store.load(), 'rt_Keep');
    });
  }

  // MARK: Error cases
  test('signIn throws GateError.invalidCredentials on 401 INVALID_CREDENTIALS', () async {
    final client = MockClient((_) async =>
        http.Response(errorJson('K9O_INVALID_CREDENTIALS'), 401));
    final gate = makeGate(httpClient: client);
    expect(
      () => gate.signIn(email: 'bad@example.com', password: 'wrong'),
      throwsA(isA<GateError>()),
    );
  });

  test('refreshToken throws GateError.unauthenticated when no token in store', () async {
    final client = MockClient((_) async => http.Response('{}', 200));
    final gate = makeGate(httpClient: client);
    expect(
      () => gate.refreshToken(),
      throwsA(isA<GateError>()),
    );
  });

  test('non-JSON 200 response throws GateError.decoding', () async {
    final client = MockClient((_) async => http.Response('not-json', 200));
    final gate = makeGate(httpClient: client);
    expect(
      () => gate.signIn(email: 'u@e.com', password: 'p'),
      throwsA(isA<GateError>()),
    );
  });

  test('500 response maps to GateError.unknown', () async {
    final client = MockClient((_) async =>
        http.Response(errorJson('K9O_INTERNAL_ERROR'), 500));
    final gate = makeGate(httpClient: client);
    expect(
      () => gate.signIn(email: 'u@e.com', password: 'p'),
      throwsA(isA<GateError>()),
    );
  });

  // MARK: JWT / AccessToken decode
  test('AccessToken.decode reads flat custom claims', () {
    // Custom claims are FLAT keys ("ext.<namespace>.<name>"), not a nested object.
    final payload = base64Url.encode(utf8.encode(jsonEncode({
      'sub': 'eu_TestUserABC123',
      'exp': 9999999999,
      'iat': 1700000000,
      'iss': 'https://issuer.example',
      'ext.partners.partner_role': 'extension_org_admin',
    }))).replaceAll('=', '');
    final token = AccessToken.decode('eyJhbGciOiJFUzI1NiJ9.$payload.sig');
    expect(token, isNotNull);
    expect(token!.subject, 'eu_TestUserABC123');
    expect(token.issuer, 'https://issuer.example');
    expect(token.customClaims['ext.partners.partner_role'], 'extension_org_admin');
    expect(token.customClaim('partners', 'partner_role'), 'extension_org_admin');
    expect(token.customClaims.length, 1);
    expect(token.customClaim('partners', 'missing'), isNull);
  });

  test('AccessToken.decode returns null for malformed JWT', () {
    expect(AccessToken.decode('not.a.jwt.at.all.whatsoever'), isNull);
    expect(AccessToken.decode('only.two'), isNull);
    expect(AccessToken.decode(''), isNull);
  });
}
