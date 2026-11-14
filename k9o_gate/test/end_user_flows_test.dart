import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:k9o_gate/k9o_gate.dart';

// The end-user flow calls: passkeys, authenticator apps, password reset, invitations and the session check.
// Each test checks the path, method, headers and body that leave the client and the value that comes back.

class _Store implements TokenStore {
  String? token;
  @override
  Future<void> save(String t) async => token = t;
  @override
  Future<String?> load() async => token;
  @override
  Future<void> delete() async => token = null;
}

/// Answers the region probe and the locate door itself, so the handler under test only sees the flow calls.
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

const _base = 'https://acme.api.example.test/@test-project/gate';

GateClient _gate(MockClientHandler handler, [_Store? store]) => GateClient(
      orgBaseUrl: 'https://acme.api.example.test',
      projectSlug: 'test-project',
      tokenStore: store ?? _Store(),
      httpClient: _NoProbe(MockClient(handler)),
    );

http.Response _ok(Object data, [int status = 200]) => http.Response(
      jsonEncode({'data': data, 'meta': {}}),
      status,
      headers: {'content-type': 'application/json'},
    );

http.Response _err(int status, String code) => http.Response(
      jsonEncode({'code': code, 'message': 'x', 'context': {}, 'recommendation': null}),
      status,
      headers: {'content-type': 'application/json'},
    );

Map<String, dynamic> _session(String refresh) => {
      'accessToken': 'access.jwt.value',
      'refreshToken': refresh,
      'expiresAt': '2099-01-01T00:00:00Z',
    };

void main() {
  group('passkeys', () {
    test('beginPasskeyRegistration posts with the bearer and no body', () async {
      http.Request? req;
      final gate = _gate((r) async {
        req = r;
        return _ok({'challenge': 'ch1', 'rp': {'id': 'example.test'}});
      });
      final options = await gate.beginPasskeyRegistration(accessToken: 'eu.access');
      expect(req!.method, 'POST');
      expect(req!.url.toString(), '$_base/passkeys/register/begin');
      expect(req!.headers['authorization'], 'Bearer eu.access');
      expect(req!.body, '');
      expect(options.challenge, 'ch1');
      expect(options.raw['rp'], {'id': 'example.test'});
    });

    test('beginPasskeyRegistration without a token is refused with a GateError', () async {
      final gate = _gate((_) async => _err(401, 'UNAUTHENTICATED'));
      expect(
        () => gate.beginPasskeyRegistration(accessToken: ''),
        throwsA(isA<GateError>().having((e) => e.status, 'status', 401)),
      );
    });

    test('finishPasskeyRegistration sends the credential and the label', () async {
      http.Request? req;
      final gate = _gate((r) async {
        req = r;
        return _ok({'passkey': {'id': 'pk_1', 'credentialId': 'cred_1'}});
      });
      final result = await gate.finishPasskeyRegistration(
        accessToken: 'eu.access',
        response: {'id': 'cred_1', 'response': {'attestationObject': 'x'}},
        label: 'Phone',
      );
      expect(req!.url.toString(), '$_base/passkeys/register/finish');
      expect(req!.headers['authorization'], 'Bearer eu.access');
      expect(jsonDecode(req!.body), {
        'response': {'id': 'cred_1', 'response': {'attestationObject': 'x'}},
        'label': 'Phone',
      });
      expect(result.id, 'pk_1');
      expect(result.credentialId, 'cred_1');
    });

    test('finishPasskeyRegistration leaves the label out when none is given', () async {
      http.Request? req;
      final gate = _gate((r) async {
        req = r;
        return _ok({'passkey': {'id': 'pk_1', 'credentialId': 'cred_1'}});
      });
      await gate.finishPasskeyRegistration(
        accessToken: 'eu.access',
        response: {'id': 'cred_1', 'response': {}},
      );
      expect((jsonDecode(req!.body) as Map).containsKey('label'), isFalse);
    });

    test('finishPasskeyRegistration maps a refused credential to a 400 GateError', () async {
      final gate = _gate((_) async => _err(400, 'INVALID_FIELD_VALUE'));
      expect(
        () => gate.finishPasskeyRegistration(
          accessToken: 'eu.access',
          response: {'id': 'x', 'response': {}},
        ),
        throwsA(isA<GateError>().having((e) => e.status, 'status', 400)),
      );
    });

    test('beginPasskeySignIn sends no bearer and the email when given', () async {
      http.Request? req;
      final gate = _gate((r) async {
        req = r;
        return _ok({'challenge': 'ch2', 'allowCredentials': []});
      });
      final options = await gate.beginPasskeySignIn(email: 'user@example.test');
      expect(req!.url.toString(), '$_base/passkeys/signin/begin');
      expect(req!.headers.containsKey('authorization'), isFalse);
      expect(jsonDecode(req!.body), {'email': 'user@example.test'});
      expect(options.challenge, 'ch2');
    });

    test('beginPasskeySignIn without an email sends an empty object', () async {
      http.Request? req;
      final gate = _gate((r) async {
        req = r;
        return _ok({'challenge': 'ch2'});
      });
      await gate.beginPasskeySignIn();
      expect(jsonDecode(req!.body), {});
    });

    test('finishPasskeySignIn sends no bearer, returns the session and stores its refresh token', () async {
      final store = _Store();
      http.Request? req;
      final gate = _gate((r) async {
        req = r;
        return _ok({'session': _session('rt_Passkey0001')});
      }, store);
      final session = await gate.finishPasskeySignIn(
        response: {'id': 'cred_1', 'response': {'signature': 's'}},
      );
      expect(req!.url.toString(), '$_base/passkeys/signin/finish');
      expect(req!.headers.containsKey('authorization'), isFalse);
      expect(jsonDecode(req!.body), {
        'response': {'id': 'cred_1', 'response': {'signature': 's'}},
      });
      expect(session.refreshToken, 'rt_Passkey0001');
      expect(await store.load(), 'rt_Passkey0001');
    });

    test('finishPasskeySignIn leaves the store alone on a refusal', () async {
      final store = _Store()..token = 'rt_Old';
      final gate = _gate((_) async => _err(400, 'INVALID_FIELD_VALUE'), store);
      await expectLater(
        gate.finishPasskeySignIn(response: {'id': 'x', 'response': {}}),
        throwsA(isA<GateError>()),
      );
      expect(await store.load(), 'rt_Old');
    });
  });

  group('authenticator apps', () {
    test('enrollTotp posts the label with the bearer and returns the factor', () async {
      http.Request? req;
      final gate = _gate((r) async {
        req = r;
        return _ok({
          'factor': {'id': 'f_1', 'secret': 'JBSWY3DP', 'uri': 'otpauth://totp/x?secret=JBSWY3DP'},
        });
      });
      final enrollment = await gate.enrollTotp(accessToken: 'eu.access', label: 'Phone app');
      expect(req!.url.toString(), '$_base/mfa/totp/enroll');
      expect(req!.headers['authorization'], 'Bearer eu.access');
      expect(jsonDecode(req!.body), {'label': 'Phone app'});
      expect(enrollment.factorId, 'f_1');
      expect(enrollment.secret, 'JBSWY3DP');
      expect(enrollment.uri, startsWith('otpauth://'));
    });

    test('enrollTotp without a label sends an empty object', () async {
      http.Request? req;
      final gate = _gate((r) async {
        req = r;
        return _ok({'factor': {'id': 'f_1', 'secret': 's', 'uri': 'u'}});
      });
      await gate.enrollTotp(accessToken: 'eu.access');
      expect(jsonDecode(req!.body), {});
    });

    test('confirmTotp sends the factor and code and stores a new session when one is returned', () async {
      final store = _Store();
      http.Request? req;
      final gate = _gate((r) async {
        req = r;
        return _ok({
          'factor': {'id': 'f_1', 'verifiedAt': '2026-11-13T00:00:00Z'},
          'session': _session('rt_AfterTotp'),
        });
      }, store);
      final result = await gate.confirmTotp(accessToken: 'eu.access', factorId: 'f_1', code: '123456');
      expect(req!.url.toString(), '$_base/mfa/totp/confirm');
      expect(req!.headers['authorization'], 'Bearer eu.access');
      expect(jsonDecode(req!.body), {'factorId': 'f_1', 'code': '123456'});
      expect(result.factorId, 'f_1');
      expect(result.verifiedAt, '2026-11-13T00:00:00Z');
      expect(result.session!.refreshToken, 'rt_AfterTotp');
      expect(await store.load(), 'rt_AfterTotp');
    });

    test('confirmTotp passes currentCode and leaves the store alone when no session comes back', () async {
      final store = _Store()..token = 'rt_Keep';
      http.Request? req;
      final gate = _gate((r) async {
        req = r;
        return _ok({'factor': {'id': 'f_2', 'verifiedAt': '2026-11-13T00:00:00Z'}});
      }, store);
      final result = await gate.confirmTotp(
        accessToken: 'eu.access',
        factorId: 'f_2',
        code: '654321',
        currentCode: '111111',
      );
      expect(jsonDecode(req!.body), {'factorId': 'f_2', 'code': '654321', 'currentCode': '111111'});
      expect(result.session, isNull);
      expect(await store.load(), 'rt_Keep');
    });

    test('confirmTotp keeps the gateway code on a wrong code', () async {
      final gate = _gate((_) async => _err(401, 'INVALID_CREDENTIALS'));
      expect(
        () => gate.confirmTotp(accessToken: 'eu.access', factorId: 'f_1', code: '000000'),
        throwsA(isA<GateError>().having((e) => e.status, 'status', 401)),
      );
    });
  });

  group('mfa methods', () {
    test('listMfaMethods gets with the bearer and decodes the methods', () async {
      http.Request? req;
      final gate = _gate((r) async {
        req = r;
        return _ok({
          'methods': [
            {'id': 'eumf_1', 'type': 'totp', 'label': 'Phone app', 'verifiedAt': '2026-01-01T00:00:00.000Z', 'createdAt': '2025-12-31T00:00:00.000Z'},
            {'id': 'eumf_2', 'type': 'totp', 'label': null, 'verifiedAt': null, 'createdAt': '2026-01-02T00:00:00.000Z'},
          ],
        });
      });
      final methods = await gate.listMfaMethods(accessToken: 'eu.access');
      expect(req!.method, 'GET');
      expect(req!.url.toString(), '$_base/mfa/methods');
      expect(req!.headers['authorization'], 'Bearer eu.access');
      expect(methods.length, 2);
      expect(methods[0].id, 'eumf_1');
      expect(methods[0].type, 'totp');
      expect(methods[0].label, 'Phone app');
      expect(methods[0].verifiedAt, '2026-01-01T00:00:00.000Z');
      expect(methods[1].label, isNull);
      expect(methods[1].verifiedAt, isNull);
    });

    test('listMfaMethods returns an empty list', () async {
      final gate = _gate((_) async => _ok({'methods': []}));
      expect(await gate.listMfaMethods(accessToken: 'eu.access'), isEmpty);
    });

    test('listMfaMethods keeps the gateway code on a refused token', () async {
      final gate = _gate((_) async => _err(401, 'K9O_UNAUTHENTICATED'));
      expect(
        () => gate.listMfaMethods(accessToken: 'bad'),
        throwsA(isA<GateError>().having((e) => e.status, 'status', 401)),
      );
    });

    test('deleteMfaMethod sends DELETE with the bearer, the code and an encoded id', () async {
      http.Request? req;
      final gate = _gate((r) async {
        req = r;
        return _ok({'deleted': true});
      });
      final deleted = await gate.deleteMfaMethod(accessToken: 'eu.access', methodId: 'eumf_1', code: '123456');
      expect(req!.method, 'DELETE');
      expect(req!.url.toString(), '$_base/mfa/methods/eumf_1');
      expect(req!.headers['authorization'], 'Bearer eu.access');
      expect(jsonDecode(req!.body), {'code': '123456'});
      expect(deleted, isTrue);
    });

    test('deleteMfaMethod without a code sends no body and reports false when nothing matched', () async {
      http.Request? req;
      final gate = _gate((r) async {
        req = r;
        return _ok({'deleted': false});
      });
      final deleted = await gate.deleteMfaMethod(accessToken: 'eu.access', methodId: 'a/b');
      expect(req!.url.toString(), '$_base/mfa/methods/a%2Fb');
      expect(req!.body, isEmpty);
      expect(deleted, isFalse);
    });

    test('deleteMfaMethod keeps the gateway code when the current code is missing', () async {
      final gate = _gate((_) async => _err(403, 'K9O_MFA_REQUIRED'));
      expect(
        () => gate.deleteMfaMethod(accessToken: 'eu.access', methodId: 'eumf_1'),
        throwsA(isA<GateError>().having((e) => e.status, 'status', 403)),
      );
    });
  });

  group('password reset', () {
    test('requestPasswordReset sends the email without a bearer and returns the answer', () async {
      http.Request? req;
      final gate = _gate((r) async {
        req = r;
        return _ok({
          'reset': {'requested': true, 'expiresAt': '2026-11-13T01:00:00Z'},
          'debugToken': 'tok_dev',
        });
      });
      final result = await gate.requestPasswordReset(email: 'user@example.test');
      expect(req!.url.toString(), '$_base/password-reset/request');
      expect(req!.headers.containsKey('authorization'), isFalse);
      expect(jsonDecode(req!.body), {'email': 'user@example.test'});
      expect(result.requested, isTrue);
      expect(result.expiresAt, '2026-11-13T01:00:00Z');
      expect(result.debugToken, 'tok_dev');
    });

    test('requestPasswordReset answers a 503 with a GateError', () async {
      final gate = _gate((_) async => _err(503, 'EMAIL_NOT_CONFIGURED'));
      expect(
        () => gate.requestPasswordReset(email: 'user@example.test'),
        throwsA(isA<GateError>().having((e) => e.status, 'status', 503)),
      );
    });

    test('redeemPasswordReset returns a session and stores its refresh token', () async {
      final store = _Store();
      http.Request? req;
      final gate = _gate((r) async {
        req = r;
        return _ok({
          'redeemed': true,
          'endUserId': 'eu_1',
          'session': _session('rt_Reset0001'),
        });
      }, store);
      final result = await gate.redeemPasswordReset(token: 'tok', newPassword: 'N3w-password!');
      expect(req!.url.toString(), '$_base/password-reset/redeem');
      expect(req!.headers.containsKey('authorization'), isFalse);
      expect(jsonDecode(req!.body), {'token': 'tok', 'newPassword': 'N3w-password!'});
      expect(result.endUserId, 'eu_1');
      expect(result.session!.refreshToken, 'rt_Reset0001');
      expect(result.mfa, isNull);
      expect(await store.load(), 'rt_Reset0001');
    });

    test('redeemPasswordReset returns an mfa challenge and no session for an account with an authenticator', () async {
      final store = _Store();
      final gate = _gate((_) async => _ok({
            'redeemed': true,
            'endUserId': 'eu_1',
            'mfa': {
              'required': true,
              'challengeId': 'ch_1',
              'expiresAt': '2026-11-13T00:10:00Z',
              'methodsAvailable': ['totp'],
              'resident': {'region': 'de01', 'origin': 'https://acme.api-de01.example.test'},
            },
          }), store);
      final result = await gate.redeemPasswordReset(token: 'tok', newPassword: 'N3w-password!');
      expect(result.session, isNull);
      expect(result.mfa!.challengeId, 'ch_1');
      expect(result.mfa!.methodsAvailable, ['totp']);
      expect(result.mfa!.region, 'de01');
      expect(result.mfa!.origin, 'https://acme.api-de01.example.test');
      expect(await store.load(), isNull);
    });

    test('redeemPasswordReset maps a bad token to a 400 GateError', () async {
      final gate = _gate((_) async => _err(400, 'INVALID_FIELD_VALUE'));
      expect(
        () => gate.redeemPasswordReset(token: 'bad', newPassword: 'x'),
        throwsA(isA<GateError>().having((e) => e.status, 'status', 400)),
      );
    });
  });

  group('invitations', () {
    test('redeemInvitation sends the token, password and display name, and stores the refresh token', () async {
      final store = _Store();
      http.Request? req;
      final gate = _gate((r) async {
        req = r;
        return _ok({
          'redeemed': true,
          'user': {'id': 'eu_9', 'email': 'new@example.test'},
          'session': _session('rt_Invite0001'),
        });
      }, store);
      final result = await gate.redeemInvitation(
        token: 'inv_tok',
        password: 'S3cret-password!',
        displayName: 'New User',
      );
      expect(req!.url.toString(), '$_base/invitations/redeem');
      expect(req!.headers.containsKey('authorization'), isFalse);
      expect(jsonDecode(req!.body), {
        'token': 'inv_tok',
        'password': 'S3cret-password!',
        'displayName': 'New User',
      });
      expect(result.userId, 'eu_9');
      expect(result.email, 'new@example.test');
      expect(result.session.refreshToken, 'rt_Invite0001');
      expect(await store.load(), 'rt_Invite0001');
    });

    test('redeemInvitation leaves the display name out when none is given', () async {
      http.Request? req;
      final gate = _gate((r) async {
        req = r;
        return _ok({
          'redeemed': true,
          'user': {'id': 'eu_9', 'email': 'new@example.test'},
          'session': _session('rt_Invite0002'),
        });
      });
      await gate.redeemInvitation(token: 't', password: 'p');
      expect((jsonDecode(req!.body) as Map).containsKey('displayName'), isFalse);
    });

    test('redeemInvitation maps a bad token to a 400 GateError', () async {
      final gate = _gate((_) async => _err(400, 'INVALID_FIELD_VALUE'));
      expect(
        () => gate.redeemInvitation(token: 'bad', password: 'p'),
        throwsA(isA<GateError>().having((e) => e.status, 'status', 400)),
      );
    });
  });

  group('verifySession', () {
    test('sends the credential as the bearer and the token in the body, and returns the claims', () async {
      http.Request? req;
      final gate = _gate((r) async {
        req = r;
        return _ok({
          'valid': true,
          'claims': {
            'subjectId': 'eu_1',
            'projectId': 'proj_1',
            'expiresAt': '2099-01-01T00:00:00Z',
          },
        });
      });
      final result = await gate.verifySession(bearerToken: 'backend.credential', token: 'eu.access');
      expect(req!.url.toString(), '$_base/verify-session');
      expect(req!.headers['authorization'], 'Bearer backend.credential');
      expect(jsonDecode(req!.body), {'token': 'eu.access'});
      expect(result.valid, isTrue);
      expect(result.subjectId, 'eu_1');
      expect(result.projectId, 'proj_1');
      expect(result.expiresAt, '2099-01-01T00:00:00Z');
      expect(result.reason, isNull);
    });

    test('a refused token is an answer with valid false and a reason, not an error', () async {
      final gate = _gate((_) async => _ok({'valid': false, 'reason': 'expired'}));
      final result = await gate.verifySession(bearerToken: 'backend.credential', token: 'old');
      expect(result.valid, isFalse);
      expect(result.reason, 'expired');
      expect(result.subjectId, isNull);
    });

    test('a refused credential raises a GateError', () async {
      final gate = _gate((_) async => _err(401, 'UNAUTHENTICATED'));
      expect(
        () => gate.verifySession(bearerToken: 'bad', token: 't'),
        throwsA(isA<GateError>().having((e) => e.status, 'status', 401)),
      );
    });
  });

  test('an answer that does not decode is a decoding GateError', () async {
    final gate = _gate((_) async => _ok({'unexpected': true}));
    expect(
      () => gate.enrollTotp(accessToken: 'eu.access'),
      throwsA(isA<GateError>()),
    );
  });

  test('a network failure is a GateError', () async {
    final gate = _gate((_) async => throw http.ClientException('down'));
    expect(
      () => gate.verifySession(bearerToken: 'b', token: 't'),
      throwsA(isA<GateError>()),
    );
  });
}
